#!/usr/bin/env bash
# tmux-claude-hooks-status: Claude Code hooks status for tmux
# TPM entry point — auto-detects native/powerline mode

set -o errexit
set -o pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 可自定义选项 ---
STATUS_COLOR=$(tmux show-option -gv @claude_hooks_status_color 2>/dev/null || echo "#F1FA8C")
IDLE_ICON=$(tmux show-option -gv @claude_hooks_idle_icon 2>/dev/null || echo "✓")
BUSY_ICON=$(tmux show-option -gv @claude_hooks_busy_icon 2>/dev/null || echo "⠿")
AUTH_ICON=$(tmux show-option -gv @claude_hooks_auth_icon 2>/dev/null || echo "🔒")

# --- 通用设置：pane 边框显示 Claude 状态 ---
tmux set-option -g pane-border-status top 2>/dev/null || true
tmux set-option -g pane-border-format " #[fg=#BD93F9]#P#[default]#{?#{@claude_pane_status}, #[fg=${STATUS_COLOR}]#{@claude_pane_status}#[default],} #{pane_title} " 2>/dev/null || true
tmux set-option -g pane-active-border-style "fg=#BD93F9" 2>/dev/null || true
tmux set-option -g pane-border-style "fg=#6272A4" 2>/dev/null || true

# --- 模式检测 ---
MODE=$(tmux show-option -gv @claude_hooks_mode 2>/dev/null || true)
if [ -z "$MODE" ]; then
    if [ -x ~/.tmux/plugins/tmux-powerline/powerline.sh ] || tmux show-option -g status-right 2>/dev/null | grep -q "powerline"; then
        MODE="powerline"
    else
        MODE="native"
    fi
fi

# --- 多行状态栏：动态追加 Claude 状态行 ---
# 读取当前行数（其他插件已设置好的），追加到最后一行的下一行
# 幂等检测：若最后一行已含 @claude_all_status 签名，则为我们上次占用的行，直接复用，
# 不再追加——这样手动重载脚本不会累计增加行数
_cur_status=$(tmux show-option -gv status 2>/dev/null || echo "on")
case "$_cur_status" in
    on)     _cur_rows=1 ;;
    off)    _cur_rows=0 ;;
    [0-9]*) _cur_rows=$((_cur_status + 0)) ;;
    *)      _cur_rows=1 ;;
esac
_last_row=$((_cur_rows - 1))
_last_fmt=$(tmux show-option -gv "status-format[${_last_row}]" 2>/dev/null || true)
if echo "$_last_fmt" | grep -q "@claude_all_status"; then
    CLAUDE_ROW=$_last_row
else
    CLAUDE_ROW=$_cur_rows
    tmux set-option -g status $((_cur_rows + 1)) 2>/dev/null || true
fi
tmux set-option -g "status-format[${CLAUDE_ROW}]" "#[align=right]#{?#{@claude_all_status},#[fg=${STATUS_COLOR}]#{T:@claude_all_status}#[default],}" 2>/dev/null || true

# 鼠标点击状态栏跳转到对应 pane（需要: set -g mouse on）
# #[align=right] 内容触发 MouseDown1StatusRight；
# handler 内检查 % 前缀过滤掉非 pane-id 的点击，不干扰其他绑定
tmux bind-key -T root MouseDown1StatusRight \
    run-shell "${CURRENT_DIR}/scripts/status-click-handler.sh '#{mouse_status_range}'" 2>/dev/null || true

if [ "$MODE" = "powerline" ]; then
    # Powerline 模式：不动 status-right，让 powerline 完全管理第 1 行
    # 原先的 #(ls ... && powerline.sh right || true) 包装导致闪烁，已废弃：
    # tmux set-option -g status-right "#(ls ~/.tmux/plugins/tmux-powerline/powerline.sh 2>/dev/null && ~/.tmux/plugins/tmux-powerline/powerline.sh right || true)"
    true
else
    # Native 模式：第 1 行只显示时间，无 #(script) 调用
    tmux set-option -g status-right-length 250 2>/dev/null || true
    tmux set-option -g status-right "#[fg=#6272A4]%Y-%m-%d #[fg=#BD93F9]%H:%M" 2>/dev/null || true
fi

# --- Reload 保护：覆盖 prefix+r reload 绑定，source-file 后追加本插件初始化 ---
# 用哨兵变量防止重复覆盖（tmux server 生命周期内只覆盖一次）
if [ -z "$(tmux show-option -gv @claude_hooks_reload_registered 2>/dev/null)" ]; then
    tmux bind-key r source-file /Users/liuziyuan/.tmux.conf \; run-shell "'${CURRENT_DIR}/tmux-claude-hooks-status.tmux'" \; display-message "配置已重载"
    tmux set-option -g @claude_hooks_reload_registered "1"
fi

# --- 快捷键绑定 ---
# prefix + C-h: 安装 hooks 到 ~/.claude/settings.json
tmux bind-key C-h run-shell "${CURRENT_DIR}/scripts/install-hooks.sh && tmux display 'Claude hooks installed'"
# prefix + C-u: 卸载 hooks
tmux bind-key C-u run-shell "${CURRENT_DIR}/scripts/install-hooks.sh uninstall && tmux display 'Claude hooks removed'"
