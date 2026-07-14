#!/bin/bash
# install-codex-hooks.sh: 注册/卸载 Codex CLI hooks 到 ~/.codex/hooks.toml
# 用法: install-codex-hooks.sh [uninstall]
#
# Codex hooks (v0.117+): [hooks] 顶层表 + PascalCase 事件段 + handler type="command"，
# stdin 传 JSON（字段与 Claude Code 同构）。Codex 无 SessionEnd/Notification/
# PostToolUseFailure/StopFailure 事件，故只注册 6 个事件。
#
# 合并策略：本插件在 hooks.toml 中用 sentinel 注释块独占管理自己的段落，
# 块外的用户/其他工具内容原样保留。零外部依赖（纯 bash + awk，不需 TOML 库）。

set -o errexit
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK_SCRIPT="${SCRIPT_DIR}/tmux-ai-status"
HOOKS_FILE="${CODEX_HOME:-$HOME/.codex}/hooks.toml"

BEGIN_MARK="# >>> tmux-ai-hooks-status (managed) >>>"
END_MARK="# <<< tmux-ai-hooks-status (managed) <<<"

# Codex 支持的 6 个事件。PermissionRequest 同步（async=false）以即时显示 !/?，
# 其余 async=true 不阻塞会话。
_SYNC_EVENTS="PermissionRequest"

# 原子写入：同目录 mktemp → 同文件系统 → mv 原子
_atomic_write() {
    local content="$1" target="$2" tmp
    tmp=$(mktemp "$(dirname "$target")/.hooks.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    mv -f "$tmp" "$target"
}

# 剥离已有的 managed 块（含标记行），返回块外内容
_strip_managed_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        skip==0 {print}
    ' "$file"
}

# 生成本插件的 managed 块（6 个事件段）
_gen_managed_block() {
    local event async cmd
    printf '%s\n' "$BEGIN_MARK"
    printf '# 由 install-codex-hooks.sh 自动生成，请勿手动编辑本块内容。\n'
    for event in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop; do
        case " $_SYNC_EVENTS " in
            *" $event "*) async="false" ;;
            *)            async="true" ;;
        esac
        cmd="${HOOK_SCRIPT} codex ${event}"
        printf '\n[[hooks.%s]]\n' "$event"
        printf '[[hooks.%s.hooks]]\n' "$event"
        printf 'type = "command"\n'
        printf 'command = "%s"\n' "$cmd"
        printf 'timeout = 5\n'
        printf 'async = %s\n' "$async"
    done
    printf '%s\n' "$END_MARK"
}

# 确保 ~/.codex 目录存在
mkdir -p "$(dirname "$HOOKS_FILE")" 2>/dev/null || true

ACTION="${1:-install}"

if [ "$ACTION" = "uninstall" ]; then
    if [ -f "$HOOKS_FILE" ]; then
        REMAINING=$(_strip_managed_block "$HOOKS_FILE")
        # 剥离后仅剩空白 → 删文件；否则写回块外内容
        if [ -z "$(printf '%s' "$REMAINING" | tr -d '[:space:]')" ]; then
            rm -f "$HOOKS_FILE"
            echo "Codex hooks uninstalled (removed empty $HOOKS_FILE)"
        else
            _atomic_write "$REMAINING" "$HOOKS_FILE"
            echo "Codex hooks uninstalled from $HOOKS_FILE (preserved external content)"
        fi
    else
        echo "Codex hooks: nothing to uninstall ($HOOKS_FILE not found)"
    fi
    exit 0
fi

# 安装：块外内容 + 新 managed 块
OUTSIDE=$(_strip_managed_block "$HOOKS_FILE")
BLOCK=$(_gen_managed_block)

if [ -n "$(printf '%s' "$OUTSIDE" | tr -d '[:space:]')" ]; then
    # 保留块外内容，其后追加 managed 块（去除块外尾部多余空行）
    NEW_CONTENT="$(printf '%s\n' "$OUTSIDE" | sed -e :a -e '/^\n*$/{$d;N;ba}')

${BLOCK}"
else
    NEW_CONTENT="$BLOCK"
fi

_atomic_write "$NEW_CONTENT" "$HOOKS_FILE"

echo "Codex hooks installed to $HOOKS_FILE"
echo "Events: SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"
