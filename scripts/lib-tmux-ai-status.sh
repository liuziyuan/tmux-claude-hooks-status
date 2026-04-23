#!/bin/bash
# lib-tmux-ai-status.sh: 共享库 — TMUX_PANE 解析、状态聚合、tool_state map、AskUserQuestion 标志
# 被 tmux-claude-status source
# 调用方需设置: TOOL_ID ("claude")、SESSION_ID（从 hook input 解析）

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATUS_COLOR="#F1FA8C"

# --- 日志模块 ---
source "${_LIB_DIR}/lib-tmux-ai-log.sh"

# --- TMUX_PANE 解析 ---
# hook 子进程不继承 $TMUX_PANE，通过进程树向上查找所属 pane
resolve_tmux_pane() {
    if [ -z "$TMUX_PANE" ]; then
        if [ -n "$TMUX" ]; then
            :
        elif command -v tmux &>/dev/null; then
            :
        else
            return
        fi
        local check_pid=$$
        while [ "${check_pid:-0}" -gt 1 ]; do
            local found
            found=$(tmux list-panes -a -F "#{pane_id} #{pane_pid}" 2>/dev/null \
                    | awk -v pid="$check_pid" '$2==pid{print $1; exit}')
            if [ -n "$found" ]; then TMUX_PANE="$found"; break; fi
            check_pid=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d '[:space:]')
        done
    fi
}

# --- Pane ID 持久化（供 SessionEnd 回读）---
_save_pane_id() {
    [ -n "$TMUX_PANE" ] && [ -n "$SESSION_ID" ] && echo "$TMUX_PANE" > "/tmp/claude-pane-${SESSION_ID}"
}
_load_pane_id() {
    [ -z "$SESSION_ID" ] && return 1
    [ -f "/tmp/claude-pane-${SESSION_ID}" ] && TMUX_PANE=$(cat "/tmp/claude-pane-${SESSION_ID}" 2>/dev/null) && [ -n "$TMUX_PANE" ]
}
_clear_pane_id() {
    [ -n "$SESSION_ID" ] && rm -f "/tmp/claude-pane-${SESSION_ID}"
}

# --- 状态聚合 ---
# 扫描所有 attached session 的 pane，读取 @claude_pane_status，写入 @ai_all_status
build_all_status() {
    ALL=""
    cur_sess=""
    while IFS='|' read -r pane_id session_name win_idx pane_idx claude_status _attached; do
        local pane_status="$claude_status"
        [ -n "$pane_status" ] || continue
        local session_block="#[bg=#6272A4,fg=#F8F8F2] ${session_name} #[bg=default,fg=default]"
        local panel_block="#[bg=#44475A,fg=#BD93F9] ${win_idx}.${pane_idx} #[bg=default,fg=default]"
        local status_block
        if [ "$pane_status" = "!" ] || [ "$pane_status" = "?" ]; then
            status_block="#[bg=#FF5555,fg=#F8F8F2] ${pane_status} #[bg=default,fg=default]"
        else
            status_block="#[bg=${STATUS_COLOR},fg=#282A36] ${pane_status} #[bg=default,fg=default]"
        fi
        local seg="${panel_block}${status_block}"
        if [ "$session_name" != "$cur_sess" ]; then
            ALL="${ALL:+$ALL  }${session_block}${seg}"
            cur_sess="$session_name"
        else
            ALL="${ALL}${seg}"
        fi
    done < <(tmux list-panes -a -F "#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{@claude_pane_status}|#{session_attached}|#{session_last_attached}" 2>/dev/null | awk -F'|' '$6>0' | sort -t'|' -k7,7n -k3,3n -k4,4n)
}

# --- Per-pane key ---
_state_key() {
    echo "${TOOL_ID}-${SESSION_ID:-unknown}-${TMUX_PANE//[^a-zA-Z0-9]/_}"
}

_toolmap_path() {
    echo "/tmp/$(_state_key)-toolmap"
}

