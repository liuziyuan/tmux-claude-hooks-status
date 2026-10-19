#!/bin/bash
# tests/pid-tree.test.sh — 进程树 BFS（快照注入）与前缀匹配语义
#
# 只用注入的进程快照验证，不依赖真实进程；覆盖 _pid_tree_has_names 的
# 精确/前缀匹配、多级 BFS、不命中，以及批量版 _pid_trees_hits 的输出契约。
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export TMUX_AI_STATUS_DIR=$(mktemp -d)
trap 'rm -rf "$TMUX_AI_STATUS_DIR"' EXIT

unset TMUX || true
tmux() { return 0; }  # source 期间不应触碰真实 tmux

TOOL_ID="claude"
EVENT="PreToolUse"
source "$ROOT/scripts/lib-tmux-ai-status.sh"

fail=0
assert_rc() {  # $1=期望 rc $2=实际 rc $3=场景
    [ "$2" = "$1" ] || { printf 'FAIL: %s (expected rc=%s, got %s)\n' "$3" "$1" "$2" >&2; fail=1; }
}

# 1(launchd) → 100(shell) → 200(codex-aarch64-*)；300 为无关进程
SNAP='1 0 /sbin/launchd
100 1 /bin/bash
200 100 /opt/codex-aarch64-apple-darwin
300 1 /usr/bin/vim'

_pid_tree_has_names 100 codex "$SNAP";    assert_rc 0 $? "前缀匹配 codex-aarch64-*"
_pid_tree_has_names 100 opencode "$SNAP"; assert_rc 1 $? "不命中其他工具"
_pid_tree_has_names 100 bash "$SNAP";     assert_rc 0 $? "精确匹配 bash"
_pid_tree_has_names 999 codex "$SNAP";    assert_rc 1 $? "不存在的 root"
_pid_tree_has_names 1 codex "$SNAP";      assert_rc 0 $? "多级 BFS（从 launchd 根）"

# 批量版：只输出命中行 "pid<TAB>name"
out=$(_pid_trees_hits "100 999" "codex opencode" "$SNAP")
expected=$(printf '100\tcodex')
[ "$out" = "$expected" ] || { printf 'FAIL: 批量输出\n期望: %q\n实际: %q\n' "$expected" "$out" >&2; fail=1; }

out=$(_pid_trees_hits "" "codex" "$SNAP")
[ -z "$out" ] || { printf 'FAIL: 空 roots 应无输出，实际: %q\n' "$out" >&2; fail=1; }

[ "$fail" = 0 ] && echo "PASS: pid-tree 用例全部通过"
exit "$fail"
