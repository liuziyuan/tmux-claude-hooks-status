#!/bin/bash
# lib-tmux-ai-status.sh: 共享库 — TMUX_PANE 解析、状态聚合、watcher、竞态保护
# 被 tmux-claude-status 和 tmux-copilot-status source
# 调用方需设置: TOOL_ID ("claude" 或 "copilot")

STATUS_COLOR="#F1FA8C"

# --- TMUX_PANE 解析 ---
# hook 子进程不继承 $TMUX_PANE，通过进程树向上查找所属 pane
resolve_tmux_pane() {
    if [ -z "$TMUX_PANE" ]; then
        if [ -n "$TMUX" ]; then
            # Claude Code hooks: $TMUX 已继承，直接遍历进程树
            :
        elif command -v tmux &>/dev/null; then
            # Copilot CLI hooks: $TMUX 可能未继承，通过 tmux 命令可用性判断
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

# --- 状态聚合 ---
# 扫描所有 attached session 的 pane，读取 @claude_pane_status 和 @copilot_pane_status
# 每个 pane 取非空值，写入 @ai_all_status
build_all_status() {
    ALL=""
    cur_sess=""
    while IFS='|' read -r pane_id session_name win_idx pane_idx claude_status copilot_status _attached; do
        local pane_status="$claude_status"
        [ -n "$pane_status" ] || pane_status="$copilot_status"
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
    done < <(tmux list-panes -a -F "#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{@claude_pane_status}|#{@copilot_pane_status}|#{session_attached}|#{session_last_attached}" 2>/dev/null | awk -F'|' '$7>0' | sort -t'|' -k8,8n -k3,3n -k4,4n)
}

# --- 竞态保护 ---
_set_protection() {
    local tool_id="${1:-$TOOL_ID}"
    [ -n "$TMUX_PANE" ] && date +%s > "/tmp/${tool_id}-protect-${TMUX_PANE//[^a-zA-Z0-9]/_}"
}

_is_protected() {
    local tool_id="${1:-$TOOL_ID}"
    local pfile="/tmp/${tool_id}-protect-${TMUX_PANE//[^a-zA-Z0-9]/_}"
    [ -f "$pfile" ] || return 1
    local pt now
    pt=$(cat "$pfile" 2>/dev/null) || return 1
    now=$(date +%s)
    [ $((now - pt)) -lt 1 ]
}

_clear_protection() {
    local tool_id="${1:-$TOOL_ID}"
    rm -f "/tmp/${tool_id}-protect-${TMUX_PANE//[^a-zA-Z0-9]/_}" 2>/dev/null
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
    _clear_protection "$tool_id"
}

# --- 状态 watcher ---
# 保护 !/? 不被竞态 PostToolUse 覆盖，监控进程退出
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
    local pane_status_var
    if [ "$tool_id" = "copilot" ]; then
        pane_status_var="@copilot_pane_status"
    else
        pane_status_var="@claude_pane_status"
    fi
    (
        _my_gen="$watcher_gen"
        _my_pid_file="$watcher_pid_file"
        _protected="$protected_status"
        _pane_pid="$pane_pid"
        _tool_id="$tool_id"
        _pane_status_var="$pane_status_var"
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

        while true; do
            sleep 1
            _is_current || exit 0
            cur_status=$(tmux display-message -pt "$TMUX_PANE" -p "#{${_pane_status_var}}" 2>/dev/null)
            # 二次保护：若 !/? 被竞态 PostToolUse 覆盖为 > 且在保护窗口内，重新断言
            if [ "$cur_status" = ">" ] && _is_protected "$_tool_id"; then
                tmux set-option -pt "$TMUX_PANE" "$_pane_status_var" "$_protected" 2>/dev/null
                build_all_status
                tmux set-option -g @ai_all_status "$ALL" 2>/dev/null
                tmux refresh-client -S 2>/dev/null || true
                continue
            fi
            # 若状态已不是 protected（被其他 hook 更新且保护已过期），退出
            [ "$cur_status" = "$_protected" ] || { _clear_protection "$_tool_id"; exit 0; }
            # 对于 !：检查 pane shell 是否还有子进程（AI 是否仍在运行）
            if [ "$_protected" = "!" ] && ! pgrep -P "$_pane_pid" >/dev/null 2>&1; then
                _is_current || exit 0
                tmux set-option -pt "$TMUX_PANE" "$_pane_status_var" "-" 2>/dev/null
                _clear_protection "$_tool_id"
                build_all_status
                tmux set-option -g @ai_all_status "$ALL" 2>/dev/null
                tmux refresh-client -S 2>/dev/null || true
                exit 0
            fi
        done
    ) &
    echo "$!:$watcher_gen" > "$watcher_pid_file"
    disown
}
