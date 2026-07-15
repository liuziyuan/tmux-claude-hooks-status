#!/bin/bash
# lib-tmux-ai-status.sh: 共享库 — TMUX_PANE 解析、状态聚合、pane title 监控
# 被 tmux-ai-status source
# 调用方需设置: TOOL_ID ("claude" | "codex")、SESSION_ID（从 hook input 解析）

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_STATUS_DIR="/tmp/ai-status"
STATUS_COLOR="#F1FA8C"

# --- 日志模块 ---
source "${_LIB_DIR}/lib-tmux-ai-log.sh"

# --- 工具适配器加载 ---
# 每个 AI CLI 的差异（事件集/hooks路径/格式/完整性/进程名/SessionEnd/SessionStart时机）
# 抽到 adapters/<TOOL_ID>.sh，核心引擎读 adapter 暴露的变量/函数分派，不再写 case "$TOOL_ID"。
# 加新 CLI = 加一个 adapters/<tool>.sh，核心零改动。
_ADAPTER_DIR="${_LIB_DIR}/adapters"
_load_adapter() {
    local tool="${TOOL_ID:-claude}"
    local adapter="${_ADAPTER_DIR}/${tool}.sh"
    if [ -f "$adapter" ]; then
        source "$adapter"
    else
        _ai_log "ADAPTER: 未找到 ${adapter}，回退默认（claude）"
        [ -f "${_ADAPTER_DIR}/claude.sh" ] && source "${_ADAPTER_DIR}/claude.sh"
    fi
}
_load_adapter

# 跨 adapter 汇总所有 AI CLI 的进程名（供 _pane_has_ai_process 识别聚合场景下的
# 任意工具进程——聚合/清理路径需认全部工具，不止当前 TOOL_ID）。扫 adapters/*.sh
# 提取 ADAPTER_PROCESS_NAMES。惰性求值，缓存到 _ALL_AI_PROCESS_NAMES。
_ALL_AI_PROCESS_NAMES=""
_collect_ai_process_names() {
    [ -n "$_ALL_AI_PROCESS_NAMES" ] && { echo "$_ALL_AI_PROCESS_NAMES"; return; }
    local names="" f n
    for f in "${_ADAPTER_DIR}"/*.sh; do
        [ -f "$f" ] || continue
        # 提取 ADAPTER_PROCESS_NAMES="..." 的值（不 source，避免副作用）
        n=$(sed -n 's/^ADAPTER_PROCESS_NAMES="\([^"]*\)".*/\1/p' "$f" 2>/dev/null)
        [ -n "$n" ] && names="$names $n"
    done
    # 去重
    _ALL_AI_PROCESS_NAMES=$(echo "$names" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
    echo "$_ALL_AI_PROCESS_NAMES"
}

# --- Per-pane 目录 ---
# 结构: ${_STATUS_DIR}/${PANE_SANITIZED}/
#   pane-${SESSION_ID}          session → pane 映射（内容为 pane_id）
#   pending-pre                 已收 PreToolUse、未收 PostToolUse 的 tool_use_id（每行 "id tool ts"）
#   pending-perm                已收 PermissionRequest、未配对的 tool_use_id（每行 "id !/? tool ts"）
#   .lock/                      修改 pending-* 时的 per-pane mkdir mutex

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
# 扫描所有 attached session 的 pane，读取 @ai_pane_status，写入 @ai_all_status
#
# 空窗期补 idle：codex 的 SessionStart hook 延迟到首个 turn 才触发（上游 run_pending_
# session_start_hooks 设计），空闲蹲在提示符时插件收不到任何事件 → 无 @ai_pane_status。
# 用 pane_current_command 兜底：前台命令是 codex/claude 但无显式状态时，显示 idle `-`。
# 纯显示，不落 @ai_pane_status（避免污染 pending/cleanup 逻辑）。零进程扫描。
build_all_status() {
    ALL=""
    cur_sess=""
    local _ai_names
    _ai_names=$(_collect_ai_process_names)
    while IFS='|' read -r pane_id session_name win_idx pane_idx claude_status _attached _last cur_cmd; do
        local pane_status="$claude_status"
        if [ -z "$pane_status" ]; then
            # 无显式状态：若前台是 AI 进程（codex 首个 turn 前空窗期），补 idle。
            # 进程名集合从所有 adapter 汇总，前缀匹配（codex-aarch64-* 等）。
            local _cmd_base _n _is_ai=0
            _cmd_base=$(basename "$cur_cmd" 2>/dev/null)
            for _n in $_ai_names; do
                case "$_cmd_base" in
                    "$_n"|"$_n"-*|"$_n"_*) _is_ai=1; break ;;
                esac
            done
            [ "$_is_ai" = "1" ] && pane_status="-" || continue
        fi
        local session_block="#[bg=#6272A4,fg=#F8F8F2] ${session_name} #[bg=default,fg=default]"
        local panel_block="#[bg=#44475A,fg=#BD93F9] ${win_idx}.${pane_idx} #[bg=default,fg=default]"
        local status_block
        if [ "$pane_status" = "!" ] || [ "$pane_status" = "?" ]; then
            status_block="#[bg=#FF5555,fg=#F8F8F2] ${pane_status} #[bg=default,fg=default]"
        elif [ "$pane_status" = ">" ]; then
            status_block="#[bg=#50FA7B,fg=#282A36] ${pane_status} #[bg=default,fg=default]"
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
    done < <(tmux list-panes -a -F "#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{@ai_pane_status}|#{session_attached}|#{session_last_attached}|#{pane_current_command}" 2>/dev/null | awk -F'|' '$6>0' | sort -t'|' -k7,7n -k2,2 -k3,3n -k4,4n)
}

