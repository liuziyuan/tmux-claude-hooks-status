#!/bin/bash
# tests/symlink-write.test.sh — 原子写/删除必须写穿符号链接
#
# 背景：cc-switch 为每个 codex provider 建独立 CODEX_HOME，并把 hooks.json 做成
# 指向 ~/.codex/hooks.json 的符号链接（所有实例共享同一真源）。mv 直接作用于
# 链接路径时只替换链接本身（POSIX rename 语义），导致实例与真源分叉、文档承诺
# 的「所有实例共享同一真源」失效。
#
# 覆盖：install 写穿绝对/相对/悬空链接并保留链接、多实例共享同一真源、
# uninstall 删真实目标而保留链接、循环链接快速回退不挂死、opencode plugin 同构。
# 隔离方式同 check-json.test.sh：HOME / CODEX_HOME / OPENCODE_CONFIG_DIR /
# XDG_CONFIG_HOME 全部指向临时目录。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

W_CODEX="$ROOT/scripts/install-codex-hooks.sh"
W_OPENCODE="$ROOT/scripts/install-opencode-hooks.sh"

unset TMUX_AI_SUPPRESS_DIR TMUX_AI_FORCE_INSTALL || true
unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR || true
export XDG_CONFIG_HOME="$TEST_TMP/xdg"
mkdir -p "$XDG_CONFIG_HOME"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_link() { [ -L "$1" ] || fail "$2: $1 应仍是符号链接（实际被替换为普通文件）"; }
assert_present() { [ -e "$1" ] || fail "$2: $1 应存在"; }
assert_absent() { [ ! -e "$1" ] || fail "$2: $1 应不存在"; }
assert_events() {  # $1=文件 $2=上下文
    [ "$(jq '.hooks | length' "$1" 2>/dev/null)" = "6" ] \
        || fail "$2: 真源应含 6 个事件（实际 $(jq -c '.hooks | keys' "$1" 2>/dev/null)）"
}

# ── 用例 1: install 写穿绝对符号链接，链接本身保留 ──
H="$TEST_TMP/h1"; mkdir -p "$H/.codex"
SHARED="$TEST_TMP/shared/hooks.json"; mkdir -p "$(dirname "$SHARED")"
printf '{}\n' > "$SHARED"
export HOME="$H"
export CODEX_HOME="$H/.codex"
ln -s "$SHARED" "$CODEX_HOME/hooks.json"

bash "$W_CODEX" >/dev/null
assert_link "$CODEX_HOME/hooks.json" "绝对链接"
[ "$(readlink "$CODEX_HOME/hooks.json")" = "$SHARED" ] \
    || fail "绝对链接: readlink 目标不应改变（got $(readlink "$CODEX_HOME/hooks.json"))"
assert_events "$SHARED" "绝对链接"
[ ! -L "$SHARED" ] || fail "绝对链接: 共享真源本身不应变成链接"
bash "$W_CODEX" check >/dev/null || fail "绝对链接: install 后 check 应为 ok"

