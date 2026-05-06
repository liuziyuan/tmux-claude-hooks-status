#!/bin/bash
# install-claude-hooks.sh: 自动注册/卸载 Claude Code hooks 到 ~/.claude/settings.json
# 用法: install-claude-hooks.sh [uninstall]
#
# 所有 settings.json 写入使用原子操作（单次 jq pipeline + mktemp + mv），
# 避免与 Claude Code 并发写产生竞态导致 hooks 字段丢失。

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK_SCRIPT="${SCRIPT_DIR}/tmux-claude-status"
SETTINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# 原子写入：mktemp 与目标同目录 → 同文件系统 → mv 原子
_atomic_write() {
    local content="$1" target="$2"
    local tmp
    tmp=$(mktemp -p "$(dirname "$target")" .settings.XXXXXX)
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}

# 检查依赖
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required. Install with: brew install jq"
    exit 1
fi

# 确保 settings.json 存在
if [ ! -f "$SETTINGS_FILE" ]; then
    _atomic_write '{}' "$SETTINGS_FILE"
fi

ACTION="${1:-install}"

if [ "$ACTION" = "uninstall" ]; then
    # 卸载：单次 jq pipeline 移除所有指向本插件的 hooks
    UPDATED=$(jq --arg hook_script "$HOOK_SCRIPT" '
        .hooks |= if . then
            [. | to_entries[] |
                .value |= [
                    .[] | .hooks = [.hooks[] | select(.command | startswith($hook_script) | not)]
                    | select(.hooks | length > 0)
                ]
                | select(.value | length > 0)
            ] | from_entries
        else . end
    ' "$SETTINGS_FILE")
    _atomic_write "$UPDATED" "$SETTINGS_FILE"
    echo "Claude hooks uninstalled from $SETTINGS_FILE"
    exit 0
fi

# 清理 + 安装：合并为单次 jq pipeline，一次性原子写入
UPDATED=$(jq --arg dev_script "$HOOK_SCRIPT" '
    # 10 个目标事件
    ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
     "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"] as $events |

    # async=false 的事件集合
    ["PermissionRequest"] as $sync_events |

    reduce $events[] as $event (
        {};

        . as $acc |
        (.[$event] // []) |
        map(
            .hooks = [
                .hooks[]
                | select(.command | contains("tmux-powerline-claude-status") | not)
                | select(
                    (.command | contains("tmux-claude-status") | not)
                    or (.command | startswith($dev_script))
                )
            ]
            | select(.hooks | length > 0)
        ) as $cleaned |

        ($dev_script + " " + $event) as $hook_cmd |
        ([$cleaned[]?.hooks[]?.command] | index($hook_cmd)) as $idx |

        if $idx != null then $cleaned
        else $cleaned + [{
            "hooks": [{
                "async": (($event | IN($sync_events[])) | not),
                "command": $hook_cmd,
                "type": "command"
            }],
            "matcher": ""
        }]
        end
        | $acc + {($event): .}
    ) as $new_hooks |

    . + {hooks: $new_hooks}
' "$SETTINGS_FILE")

_atomic_write "$UPDATED" "$SETTINGS_FILE"

echo "Claude hooks installed to $SETTINGS_FILE"
echo "Events: SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure"