_ask_flag_path() {
    echo "/tmp/$(_state_key)-ask"
}

_perm_flag_path() {
    echo "/tmp/$(_state_key)-perm"
}

# --- mkdir-based 原子锁（与日志模块同策略）---
# 最多等待 ~1s，超时放弃（单次 hook 冲突概率低）
_toolmap_lock() {
    local lock_dir="$1"
    local attempts=50
    while ! mkdir "$lock_dir" 2>/dev/null; do
        attempts=$((attempts - 1))
        [ "$attempts" -le 0 ] && return 1
        sleep 0.02 2>/dev/null || sleep 1
    done
    return 0
}

_toolmap_unlock() {
    rmdir "$1" 2>/dev/null
}

# --- tool_state map 操作 ---
# 格式: 每行 "tool_use_id:STATE"，STATE ∈ {P, A, C}
#   P = PENDING       (PreToolUse 已到，未知是否需权限)
#   A = AWAITING_PERM (PermissionRequest 已到，等用户响应)
#   C = COMPLETED     (PostToolUse 已到)

# 设置某 id 的状态（覆盖写入，始终移到文件末尾）
# $1 = id, $2 = state
_toolmap_set() {
    [ -z "$TMUX_PANE" ] && return
    local id="$1" state="$2"
    [ -z "$id" ] || [ -z "$state" ] && return
    local file; file=$(_toolmap_path)
    local lock="${file}.lock"
    _toolmap_lock "$lock" || return
    local tmp="${file}.tmp.$$"
    if [ -f "$file" ]; then
        grep -v "^${id}:" "$file" > "$tmp" 2>/dev/null || true
    else
        : > "$tmp"
    fi
    printf '%s:%s\n' "$id" "$state" >> "$tmp"
    mv "$tmp" "$file"
    _toolmap_unlock "$lock"
}

# PreToolUse 专用：仅当 id 当前不是 A 或 C 时写入 P（防止反向竞态覆盖已到达的 PermissionRequest）
_toolmap_set_pending_guarded() {
    [ -z "$TMUX_PANE" ] && return
    local id="$1"
    [ -z "$id" ] && return
    local file; file=$(_toolmap_path)
    local lock="${file}.lock"
    _toolmap_lock "$lock" || return
    local cur=""
    if [ -f "$file" ]; then
        cur=$(grep "^${id}:" "$file" 2>/dev/null | head -1 | cut -d: -f2)
    fi
    if [ "$cur" != "A" ] && [ "$cur" != "C" ]; then
        local tmp="${file}.tmp.$$"
        if [ -f "$file" ]; then
            grep -v "^${id}:" "$file" > "$tmp" 2>/dev/null || true
        else
            : > "$tmp"
        fi
        printf '%s:P\n' "$id" >> "$tmp"
        mv "$tmp" "$file"
    fi
    _toolmap_unlock "$lock"
}

# PermissionRequest 无 tool_use_id 时的容错：升级最早的 PENDING 为 AWAITING_PERM
_toolmap_upgrade_oldest_pending_to_awaiting() {
    [ -z "$TMUX_PANE" ] && return
    local file; file=$(_toolmap_path)
    local lock="${file}.lock"
    _toolmap_lock "$lock" || return
    if [ -f "$file" ]; then
        local tmp="${file}.tmp.$$"
        awk -F: 'BEGIN{done=0} {
            if (!done && $2=="P") { printf "%s:A\n", $1; done=1 }
            else { print }
        }' "$file" > "$tmp" 2>/dev/null
        [ -s "$tmp" ] && mv "$tmp" "$file" || rm -f "$tmp"
    fi
    _toolmap_unlock "$lock"
}

