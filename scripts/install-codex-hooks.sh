#!/bin/bash
# install-codex-hooks.sh: 注册/卸载 Codex CLI hooks 到 ~/.codex/hooks.json
# 用法: install-codex-hooks.sh [uninstall]
#
# Codex hooks (v0.144+): 独立 hooks.json 放在 config 文件夹（~/.codex/），
# 结构 { "hooks": { "<Event>": [ { "hooks": [ {type,command,timeout} ] } ] } }。
# stdin 传 JSON（字段与 Claude Code 同构）。Codex 无 SessionEnd/Notification/
# PostToolUseFailure/StopFailure 事件，故只注册 6 个事件。
#
# ⚠️ 0.144 三处 breaking change（相对旧 hooks.toml 方案）：
#   1. 不再读取独立 hooks.toml —— 仅认 config.toml [hooks] 表 或 config 文件夹里的 hooks.json
#   2. async=true 的 hook 被静默跳过（"async hooks are not supported yet"）—— 必须同步
#   3. 新增 hook trust：user 来源的 hook 需 hooks.state.<key>.trusted_hash 匹配才运行。
#      hash 算法（TOML 归一化指纹）无法在 bash 里可靠复现，故本脚本不预写 trusted_hash。
#      用户下次启动 codex TUI 会弹「Hooks need review → Trust all and continue」授信一次即永久生效。
#      （或以 codex --dangerously-bypass-hook-trust 启动跳过。）
#
# 合并策略：用 jq 读改写 hooks.json，仅替换本插件（command 含 "tmux-ai-status"）的 matcher
# group，保留用户/其他工具自有 hook。依赖 jq（本项目已依赖）。

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK_SCRIPT="${SCRIPT_DIR}/tmux-ai-status"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
HOOKS_FILE="${CODEX_DIR}/hooks.json"
LEGACY_TOML="${CODEX_DIR}/hooks.toml"

# Codex 支持的 6 个事件。全部同步（0.144 不支持 async hook）。
_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"

command -v jq >/dev/null 2>&1 || { echo "错误：install-codex-hooks.sh 需要 jq" >&2; exit 1; }

mkdir -p "$CODEX_DIR" 2>/dev/null || true

# 原子写入：同目录 mktemp → mv 原子
_atomic_write() {
    local content="$1" target="$2" tmp
    tmp=$(mktemp "$(dirname "$target")/.hooks.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}

# 读取现有 hooks.json（无/非法则空对象）
_read_existing() {
    if [ -f "$HOOKS_FILE" ] && jq empty "$HOOKS_FILE" >/dev/null 2>&1; then
        cat "$HOOKS_FILE"
    else
        echo '{}'
    fi
}

# 从每个事件数组里剔除本插件的 group（command 含 tmux-ai-status），返回清理后的 JSON。
# 事件清空后删掉键；.hooks 清空后删掉键。
_strip_managed() {
    jq '
      def clean_event:
        map(select(
          (.hooks // []) | any(.type == "command" and (.command // "" | contains("tmux-ai-status"))) | not
        ));
      if .hooks then
        .hooks |= (with_entries(.value |= clean_event) | with_entries(select(.value | length > 0)))
      else . end
      | if (.hooks // {}) == {} then del(.hooks) else . end
    '
}

ACTION="${1:-install}"

if [ "$ACTION" = "uninstall" ]; then
    [ -f "$LEGACY_TOML" ] && rm -f "$LEGACY_TOML" && echo "移除旧 hooks.toml"
    if [ -f "$HOOKS_FILE" ]; then
        STRIPPED=$(_read_existing | _strip_managed)
        # 剥离后是空对象 → 删文件；否则写回
        if [ "$(printf '%s' "$STRIPPED" | jq -c .)" = "{}" ]; then
            rm -f "$HOOKS_FILE"
            echo "Codex hooks uninstalled (removed empty $HOOKS_FILE)"
        else
            _atomic_write "$STRIPPED" "$HOOKS_FILE"
            echo "Codex hooks uninstalled from $HOOKS_FILE (preserved external content)"
        fi
    else
        echo "Codex hooks: nothing to uninstall ($HOOKS_FILE not found)"
    fi
    exit 0
fi

# 安装：清理旧 toml，剥离旧 managed group 后为每个事件追加本插件 group。
[ -f "$LEGACY_TOML" ] && rm -f "$LEGACY_TOML" && echo "移除旧 hooks.toml（0.144 不再读取）"

NEW_JSON=$(_read_existing | _strip_managed | jq \
    --arg script "$HOOK_SCRIPT" \
    --arg events "$_EVENTS" '
      .hooks //= {}
      | reduce ($events | split(" ")[]) as $ev (.;
          .hooks[$ev] = ((.hooks[$ev] // []) + [{
            hooks: [{ type: "command", command: ($script + " codex " + $ev), timeout: 5 }]
          }])
        )
    ')

_atomic_write "$NEW_JSON" "$HOOKS_FILE"

echo "Codex hooks installed to $HOOKS_FILE"
echo "Events: $_EVENTS"
echo ""
echo "⚠️  下次启动 codex 时 TUI 会提示 \"Hooks need review\"，选择 \"Trust all and continue\" 授信一次即可永久生效。"