# ── 用例 2: 第二个实例指向同一真源 → no-op，仍共享一份 ──
H2="$TEST_TMP/h2"; mkdir -p "$H2/.codex"
HOME="$H2" CODEX_HOME="$H2/.codex" ln -s "$SHARED" "$H2/.codex/hooks.json"
HOME="$H2" CODEX_HOME="$H2/.codex" bash "$W_CODEX" >/dev/null
assert_link "$H2/.codex/hooks.json" "第二实例"
[ "$(readlink "$H2/.codex/hooks.json")" = "$SHARED" ] || fail "第二实例: readlink 目标应不变"
assert_events "$SHARED" "第二实例"
[ "$(find "$TEST_TMP" -name '.hooks.*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
    || fail "第二实例: 不应残留临时文件"

# ── 用例 3: 悬空符号链接（target 尚不存在）→ 创建真实目标，链接保留 ──
H3="$TEST_TMP/h3"; mkdir -p "$H3/.codex"
MISSING="$TEST_TMP/missing-dir/hooks.json"
HOME="$H3" CODEX_HOME="$H3/.codex" ln -s "$MISSING" "$H3/.codex/hooks.json"
HOME="$H3" CODEX_HOME="$H3/.codex" bash "$W_CODEX" >/dev/null
assert_link "$H3/.codex/hooks.json" "悬空链接"
assert_present "$MISSING" "悬空链接: 真实目标应被创建"
assert_events "$MISSING" "悬空链接"

# ── 用例 4: 相对符号链接 → 基于链接所在目录解析 ──
mkdir -p "$TEST_TMP/rel/a" "$TEST_TMP/rel/b"
printf '{}\n' > "$TEST_TMP/rel/b/hooks.json"
ln -s ../b/hooks.json "$TEST_TMP/rel/a/hooks.json"
HOME="$H3" CODEX_HOME="$TEST_TMP/rel/a" bash "$W_CODEX" >/dev/null
assert_link "$TEST_TMP/rel/a/hooks.json" "相对链接"
[ "$(readlink "$TEST_TMP/rel/a/hooks.json")" = "../b/hooks.json" ] \
    || fail "相对链接: readlink 应保持相对目标"
assert_events "$TEST_TMP/rel/b/hooks.json" "相对链接"

# ── 用例 5: uninstall 清空（只含本插件）→ 删真实目标、保留链接 ──
H5="$TEST_TMP/h5"; mkdir -p "$H5/.codex"
SHARED5="$TEST_TMP/shared5/hooks.json"; mkdir -p "$(dirname "$SHARED5")"
printf '{}\n' > "$SHARED5"
HOME="$H5" CODEX_HOME="$H5/.codex" ln -s "$SHARED5" "$H5/.codex/hooks.json"
HOME="$H5" CODEX_HOME="$H5/.codex" bash "$W_CODEX" >/dev/null
HOME="$H5" CODEX_HOME="$H5/.codex" bash "$W_CODEX" uninstall >/dev/null
assert_link "$H5/.codex/hooks.json" "uninstall 清空"
assert_absent "$SHARED5" "uninstall 清空: 真实目标应被删除（链接指向悬空）"
# 再次 install 应写穿悬空链接恢复共享，而不是把链接换成普通文件
HOME="$H5" CODEX_HOME="$H5/.codex" bash "$W_CODEX" >/dev/null
assert_link "$H5/.codex/hooks.json" "重新 install"
assert_events "$SHARED5" "重新 install"

# ── 用例 6: uninstall 保留他人 hook → 真源写回他人内容，链接保留 ──
H6="$TEST_TMP/h6"; mkdir -p "$H6/.codex"
SHARED6="$TEST_TMP/shared6/hooks.json"; mkdir -p "$(dirname "$SHARED6")"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other-tool run"}]}]}}' > "$SHARED6"
HOME="$H6" CODEX_HOME="$H6/.codex" ln -s "$SHARED6" "$H6/.codex/hooks.json"
HOME="$H6" CODEX_HOME="$H6/.codex" bash "$W_CODEX" >/dev/null
HOME="$H6" CODEX_HOME="$H6/.codex" bash "$W_CODEX" uninstall >/dev/null
assert_link "$H6/.codex/hooks.json" "uninstall 保留他人"
[ -f "$SHARED6" ] || fail "uninstall 保留他人: 真源不应被删"
[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$SHARED6")" = "other-tool run" ] \
    || fail "uninstall 保留他人: 他人 hook 应保留"

# ── 用例 7: 循环符号链接（a→b→a）→ 解析失败快速回退，不挂死 ──
H7="$TEST_TMP/h7"; mkdir -p "$H7/.codex"
ln -s b "$H7/.codex/a"
ln -s a "$H7/.codex/b"
ln -s a "$H7/.codex/hooks.json"
HOME="$H7" CODEX_HOME="$H7/.codex" bash "$W_CODEX" >/dev/null 2>&1 \
    || fail "循环链接: install 不应失败/挂死"
[ ! -L "$H7/.codex/hooks.json" ] || fail "循环链接: 解析失败应回退原路径写入（链接被替换）"
assert_events "$H7/.codex/hooks.json" "循环链接"

# ── 用例 8: opencode plugin 同构（install 写穿 + uninstall 删目标留链接）──
H8="$TEST_TMP/h8"; mkdir -p "$H8"
export HOME="$H8"
OC_DIR="$TEST_TMP/opencode"; mkdir -p "$OC_DIR/plugins"
OC_SHARED="$TEST_TMP/oc-shared/plugin.ts"; mkdir -p "$(dirname "$OC_SHARED")"
: > "$OC_SHARED"
ln -s "$OC_SHARED" "$OC_DIR/plugins/tmux-ai-status.ts"
OPENCODE_CONFIG_DIR="$OC_DIR" bash "$W_OPENCODE" >/dev/null
assert_link "$OC_DIR/plugins/tmux-ai-status.ts" "opencode install"
grep -q "tmux-ai-status (managed by tmux-ai-hooks-status)" "$OC_SHARED" \
    || fail "opencode install: 插件内容应写入共享真源"
OPENCODE_CONFIG_DIR="$OC_DIR" bash "$W_OPENCODE" uninstall >/dev/null
assert_link "$OC_DIR/plugins/tmux-ai-status.ts" "opencode uninstall"
assert_absent "$OC_SHARED" "opencode uninstall: 真实目标应被删除"

printf 'symlink-write: all cases passed\n'
