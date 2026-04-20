#!/bin/bash
# lib-tmux-ai-status.sh: 共享库 — TMUX_PANE 解析、状态聚合、watcher、竞态保护
# 被 tmux-claude-status source
# 调用方需设置: TOOL_ID ("claude")

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATUS_COLOR="#F1FA8C"

# --- 日志模块 ---
source "${_LIB_DIR}/lib-tmux-ai-log.sh"

# --- TMUX_PANE 解析 ---
# hook 子进程不继承 $TMUX_PANE，通过进程树向上查找所属 pane
resolve_tmux_pane() {
    if [ -z "$TMUX_PANE" ]; then
        if [ -n "$TMUX" ]; then
            # Claude Code hooks: $TMUX 已继承，直接遍历进程树
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
# 扫描所有 attached session 的 pane，读取 @claude_pane_status
# 每个 pane 取非空值，写入 @ai_all_status
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

# --- 权限模式（事件序列保护）---
# 临时文件 key = ${TOOL_ID}-${SESSION_ID}-${TMUX_PANE（sanitized）}
# SESSION_ID 由调用方从 hook input JSON 中解析后设置

_permission_key() {
    echo "${TOOL_ID}-${SESSION_ID:-unknown}-${TMUX_PANE//[^a-zA-Z0-9]/_}"
}

_enter_permission_mode() {
    if [ -z "$TMUX_PANE" ]; then return; fi
    local key=$(_permission_key)
    echo "$(date +%s)" > "/tmp/${key}-permission"
    # 保留已有 pretool-ids：PreToolUse 先于 PermissionRequest 到达时，
    # 需要保留它已记录的 tool_use_id，否则 PostToolUse 无法匹配、永远卡在 permission_mode
    touch "/tmp/${key}-pretool-ids"
}

_exit_permission_mode() {
    if [ -z "$TMUX_PANE" ]; then return; fi
    local key=$(_permission_key)
    rm -f "/tmp/${key}-permission" "/tmp/${key}-pretool-ids"
}

_is_permission_mode() {
    if [ -z "$TMUX_PANE" ]; then return 1; fi
    [ -f "/tmp/$(_permission_key)-permission" ]
}

_record_pretool_id() {
    local tool_use_id="$1"
    if [ -z "$TMUX_PANE" ] || [ -z "$tool_use_id" ]; then return; fi
    echo "$tool_use_id" >> "/tmp/$(_permission_key)-pretool-ids"
}

_check_pretool_id() {
    local tool_use_id="$1"
    if [ -z "$TMUX_PANE" ] || [ -z "$tool_use_id" ]; then return 1; fi
    grep -qx "$tool_use_id" "/tmp/$(_permission_key)-pretool-ids" 2>/dev/null
}

# --- Watcher PID 管理 ---
_read_watcher_pid() {
    local tool_id="${1:-$TOOL_ID}"
    local pid_file="/tmp/${tool_id}-watcher-${TMUX_PANE//[^a-zA-Z0-9]/_}.pid"
    [ -f "$pid_file" ] || return 1
    local content
    content=$(cat "$pid_file" 2>/dev/null) || return 1
    echo "${content%%:*}"
}

_read_watcher_gen() {
    local tool_id="${1:-$TOOL_ID}"
    local pid_file="/tmp/${tool_id}-watcher-${TMUX_PANE//[^a-zA-Z0-9]/_}.pid"
    [ -f "$pid_file" ] || return 1
    local content
    content=$(cat "$pid_file" 2>/dev/null) || return 1
    echo "${content#*:}"
}

# --- 杀掉当前 watcher ---
kill_watcher() {
    local tool_id="${1:-$TOOL_ID}"
    if [ -z "$TMUX_PANE" ]; then return; fi
    local pid_file="/tmp/${tool_id}-watcher-${TMUX_PANE//[^a-zA-Z0-9]/_}.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(_read_watcher_pid "$tool_id")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$pid_file"
    fi
}

# --- 状态 watcher ---
# 监控 pane 进程退出，检测 AI 是否停止运行
# 参数: $1 = tool_id, $2 = protected_status ("!" 或 "?")
start_status_watcher() {
    local tool_id="$1"
    local protected_status="$2"
    if [ -z "$TMUX_PANE" ]; then return; fi
    local pane_pid
    pane_pid=$(tmux display-message -pt "$TMUX_PANE" -p "#{pane_pid}" 2>/dev/null)
    [ -n "$pane_pid" ] || return
    local watcher_gen="$$"
    local watcher_pid_file="/tmp/${tool_id}-watcher-${TMUX_PANE//[^a-zA-Z0-9]/_}.pid"
    local _pane_loc_outer="$_pane_loc"
    local pane_status_var="@claude_pane_status"
    (
        _my_gen="$watcher_gen"
        _my_pid_file="$watcher_pid_file"
        _protected="$protected_status"
        _pane_pid="$pane_pid"
        _pane_status_var="$pane_status_var"
        _pane_loc="$_pane_loc_outer"
        _is_current() {
            [ -f "$_my_pid_file" ] && [ "$(cat "$_my_pid_file" 2>/dev/null | cut -d: -f2)" = "$_my_gen" ]
        }
        _cleanup() {
            if [ -f "$_my_pid_file" ]; then
                local gen
                gen=$(cat "$_my_pid_file" 2>/dev/null | cut -d: -f2)
                [ "$gen" = "$_my_gen" ] && rm -f "$_my_pid_file"
            fi
        }
        trap _cleanup EXIT

        _start_time=$(date +%s)
        while true; do
            sleep 1
            _is_current || exit 0
            if [ "$_protected" = "!" ]; then
                # AI 进程已退出 → reset 为 -
                if ! pgrep -P "$_pane_pid" >/dev/null 2>&1; then
                    _is_current || exit 0
                    tmux set-option -pt "$TMUX_PANE" "$_pane_status_var" "-" 2>/dev/null
                    build_all_status
                    tmux set-option -g @ai_all_status "$ALL" 2>/dev/null
                    tmux refresh-client -S 2>/dev/null || true
                    exit 0
                fi
                # 超时 30 秒：权限被拒绝但无事件触发，自动 reset 为 -
                if [ $(( $(date +%s) - _start_time )) -ge "${PERMISSION_TIMEOUT:-30}" ]; then
                    _is_current || exit 0
                    tmux set-option -pt "$TMUX_PANE" "$_pane_status_var" "-" 2>/dev/null
                    build_all_status
                    tmux set-option -g @ai_all_status "$ALL" 2>/dev/null
                    tmux refresh-client -S 2>/dev/null || true
                    exit 0
                fi
            fi
        done
    ) &
    local w_pid=$!
    echo "$w_pid:$watcher_gen" > "$watcher_pid_file"
    disown
}
