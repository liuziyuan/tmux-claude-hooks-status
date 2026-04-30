#!/bin/bash
# lib-tmux-ai-status.sh: 共享库 — TMUX_PANE 解析、状态聚合、pane title 监控
# 被 tmux-claude-status source
# 调用方需设置: TOOL_ID ("claude")、SESSION_ID（从 hook input 解析）

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_STATUS_DIR="/tmp/claude-status"
STATUS_COLOR="#F1FA8C"

# --- 日志模块 ---
source "${_LIB_DIR}/lib-tmux-ai-log.sh"

# --- Per-pane 目录 ---
# 结构: ${_STATUS_DIR}/${PANE_SANITIZED}/
#   pane-${SESSION_ID}          session → pane 映射（内容为 pane_id）
#   ${SESSION_ID}-poll-pid      approval poll 后台进程 PID

_pane_sanitized() {
    echo "${TMUX_PANE//[^a-zA-Z0-9]/_}"
}

_pane_dir() {
    echo "${_STATUS_DIR}/$(_pane_sanitized)"
}

_ensure_pane_dir() {
    local dir; dir=$(_pane_dir)
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null
}

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
# 注意: SessionStart/SessionEnd 事件不含 session_id，_save_pane_id 在这两事件中不会保存。
# 映射由后续事件（PreToolUse、PermissionRequest 等）建立。
# SessionEnd 回退链: resolve_tmux_pane → _load_pane_id → _cleanup_stale_panes。
# 若 Claude 会话全程无工具调用，pane 状态可能残留最多 60s（直到下次 cleanup）。
_save_pane_id() {
    [ -n "$TMUX_PANE" ] && [ -n "$SESSION_ID" ] && { _ensure_pane_dir; echo "$TMUX_PANE" > "$(_pane_dir)/pane-${SESSION_ID}"; }
}
_load_pane_id() {
    [ -z "$SESSION_ID" ] && return 1
    local f
    for f in "${_STATUS_DIR}"/*/pane-${SESSION_ID}; do
        [ -f "$f" ] || continue
        TMUX_PANE=$(cat "$f" 2>/dev/null) && [ -n "$TMUX_PANE" ] && return 0
    done
    return 1
}
_clear_pane_id() {
    [ -n "$SESSION_ID" ] && rm -f "$(_pane_dir)/pane-${SESSION_ID}"
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

# --- Pane Title 监控 ---
# Claude Code 通过 pane title 显示状态:
#   ✳ Claude Code (U+2733) = 等待用户操作（PermissionRequest / 等待输入）
#   ⠐ Claude Code (盲文字符 U+2800-U+28FF，动态变化) = 处理中/thinking
# 用户批准权限时 title 从 ✳ → 盲文，作为批准检测的 ground truth。

_poll_pid_path() {
    echo "$(_pane_dir)/${SESSION_ID:-unknown}-poll-pid"
}

# 检查 pane title 是否为处理中状态
# return 0 = 处理中, return 1 = 等待用户或非 Claude pane
_pane_title_is_processing() {
    local pane_id="${1:-$TMUX_PANE}"
    [ -n "$pane_id" ] || return 1
    local title
    title=$(tmux display-message -pt "$pane_id" -p '#{pane_title}' 2>/dev/null) || return 1
    case "$title" in
        ✳*) return 1 ;;
        *Claude\ Code*) return 0 ;;
        *) return 1 ;;
    esac
}

# 后台监控 pane title + 弹窗状态，检测用户批准/拒绝
# 检测机制：
#   1. 权限弹窗显示时 pane lastline 包含 "Esc to cancel"
#   2. 弹窗关闭（用户操作了）后 lastline 变化
#   3. 此时检查 title：盲文 = 批准，✳ = 拒绝
# 无超时：poll 通过弹窗消失精确检测用户操作，不依赖定时器。
# $1 = wait_status ("!" 或 "?")
_start_approval_poll() {
    [ -z "$TMUX_PANE" ] || [ -z "$SESSION_ID" ] && return
    _stop_approval_poll
    local wait_status="${1:-!}"
    local pid_file
    pid_file=$(_poll_pid_path)
    _ensure_pane_dir

    (
        echo $$ > "$pid_file"
        trap 'rm -f "$pid_file" 2>/dev/null' EXIT
        local saw_popup=0
        while :; do
            sleep 0.3 2>/dev/null || sleep 1
            # pane 状态已被外部变更（Stop 等），退出
            local cur_status
            cur_status=$(tmux display-message -pt "$TMUX_PANE" -p '#{@claude_pane_status}' 2>/dev/null)
            if [ "$cur_status" != "!" ] && [ "$cur_status" != "?" ]; then
                exit 0
            fi
            # 检测权限弹窗状态（lastline 含 "Esc to cancel" = 弹窗显示中）
            local lastline
            lastline=$(tmux capture-pane -pt "$TMUX_PANE" -p 2>/dev/null | grep -v '^$' | tail -1)
            case "$lastline" in
                *"Esc to cancel"*)
                    saw_popup=1
                    ;;
                *)
                    if [ "$saw_popup" -eq 1 ]; then
                        # 弹窗关闭 → 用户做了操作
                        if _pane_title_is_processing "$TMUX_PANE"; then
                            tmux set-option -pt "$TMUX_PANE" @claude_pane_status ">" 2>/dev/null || true
                            build_all_status
                            tmux set-option -g @ai_all_status "$ALL" 2>/dev/null || true
                            tmux refresh-client -S 2>/dev/null || true
                            _ai_log "POLL: approved (popup closed + title → processing)"
                            exit 0
                        else
                            tmux set-option -pt "$TMUX_PANE" @claude_pane_status "-" 2>/dev/null || true
                            build_all_status
                            tmux set-option -g @ai_all_status "$ALL" 2>/dev/null || true
                            tmux refresh-client -S 2>/dev/null || true
                            _ai_log "POLL: rejected (popup closed + title still ✳)"
                            exit 0
                        fi
                    fi
                    ;;
            esac
        done
    ) &
}

# 停止后台 approval poll
_stop_approval_poll() {
    [ -z "$SESSION_ID" ] && return
    local pid_file
    pid_file=$(_poll_pid_path)
    [ -f "$pid_file" ] || return
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    rm -f "$pid_file"
}

# 清理所有 per-pane 状态（SessionStart/SessionEnd/UserPromptSubmit 用）
_clear_all_state() {
    _stop_approval_poll
}

# --- SessionEnd 竞态保护 ---
# /new 触发时 SessionEnd(async) 和 SessionStart(async) 同时执行，
# SessionEnd 可能晚于 SessionStart 写入，将 "-" 覆盖为 ""。
# 清除自身 pane-id 文件后，检查是否有其他 session 已接管此 pane。
_new_session_owns_pane() {
    [ -z "$TMUX_PANE" ] && return 1
    local sanitized; sanitized=$(_pane_sanitized)
    local pane_dir="${_STATUS_DIR}/${sanitized}"
    [ -d "$pane_dir" ] || return 1
    local f
    for f in "${pane_dir}"/pane-*; do
        [ -f "$f" ] || continue
        local stored_pane
        stored_pane=$(cat "$f" 2>/dev/null)
        [ "$stored_pane" = "$TMUX_PANE" ] || continue
        local mtime
        # stat 失败时保守视为新鲜（date +%s），避免误清活跃会话
        mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || date +%s)
        local age=$(( $(date +%s) - mtime ))
        [ "$age" -ge 300 ] && ! _pane_has_claude_process "$TMUX_PANE" && continue
        return 0
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
            local cmd
            cmd=$(ps -o comm= -p "$p" 2>/dev/null)
            [ "$(basename "$cmd" 2>/dev/null)" = "claude" ] && return 0
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
    local sanitized="${pane_id//[^a-zA-Z0-9]/_}"
    local pane_dir="${_STATUS_DIR}/${sanitized}"
    [ -d "$pane_dir" ] || return 0
    local f
    for f in "${pane_dir}"/pane-*; do
        [ -f "$f" ] || continue
        local mtime
        # stat 失败时保守视为新鲜（date +%s），避免误清活跃会话
        mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || date +%s)
        local age=$(( $(date +%s) - mtime ))
        [ "$age" -lt 300 ] && return 1
    done
    ! _pane_has_claude_process "$pane_id"
}

# --- 孤儿状态清理（_refresh 用）---
# 活跃状态 (!, ?, >) 的 pane 必须有对应的 pane 目录和 pane-${SESSION_ID} 文件（由 SessionStart 写入）。
# 无对应文件则说明状态已过期（手动测试残留、pane 被销毁等），清除整个 pane 目录。
# 有对应文件但文件过期且进程已死（Stop 未触发的崩溃场景），也清除。
_cleanup_stale_panes() {
    local active_panes=""
    local f pane_id
    for f in "${_STATUS_DIR}"/*/pane-*; do
        [ -f "$f" ] || continue
        pane_id=$(cat "$f" 2>/dev/null)
        [ -n "$pane_id" ] && active_panes="$active_panes $pane_id"
    done

    while IFS='|' read -r pane_id pane_status; do
        case "$pane_status" in
            "!"|"?"|">")
                local sanitized="${pane_id//[^a-zA-Z0-9]/_}"
                local pane_dir="${_STATUS_DIR}/${sanitized}"
                if ! echo " $active_panes " | grep -q " $pane_id "; then
                    _ai_log "STALE: clearing orphaned '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @claude_pane_status "" 2>/dev/null || true
                    rm -rf "$pane_dir" 2>/dev/null
                elif _is_pane_session_dead "$pane_id"; then
                    _ai_log "STALE: clearing dead session '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @claude_pane_status "" 2>/dev/null || true
                    rm -rf "$pane_dir" 2>/dev/null
                fi
                ;;
            "✓"|"-")
                if ! _pane_has_claude_process "$pane_id"; then
                    _ai_log "STALE: clearing terminal state '$pane_status' on $pane_id (no claude process)"
                    tmux set-option -pt "$pane_id" @claude_pane_status "" 2>/dev/null || true
                fi
                ;;
        esac
    done < <(tmux list-panes -a -F "#{pane_id}|#{@claude_pane_status}" 2>/dev/null)

    # 清理孤儿目录：目录存在但对应 pane 已不在 tmux 中
    local all_pane_ids
    all_pane_ids=$(tmux list-panes -a -F "#{pane_id}" 2>/dev/null)
    for pane_dir in "${_STATUS_DIR}"/*/; do
        [ -d "$pane_dir" ] || continue
        local dir_name
        dir_name=$(basename "$pane_dir")
        local found=0
        while IFS= read -r pid; do
            [ "${pid//[^a-zA-Z0-9]/_}" = "$dir_name" ] && { found=1; break; }
        done <<< "$all_pane_ids"
        if [ "$found" -eq 0 ]; then
            # 清理孤儿 poll 进程
            for pid_file in "${pane_dir}"*-poll-pid; do
                [ -f "$pid_file" ] || continue
                local pid
                pid=$(cat "$pid_file" 2>/dev/null)
                [ -n "$pid" ] && kill "$pid" 2>/dev/null
            done
            _ai_log "ORPHAN: removing $pane_dir (pane no longer exists)"
            rm -rf "$pane_dir" 2>/dev/null
        fi
    done
}

# 频率限制的孤儿清理（每次 hook 调用，最多每 60s 执行一次）
_maybe_cleanup_stale() {
    local marker="${_STATUS_DIR}/.stale-cleanup-ts"
    local now
    now=$(date +%s)
    [ -d "$_STATUS_DIR" ] || mkdir -p "$_STATUS_DIR" 2>/dev/null
    if [ -f "$marker" ]; then
        local last
        last=$(cat "$marker" 2>/dev/null)
        [ $((now - ${last:-0})) -lt 60 ] && return
    fi
    _cleanup_stale_panes
    echo "$now" > "$marker"
}
