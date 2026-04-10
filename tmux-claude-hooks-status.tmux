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
    if tmux show-option -g status-right 2>/dev/null | grep -q "powerline"; then
        MODE="powerline"
    else
        MODE="native"
    fi
fi

if [ "$MODE" = "powerline" ]; then
    # Powerline 模式：在 powerline 之前插入 Claude 状态
    # 需要在 TPM/powerline 初始化之后才能正确读取 powerline 路径
    # 使用 delayed source 确保 powerline 已设置
    tmux set-option -g status-right-length 120 2>/dev/null || true
    tmux set-option -g status-right "#{?#{@claude_all_status},#{@claude_all_status} ,}#(ls ~/.tmux/plugins/tmux-powerline/powerline.sh 2>/dev/null && ~/.tmux/plugins/tmux-powerline/powerline.sh right || echo '')" 2>/dev/null || true
else
    # Native 模式：独立 status-right
    tmux set-option -g status-right-length 120 2>/dev/null || true
    tmux set-option -g status-right "#(${CURRENT_DIR}/scripts/tmux-native-claude-status)" 2>/dev/null || true
fi

# --- 快捷键绑定 ---
# prefix + C-h: 安装 hooks 到 ~/.claude/settings.json
tmux bind-key C-h run-shell "${CURRENT_DIR}/scripts/install-hooks.sh && tmux display 'Claude hooks installed'"
# prefix + C-u: 卸载 hooks
tmux bind-key C-u run-shell "${CURRENT_DIR}/scripts/install-hooks.sh uninstall && tmux display 'Claude hooks removed'"