# --- Pending 集合管理（PreToolUse / PermissionRequest 配对）---
# 状态判定基于两个 per-pane 集合:
#   pending-pre   : 已 PreToolUse 未 PostToolUse 的 tool_use_id
#   pending-perm  : 已 PermissionRequest 未配对的 tool_use_id (含 ! 或 ?)
# 派生规则:
#   perm 含 "!"   → STATUS=!
#   perm 含 "?"   → STATUS=?
#   pre 非空      → STATUS=>
#   都空          → STATUS=""（事件自行决定）

_pending_pre_path()  { echo "$(_pane_dir)/pending-pre"; }
_pending_perm_path() { echo "$(_pane_dir)/pending-perm"; }
_lock_dir()          { echo "$(_pane_dir)/.lock"; }

# Per-pane mkdir mutex。5s stale 强夺。retry 20 × 10ms ≈ 200ms 上限。
_acquire_lock() {
    [ -n "$TMUX_PANE" ] || return 1
    _ensure_pane_dir
    local lock; lock=$(_lock_dir)
    local i
    for i in $(seq 1 20); do
        if mkdir "$lock" 2>/dev/null; then
            return 0
        fi
        # stale 检测: 锁目录 mtime > 5s 视为遗弃
        local mtime
        mtime=$(stat -f %m "$lock" 2>/dev/null || stat -c %Y "$lock" 2>/dev/null)
        if [ -n "$mtime" ]; then
            local age=$(( $(date +%s) - mtime ))
            if [ "$age" -ge 5 ]; then
                rmdir "$lock" 2>/dev/null
                mkdir "$lock" 2>/dev/null && return 0
            fi
        fi
        sleep 0.01 2>/dev/null || sleep 1
    done
    _ai_log "LOCK: acquire timeout on $lock"
    return 1
}

_release_lock() {
    [ -n "$TMUX_PANE" ] || return
    rmdir "$(_lock_dir)" 2>/dev/null
}

# 在锁内追加一行到 pending-pre。$1=tool_use_id $2=tool_name
_add_pending_pre() {
    local id="$1" tool="$2"
    [ -z "$id" ] && return
    _acquire_lock || return
    local f; f=$(_pending_pre_path)
    # 已存在则不重复
    if ! grep -q "^${id} " "$f" 2>/dev/null; then
        echo "${id} ${tool:-?} $(date +%s)" >> "$f"
    fi
    _release_lock
}

# 在锁内追加一行到 pending-perm。$1=tool_use_id $2=! 或 ? $3=tool_name
_add_pending_perm() {
    local id="$1" mark="$2" tool="$3"
    [ -z "$id" ] && return
    _acquire_lock || return
    local f; f=$(_pending_perm_path)
    if ! grep -q "^${id} " "$f" 2>/dev/null; then
        echo "${id} ${mark} ${tool:-?} $(date +%s)" >> "$f"
    fi
    _release_lock
}

# 从 pending-pre 和 pending-perm 同时移除 id（配对清除）
_remove_pending_id() {
    local id="$1"
    [ -z "$id" ] && return
    _acquire_lock || return
    local pre; pre=$(_pending_pre_path)
    local perm; perm=$(_pending_perm_path)
    # 注意: grep -v 无匹配行时退出 1,不能用 && 串接 mv;改用无条件 mv
    if [ -f "$pre" ]; then
        grep -v "^${id} " "$pre" > "${pre}.tmp" 2>/dev/null
        mv "${pre}.tmp" "$pre" 2>/dev/null || rm -f "${pre}.tmp"
    fi
    if [ -f "$perm" ]; then
        grep -v "^${id} " "$perm" > "${perm}.tmp" 2>/dev/null
        mv "${perm}.tmp" "$perm" 2>/dev/null || rm -f "${perm}.tmp"
    fi
    _release_lock
}

# 清空两个 pending 文件（Stop/SessionStart/SessionEnd/UserPromptSubmit/Esc 用）
_clear_pending() {
    [ -n "$TMUX_PANE" ] || return
    _acquire_lock || return
    rm -f "$(_pending_pre_path)" "$(_pending_perm_path)" 2>/dev/null
    _release_lock
}