# PostToolUse 无 tool_use_id 时的容错：降级最早的 PENDING 为 COMPLETED
_toolmap_downgrade_oldest_pending() {
    [ -z "$TMUX_PANE" ] && return
    local file; file=$(_toolmap_path)
    local lock="${file}.lock"
    _toolmap_lock "$lock" || return
    if [ -f "$file" ]; then
        local tmp="${file}.tmp.$$"
        awk -F: 'BEGIN{done=0} {
            if (!done && $2=="P") { printf "%s:C\n", $1; done=1 }
            else { print }
        }' "$file" > "$tmp" 2>/dev/null
        [ -s "$tmp" ] && mv "$tmp" "$file" || rm -f "$tmp"
    fi
    _toolmap_unlock "$lock"
}

_toolmap_clear() {
    [ -z "$TMUX_PANE" ] && return
    local file; file=$(_toolmap_path)
    local lock="${file}.lock"
    _toolmap_lock "$lock" || return
    rm -f "$file"
    _toolmap_unlock "$lock"
}

# 判断 map 是否有 AWAITING_PERM 项（用于 Stop 拒绝推断）
_toolmap_has_awaiting() {
    [ -z "$TMUX_PANE" ] && return 1
    local file; file=$(_toolmap_path)
    [ -f "$file" ] || return 1
    grep -qE ':A$' "$file" 2>/dev/null
}

# 判断 map 是否有 PENDING 项
_toolmap_has_pending() {
    [ -z "$TMUX_PANE" ] && return 1
    local file; file=$(_toolmap_path)
    [ -f "$file" ] || return 1
    grep -qE ':P$' "$file" 2>/dev/null
}

# --- AskUserQuestion 标志（? 状态，与 tool_state map 独立）---
_set_ask_flag() {
    [ -z "$TMUX_PANE" ] && return
    printf '%s\n' "$(date +%s)" > "$(_ask_flag_path)" 2>/dev/null
}

_clear_ask_flag() {
    [ -z "$TMUX_PANE" ] && return
    rm -f "$(_ask_flag_path)"
}

_has_ask_flag() {
    [ -z "$TMUX_PANE" ] && return 1
    [ -f "$(_ask_flag_path)" ]
}

# --- PermissionRequest 标志（! 状态，防止 PreToolUse async 竞态覆盖）---
_set_perm_flag() {
    [ -z "$TMUX_PANE" ] && return
    printf '%s\n' "$(date +%s)" > "$(_perm_flag_path)" 2>/dev/null
}

_clear_perm_flag() {
    [ -z "$TMUX_PANE" ] && return
    rm -f "$(_perm_flag_path)"
}

_has_perm_flag() {
    [ -z "$TMUX_PANE" ] && return 1
    [ -f "$(_perm_flag_path)" ]
}

# --- 状态聚合计算 ---
# 优先级: ! > ? > > > (empty)
# stdout: "!" | "?" | ">" | "" （空表示无活跃状态）
# A 条目始终视为活跃，由 Stop/PostToolUse 负责清理
_compute_status() {
    if _toolmap_has_awaiting || _has_perm_flag; then
        echo "!"
    elif _has_ask_flag; then
        echo "?"
    elif _toolmap_has_pending; then
        echo ">"
    else
        echo ""
    fi
}

# 清理所有 per-pane 状态文件（SessionStart/SessionEnd/UserPromptSubmit 用）
_clear_all_state() {
    _toolmap_clear
    _clear_ask_flag
    _clear_perm_flag
}

# --- SessionEnd 竞态保护 ---
# /new 触发时 SessionEnd(async) 和 SessionStart(async) 同时执行，
# SessionEnd 可能晚于 SessionStart 写入，将 "-" 覆盖为 ""。
# 清除自身 pane-id 文件后，检查是否有其他 session 已接管此 pane。
_new_session_owns_pane() {
    [ -z "$TMUX_PANE" ] && return 1
    local f stored_pane
    for f in /tmp/claude-pane-*; do
        [ -f "$f" ] || continue
        stored_pane=$(cat "$f" 2>/dev/null)
        [ "$stored_pane" = "$TMUX_PANE" ] && return 0
    done
    return 1
}

