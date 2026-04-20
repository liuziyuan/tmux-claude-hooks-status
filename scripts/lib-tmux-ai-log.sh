#!/bin/bash
# lib-tmux-ai-log.sh: 轻量日志模块 — 直接 O_APPEND 追加 + 原子轮转
# 被 lib-tmux-ai-status.sh source
# 调用方需设置: TOOL_ID ("claude")、EVENT、_pane_loc

AI_LOG_FILE="/tmp/tmux-ai-status.log"
AI_LOG_MAX_SIZE=102400   # 100KB 触发轮转
AI_LOG_KEEP_SIZE=51200   # 轮转后保留尾部 50KB
AI_LOG_LOCK_DIR="${AI_LOG_FILE}.lock"

# 原子轮转（mkdir 作为互斥锁，多进程安全）
_ai_log_rotate() {
    mkdir "$AI_LOG_LOCK_DIR" 2>/dev/null || return 0
    local cur_size
    cur_size=$(wc -c < "$AI_LOG_FILE" 2>/dev/null || echo 0)
    if [ "${cur_size:-0}" -gt "$AI_LOG_MAX_SIZE" ]; then
        local tmp="${AI_LOG_FILE}.tmp.$$"
        if tail -c "$AI_LOG_KEEP_SIZE" "$AI_LOG_FILE" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$AI_LOG_FILE" 2>/dev/null
        fi
        rm -f "$tmp"
    fi
    rmdir "$AI_LOG_LOCK_DIR" 2>/dev/null
}

_ai_log() {
    local B=$'\033[1;36m' R=$'\033[0m'
    local msg="[$(date '+%Y-%m-%dT%H:%M:%S')] [${TOOL_ID:-?}] [${B}${EVENT:-?}${R}] [${_pane_loc:-${TMUX_PANE:-?}}] $*"

    # 首次创建时限制权限（避免 /tmp 下日志对其它用户可读）
    [ -f "$AI_LOG_FILE" ] || (umask 077; : >> "$AI_LOG_FILE")

    # POSIX O_APPEND 对单行 ≤PIPE_BUF (≥4096B) 写入保证原子，多进程无需额外锁
    printf '%s\n' "$msg" >> "$AI_LOG_FILE" 2>/dev/null

    # 按需轮转（单次 wc -c 开销微小，hook 每次只调一次 _ai_log）
    local fsize
    fsize=$(wc -c < "$AI_LOG_FILE" 2>/dev/null || echo 0)
    [ "${fsize:-0}" -gt "$AI_LOG_MAX_SIZE" ] && _ai_log_rotate
}
