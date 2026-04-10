#!/bin/bash
# install-hooks.sh: 自动注册/卸载 Claude Code hooks 到 ~/.claude/settings.json
# 用法: install-hooks.sh [uninstall]

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="${SCRIPT_DIR}/tmux-powerline-claude-status"
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# 需要注册的事件列表
EVENTS=(
    "SessionStart"
    "SessionEnd"
    "UserPromptSubmit"
    "PreToolUse"
    "PostToolUse"
    "PostToolUseFailure"
    "PermissionRequest"
    "Notification"
    "Stop"
    "StopFailure"
)

# 检查依赖
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install with: brew install jq"
    exit 1
fi

# 确保 settings.json 存在
if [ ! -f "$SETTINGS_FILE" ]; then
    echo "{}" > "$SETTINGS_FILE"
fi

# 确保 hooks 字段存在
if [ "$(jq 'has("hooks")' "$SETTINGS_FILE")" = "false" ]; then
    UPDATED=$(jq '. + {"hooks": {}}' "$SETTINGS_FILE")
    echo "$UPDATED" > "$SETTINGS_FILE"
fi

ACTION="${1:-install}"

if [ "$ACTION" = "uninstall" ]; then
    # 卸载：移除所有指向本插件的 hooks（匹配 "script event" 或旧版无参数格式）
    for EVENT in "${EVENTS[@]}"; do
        UPDATED=$(jq --arg event "$EVENT" --arg hook_script "$HOOK_SCRIPT" '
            .hooks[$event] = [
                .hooks[$event][]?
                | .hooks = [.hooks[] | select(.command | startswith($hook_script) | not)]
            ] | .hooks[$event] = [.hooks[$event][] | select(.hooks | length > 0)]
        ' "$SETTINGS_FILE")
        echo "$UPDATED" > "$SETTINGS_FILE"
    done
    echo "Claude hooks uninstalled from $SETTINGS_FILE"
    exit 0
fi

# 安装：为每个事件添加 hook（幂等，不重复添加）
for EVENT in "${EVENTS[@]}"; do
    # 判断该事件是否需要 async
    case "$EVENT" in
        PermissionRequest) ASYNC="false" ;;
        SessionEnd)        ASYNC="true" ;;
        Stop|StopFailure)  ASYNC="true" ;;
        *)                 ASYNC="true" ;;
    esac

    HOOK_COMMAND="$HOOK_SCRIPT $EVENT"

    # 检查是否已存在（避免重复添加）
    EXISTS=$(jq --arg event "$EVENT" --arg hook_command "$HOOK_COMMAND" '
        [.hooks[$event][]?.hooks[]?.command // empty] | map(select(. == $hook_command)) | length
    ' "$SETTINGS_FILE")

    if [ "$EXISTS" != "0" ]; then
        continue
    fi

    UPDATED=$(jq --arg event "$EVENT" \
        --arg hook_command "$HOOK_COMMAND" \
        --argjson async "$ASYNC" '
        .hooks[$event] = (.hooks[$event] // []) + [{
            "hooks": [{"async": $async, "command": $hook_command, "type": "command"}],
            "matcher": ""
        }]
    ' "$SETTINGS_FILE")
    echo "$UPDATED" > "$SETTINGS_FILE"
done

echo "Claude hooks installed to $SETTINGS_FILE"
echo "Events: ${EVENTS[*]}"