# --- 进程树检查 ---
# BFS 遍历 pane 的进程树，检查是否有包含 "claude" 的命令
_pane_has_claude_process() {
    local pane_id="$1"
    local pane_pid
    pane_pid=$(tmux list-panes -t "$pane_id" -F "#{pane_pid}" 2>/dev/null)
    [ -z "$pane_pid" ] && return 1
    local pids="$pane_pid" next="" depth=0
    while [ $depth -lt 10 ] && [ -n "$pids" ]; do
        for p in $pids; do
            ps -o args= -p "$p" 2>/dev/null | grep -qi "claude" && return 0
            local children
            children=$(pgrep -P "$p" 2>/dev/null)
            [ -n "$children" ] && next="$next $children"
        done
        pids="${next# }"
        next=""
        depth=$((depth + 1))
    done
    return 1
}

# 检查 pane 的所有 pane-id 文件是否过期（> 5 min），再验证进程树
_is_pane_session_dead() {
    local pane_id="$1"
    local f stored_pane
    for f in /tmp/claude-pane-*; do
        [ -f "$f" ] || continue
        stored_pane=$(cat "$f" 2>/dev/null)
        [ "$stored_pane" != "$pane_id" ] && continue
        local mtime
        mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
        local age=$(( $(date +%s) - mtime ))
        [ "$age" -lt 300 ] && return 1
    done
    ! _pane_has_claude_process "$pane_id"
}

# --- 孤儿状态清理（_refresh 用）---
# 活跃状态 (!, ?, >) 的 pane 必须有对应的 /tmp/claude-pane-* 文件（由 SessionStart 写入）。
# 无对应文件则说明状态已过期（手动测试残留、pane 被销毁等），清除状态和 toolmap。
# 有对应文件但文件过期且进程已死（Stop 未触发的崩溃场景），也清除。
_cleanup_stale_panes() {
    local active_panes=""
    local f pane_id
    for f in /tmp/claude-pane-*; do
        [ -f "$f" ] || continue
        pane_id=$(cat "$f" 2>/dev/null)
        [ -n "$pane_id" ] && active_panes="$active_panes $pane_id"
    done

    while IFS='|' read -r pane_id pane_status; do
        case "$pane_status" in
            "!"|"?"|">")
                local sanitized="${pane_id//[^a-zA-Z0-9]/_}"
                if ! echo " $active_panes " | grep -q " $pane_id "; then
                    _ai_log "STALE: clearing orphaned '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @claude_pane_status "" 2>/dev/null || true
                    rm -f /tmp/claude-*-${sanitized}-toolmap 2>/dev/null
                    rm -f /tmp/claude-*-${sanitized}-ask 2>/dev/null
                    rm -f /tmp/claude-*-${sanitized}-perm 2>/dev/null
                elif _is_pane_session_dead "$pane_id"; then
                    _ai_log "STALE: clearing dead session '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @claude_pane_status "" 2>/dev/null || true
                    rm -f /tmp/claude-*-${sanitized}-toolmap 2>/dev/null
                    rm -f /tmp/claude-*-${sanitized}-ask 2>/dev/null
                    rm -f /tmp/claude-*-${sanitized}-perm 2>/dev/null
                    for f in /tmp/claude-pane-*; do
                        [ -f "$f" ] || continue
                        [ "$(cat "$f" 2>/dev/null)" = "$pane_id" ] && rm -f "$f"
                    done
                fi
                ;;
        esac
    done < <(tmux list-panes -a -F "#{pane_id}|#{@claude_pane_status}" 2>/dev/null)
}

# 频率限制的孤儿清理（每次 hook 调用，最多每 60s 执行一次）
_maybe_cleanup_stale() {
    local marker="/tmp/.claude-stale-cleanup-ts"
    local now
    now=$(date +%s)
    if [ -f "$marker" ]; then
        local last
        last=$(cat "$marker" 2>/dev/null)
        [ $((now - ${last:-0})) -lt 60 ] && return
    fi
    _cleanup_stale_panes
    echo "$now" > "$marker"
}
