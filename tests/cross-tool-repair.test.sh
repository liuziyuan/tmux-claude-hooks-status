#!/bin/bash
# tests/cross-tool-repair.test.sh — 安装意图标记 + 跨工具自修复 + 终态清理认 seen
#
# 背景：tmux 入口所有 _refresh/_session-switched 固定传 TOOL_ID=claude，codex/opencode
# 只有自身 SessionStart 能触发修复；hooks 文件被整体覆盖/删除后再无事件 → 永不自愈。
# 修复前提是「用户显式装过」（installed-<tool> 标记），避免给未安装的工具自动装 hooks。
#
# 隔离：HOME / TMUX_AI_SUPPRESS_DIR / TMUX_AI_STATUS_DIR 全部指向临时目录；
# tmux 命令用最小 stub 拦截（_refresh 的聚合与 display-message）。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

CLAUDE_WRAPPER="$ROOT/scripts/install-claude-hooks.sh"
CODEX_WRAPPER="$ROOT/scripts/install-codex-hooks.sh"
OPENCODE_WRAPPER="$ROOT/scripts/install-opencode-hooks.sh"
ENGINE="$ROOT/scripts/tmux-ai-status"

unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true
unset TMUX_AI_SUPPRESS_DIR TMUX_AI_FORCE_INSTALL || true

export HOME="$TEST_TMP/home"
export TMUX_AI_SUPPRESS_DIR="$TEST_TMP/suppress"
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
export FAKE_TMUX_DIR="$TEST_TMP/tmux"
mkdir -p "$HOME" "$TMUX_AI_SUPPRESS_DIR" "$TMUX_AI_STATUS_DIR" "$FAKE_TMUX_DIR"

# 最小 tmux stub：_refresh 会调 display-message / set-option / list-panes / refresh-client
tmux() {
    case "${1:-}" in
        display-message)
            case "${5:-}" in
                *'@ai_pane_status'*) : ;;
                *'session_name'*) printf '%s\n' 'test:1.1' ;;
            esac
            ;;
        set-option) : ;;
        list-panes) : ;;
        refresh-client) : ;;
        show-options) return 1 ;;
    esac
    return 0
}
export -f tmux

assert_eq() { [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "${2:-<empty>}" >&2; exit 1; }; }
assert_file() { [ -f "$1" ] || { printf 'FAIL: %s: %s 应存在\n' "$2" "$1" >&2; exit 1; }; }
assert_no_file() { [ ! -e "$1" ] || { printf 'FAIL: %s: %s 不应存在\n' "$2" "$1" >&2; exit 1; }; }

installed()  { printf '%s/installed-%s'  "$TMUX_AI_SUPPRESS_DIR" "$1"; }
suppressed() { printf '%s/suppressed-%s' "$TMUX_AI_SUPPRESS_DIR" "$1"; }
events()     { jq '.hooks | length' "$1" 2>/dev/null; }

# ── 用例 1: installed 标记生命周期 ──
# 三工具显式 install → 写标记；uninstall → 删标记 + 写 suppressed。
for pair in "claude:$CLAUDE_WRAPPER" "codex:$CODEX_WRAPPER" "opencode:$OPENCODE_WRAPPER"; do
    tool="${pair%%:*}"; wrapper="${pair#*:}"
    HOME="$TEST_TMP/h-$tool" bash "$wrapper" >/dev/null
    assert_file "$(installed "$tool")" "$tool install 应写 installed 标记"
    HOME="$TEST_TMP/h-$tool" bash "$wrapper" uninstall >/dev/null
    assert_no_file "$(installed "$tool")" "$tool uninstall 应删 installed 标记"
    assert_file "$(suppressed "$tool")" "$tool uninstall 应写 suppressed 标记"
done

# 显式 install 清 suppressed 并重新登记
HOME="$TEST_TMP/h-claude" bash "$CLAUDE_WRAPPER" >/dev/null
assert_no_file "$(suppressed claude)" "显式 install 应清 suppressed"
assert_file "$(installed claude)" "显式 install 应重新登记 installed"

# claude auto 的「已收敛跳过」路径也要补登记（老用户升级后没有标记）
rm -f "$(installed claude)"
HOME="$TEST_TMP/h-claude" bash "$CLAUDE_WRAPPER" auto >/dev/null
assert_file "$(installed claude)" "auto 已收敛路径应补登记 installed"

# auto 被 suppressed 拦截时不登记
rm -f "$(installed claude)"
: > "$(suppressed claude)"
HOME="$TEST_TMP/h-claude" bash "$CLAUDE_WRAPPER" auto >/dev/null
assert_no_file "$(installed claude)" "auto 被 suppressed 拦截时不应登记"

printf 'cross-tool-repair: all cases passed\n'
