#!/bin/bash
# install-copilot-hooks.sh: 自动注册/卸载 Copilot CLI hooks
# 用法: install-copilot-hooks.sh [uninstall]

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_NAME="tmux-ai-status"
HOOK_SCRIPT="${SCRIPT_DIR}/tmux-copilot-status"
COPILOT_CONFIG_DIR="${COPILOT_CONFIG_DIR:-$HOME/.copilot}"

# 检查 copilot CLI 是否可用
_copilot_cli() {
    if command -v copilot &>/dev/null; then
        echo "copilot"
    elif command -v gh &>/dev/null; then
        # gh copilot 代理模式
        echo "gh copilot --"
    else
        return 1
    fi
}

ACTION="${1:-install}"

if [ "$ACTION" = "uninstall" ]; then
    COP=$(_copilot_cli) || { echo "INFO: copilot CLI not found, skipping uninstall"; exit 0; }
    $COP plugin uninstall "$PLUGIN_NAME" 2>/dev/null || true
    # 也清理直接安装的残留
    rm -rf "${COPILOT_CONFIG_DIR}/installed-plugins/_direct/${PLUGIN_NAME}" 2>/dev/null || true
    rm -rf "${COPILOT_CONFIG_DIR}/state/installed-plugins/${PLUGIN_NAME}" 2>/dev/null || true
    echo "Copilot hooks uninstalled"
    exit 0
fi

# 安装：在临时目录动态生成 plugin.json 和 hooks.json
PLUGIN_DIR=$(mktemp -d)
trap "rm -rf '$PLUGIN_DIR'" EXIT

cat > "${PLUGIN_DIR}/plugin.json" << EOF
{
  "name": "${PLUGIN_NAME}",
  "description": "tmux status bar integration for AI CLI tools",
  "version": "1.0.0",
  "hooks": "hooks.json"
}
EOF

cat > "${PLUGIN_DIR}/hooks.json" << EOF
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      { "bash": "${HOOK_SCRIPT} SessionStart", "type": "command" }
    ],
    "sessionEnd": [
      { "bash": "${HOOK_SCRIPT} SessionEnd", "type": "command" }
    ],
    "userPromptSubmit": [
      { "bash": "${HOOK_SCRIPT} UserPromptSubmit", "type": "command" }
    ],
    "preToolUse": [
      { "bash": "${HOOK_SCRIPT} PreToolUse", "type": "command" }
    ],
    "postToolUse": [
      { "bash": "${HOOK_SCRIPT} PostToolUse", "type": "command" }
    ],
    "errorOccurred": [
      { "bash": "${HOOK_SCRIPT} ErrorOccurred", "type": "command" }
    ]
  }
}
EOF

# 尝试使用 copilot plugin install
COP=$(_copilot_cli) || { echo "INFO: copilot CLI not found, skipping Copilot hooks installation"; exit 0; }

if $COP plugin list 2>/dev/null | grep -q "$PLUGIN_NAME"; then
    # 已安装，先卸载再重装以确保 hooks.json 更新
    $COP plugin uninstall "$PLUGIN_NAME" 2>/dev/null || true
fi

if $COP plugin install "$PLUGIN_DIR" 2>/dev/null; then
    echo "Copilot hooks installed via plugin system"
else
    # 回退：直接复制到 copilot 插件目录
    DEST_DIR="${COPILOT_CONFIG_DIR}/installed-plugins/_direct/${PLUGIN_NAME}"
    mkdir -p "$DEST_DIR"
    cp "${PLUGIN_DIR}/plugin.json" "${DEST_DIR}/"
    cp "${PLUGIN_DIR}/hooks.json" "${DEST_DIR}/"
    echo "Copilot hooks installed to $DEST_DIR (fallback)"
fi
