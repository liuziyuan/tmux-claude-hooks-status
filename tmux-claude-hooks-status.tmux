#!/usr/bin/env bash
# tmux-claude-hooks-status: Claude Code hooks status for tmux
# TPM entry point

set -o errexit
set -o pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 可自定义选项 ---
STATUS_COLOR=$(tmux show-option -gv @claude_hooks_status_color 2>/dev/null || echo "#F1FA8C")
IDLE_ICON=$(tmux show-option -gv @claude_hooks_idle_icon 2>/dev/null || echo "✓")
BUSY_ICON=$(tmux show-option -gv @claude_hooks_busy_icon 2>/dev/null || echo "⠿")
AUTH_ICON=$(tmux show-option -gv @claude_hooks_auth_icon 2>/dev/null || echo "🔒")

# --- 通用设置：pane 边框样式 ---
tmux set-option -g pane-border-status top 2>/dev/null || true
tmux set-option -g pane-border-format " #P #{pane_title} " 2>/dev/null || true
tmux set-option -g pane-active-border-style "fg=#BD93F9" 2>/dev/null || true
tmux set-option -g pane-border-style "fg=#6272A4" 2>/dev/null || true

# --- 多行状态栏：动态追加 AI 状态行 ---
# 读取当前行数（其他插件已设置好的），追加到最后一行的下一行
# 幂等检测：扫描所有行，查找已含 @ai_all_status 签名的行，直接复用，
# 不再追加——这样手动重载脚本不会累计增加行数
_cur_status=$(tmux show-option -gv status 2>/dev/null || echo "on")
case "$_cur_status" in
    on)     _cur_rows=1 ;;
    off)    _cur_rows=0 ;;
    [0-9]*) _cur_rows=$((_cur_status + 0)) ;;
    *)      _cur_rows=1 ;;
esac
CLAUDE_ROW=""
for _i in $(seq 0 $((_cur_rows - 1))); do
    _fmt=$(tmux show-option -gv "status-format[${_i}]" 2>/dev/null || true)
    if echo "$_fmt" | grep -q "@ai_all_status"; then
        CLAUDE_ROW=$_i
        break
    fi
done
if [ -z "$CLAUDE_ROW" ]; then
    CLAUDE_ROW=$_cur_rows
    tmux set-option -g status $((_cur_rows + 1)) 2>/dev/null || true
fi
tmux set-option -g "status-format[${CLAUDE_ROW}]" "#[align=centre]#{?#{@ai_all_status},#{T:@ai_all_status},}" 2>/dev/null || true

# 不动 status-right，让用户自行管理第 1 行内容
# Claude 状态通过多行 status-format 的独立行显示，不修改 status-right

# --- Reload 保护：覆盖 prefix+r reload 绑定，source-file 后追加本插件初始化 ---
# 用哨兵变量防止重复覆盖（tmux server 生命周期内只覆盖一次）
# 注意：不能在 shell CLI 中用 \; 分隔多条 tmux 命令传给 bind-key，
# 因为 tmux CLI 会将 \; 作为命令分隔符立即执行后续命令（而不是绑定到按键）。
# 解决方案：写入临时 tmux config 文件再 source，确保 \; 被 tmux config parser 正确处理。
if [ -z "$(tmux show-option -gv @claude_hooks_reload_registered 2>/dev/null)" ]; then
    _bind_tmpfile=$(mktemp /tmp/tmux-claude-bind-XXXXXX.conf)
    printf "bind-key r source-file ~/.tmux.conf \\; run-shell '%s' \\; display-message '配置已重载'\n" \
        "${CURRENT_DIR}/tmux-claude-hooks-status.tmux" > "$_bind_tmpfile"
    tmux source-file "$_bind_tmpfile" 2>/dev/null || true
    rm -f "$_bind_tmpfile"
    tmux set-option -g @claude_hooks_reload_registered "1"
fi

# --- 自动注册 hooks（幂等，每次插件加载时确保 hooks 存在）---
"${CURRENT_DIR}/scripts/install-claude-hooks.sh" >/dev/null 2>&1 || true

# --- 注册 tmux session/client 变化 hook，刷新聚合状态 ---
# session-closed: session 被销毁时清除残留条目
# client-detached: client 断开连接时排除已变为 detached 的 session
# client-attached: client 重新连接时恢复该 session 的状态
tmux set-hook -g session-closed    "run-shell '${CURRENT_DIR}/scripts/tmux-claude-status _refresh'"
tmux set-hook -g client-detached   "run-shell '${CURRENT_DIR}/scripts/tmux-claude-status _refresh'"
tmux set-hook -g client-attached   "run-shell '${CURRENT_DIR}/scripts/tmux-claude-status _refresh'"
# pane-exited: 程序自然退出 → 触发孤儿清理（#{pane_id} 在此 hook 中不可靠）
tmux set-hook -g pane-exited       "run-shell '${CURRENT_DIR}/scripts/tmux-claude-status _refresh'"
# after-kill-pane: kill-pane 后触发孤儿清理
tmux set-hook -g after-kill-pane   "run-shell '${CURRENT_DIR}/scripts/tmux-claude-status _refresh'"

# --- 快捷键绑定 ---
# prefix + C-h: 安装 Claude hooks 到 ~/.claude/settings.json
tmux bind-key C-h run-shell "${CURRENT_DIR}/scripts/install-claude-hooks.sh && tmux display 'Claude hooks installed'"
# prefix + C-u: 卸载 Claude hooks
tmux bind-key C-u run-shell "${CURRENT_DIR}/scripts/install-claude-hooks.sh uninstall && tmux display 'Claude hooks removed'"