# 根据当前 pending-perm / pending-pre 派生 STATUS。结果写入全局 DERIVED
# return 0 = 派生出非空 STATUS, return 1 = 都空（事件需自行决定）
_derive_status_from_pending() {
    DERIVED=""
    [ -n "$TMUX_PANE" ] || return 1
    local perm; perm=$(_pending_perm_path)
    local pre; pre=$(_pending_pre_path)
    if [ -s "$perm" ]; then
        if awk '{if ($2=="!") {f=1; exit}} END{exit !f}' "$perm" 2>/dev/null; then
            DERIVED="!"; return 0
        fi
        if awk '{if ($2=="?") {f=1; exit}} END{exit !f}' "$perm" 2>/dev/null; then
            DERIVED="?"; return 0
        fi
    fi
    if [ -s "$pre" ]; then
        DERIVED=">"; return 0
    fi
    return 1
}

# 兼容旧调用名（Stop/SessionEnd 仍可能引用）
_clear_all_state() {
    _clear_pending
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
        [ "$age" -ge 300 ] && ! _pane_has_ai_process "$TMUX_PANE" && continue
        return 0
    done
    return 1
}

# --- 进程树检查 ---
# BFS 遍历 pane 的进程树，检查是否有 AI CLI 进程。
# 进程名集合从所有 adapter 的 ADAPTER_PROCESS_NAMES 汇总（_collect_ai_process_names），
# 前缀匹配（codex 二进制常为 codex-aarch64-* 等带后缀名）。
_pane_has_ai_process() {
    local pane_id="$1"
    local pane_pid
    # 注意：list-panes -t "%N" 会返回该 pane 所在 window 的全部 pane，
    # 直接取 #{pane_pid} 会混入同 window 其他 pane 的 pid，导致 BFS 爬到
    # 邻近 pane 的 AI 进程而误判。必须用 -a 全局列 + 精确匹配 pane_id。
    pane_pid=$(tmux list-panes -a -F "#{pane_id} #{pane_pid}" 2>/dev/null \
        | awk -v id="$pane_id" '$1==id{print $2; exit}')
    [ -z "$pane_pid" ] && return 1
    local ai_names
    ai_names=$(_collect_ai_process_names)
    local pids="$pane_pid" next="" depth=0
    while [ $depth -lt 10 ] && [ -n "$pids" ]; do
        for p in $pids; do
            local cmd base name
            cmd=$(ps -o comm= -p "$p" 2>/dev/null)
            base=$(basename "$cmd" 2>/dev/null)
            for name in $ai_names; do
                case "$base" in
                    "$name"|"$name"-*|"$name"_*) return 0 ;;
                esac
            done
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
    ! _pane_has_ai_process "$pane_id"
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
                    tmux set-option -pt "$pane_id" @ai_pane_status "" 2>/dev/null || true
                    rm -rf "$pane_dir" 2>/dev/null
                elif _is_pane_session_dead "$pane_id"; then
                    _ai_log "STALE: clearing dead session '$pane_status' on $pane_id"
                    tmux set-option -pt "$pane_id" @ai_pane_status "" 2>/dev/null || true
                    rm -rf "$pane_dir" 2>/dev/null
                fi
                ;;
            "✓"|"-")
                if ! _pane_has_ai_process "$pane_id"; then
                    _ai_log "STALE: clearing terminal state '$pane_status' on $pane_id (no ai process)"
                    tmux set-option -pt "$pane_id" @ai_pane_status "" 2>/dev/null || true
                fi
                ;;
        esac
    done < <(tmux list-panes -a -F "#{pane_id}|#{@ai_pane_status}" 2>/dev/null)

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

# Hooks 完整性检查：委托给当前 adapter（adapter_check_integrity）。
# 各工具的路径/格式/事件数判定在 adapters/<tool>.sh 中声明，核心不再 case 分派。
# 缺失 → 返回 1（配置被外部应用覆盖时会发生）。
_check_hooks_integrity() {
    if declare -f adapter_check_integrity >/dev/null 2>&1; then
        adapter_check_integrity
    else
        # adapter 未加载（异常）→ 保守视为完整，避免误触发重装
        return 0
    fi
}

# 兜底自修复：tmux 端事件路径调用，配置被外部覆盖时自动重装。
# 不依赖 SESSION_ID/EVENT，可被 _refresh 触发。60s 节流。
# 安装器由 adapter 声明（ADAPTER_INSTALLER）。
_maybe_repair_hooks() {
    local marker="${_STATUS_DIR}/.hooks-repair-${TOOL_ID:-claude}-ts"
    local now
    now=$(date +%s)
    [ -d "$_STATUS_DIR" ] || mkdir -p "$_STATUS_DIR" 2>/dev/null
    if [ -f "$marker" ]; then
        local last
        last=$(cat "$marker" 2>/dev/null)
        [ $((now - ${last:-0})) -lt 60 ] && return
    fi
    echo "$now" > "$marker"
    local installer="${ADAPTER_INSTALLER}"
    if ! _check_hooks_integrity; then
        _ai_log "REPAIR: hooks integrity check failed, reinstalling (${TOOL_ID:-claude})"
        [ -x "$installer" ] && "$installer" >/dev/null 2>&1 || true
    fi
}
