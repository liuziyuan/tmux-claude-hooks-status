#!/bin/bash
# tests/pane-resolve.test.sh — resolve_tmux_pane 的有效性校验与多信号收敛
#
# 关键场景：codex managed daemon 的继承 TMUX_PANE 可能指向当前 server 中
# 真实存在但无关的 pane；祖先链不通时必须丢弃继承值，走映射/进程树/标题/cwd。
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

unset TMUX || true
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
mkdir -p "$TMUX_AI_STATUS_DIR"

# ── fake tmux：只实现 pane 解析用到的快照查询 ──
FAKE_SNAPSHOT=""
FAKE_SERVER_PID="1234"
tmux() {
    case "${1:-}" in
        list-panes)
            local fmt="${4:-}"
            [ -n "$FAKE_SNAPSHOT" ] || return 0
            case "$fmt" in
                *'#{pane_title}'*) printf '%s\n' "$FAKE_SNAPSHOT" ;;
            esac
            ;;
    esac
    return 0
}
export -f tmux

# ── source lib（TOOL_ID=codex）──
TOOL_ID="codex"
EVENT="PreToolUse"
source "$ROOT/scripts/lib-tmux-ai-status.sh"

# 保存 source 版真实现（下方 stub 会覆盖；末尾用例恢复验证快照爬链）
_REAL_ANCESTRY_FN=$(declare -f _pane_from_ancestry)

# 进程树模拟：FAKE_TREE 里列出的 pane_pid 视为有 codex 进程
FAKE_TREE=""
_pid_tree_has_names() {
    case " $FAKE_TREE " in *" $1 "*) return 0 ;; esac
    return 1
}

# 祖先链默认不通（模拟 daemon）；需要时用 override_ancestry 打开
_ancestry_result=""
_pane_from_ancestry() { [ -n "$_ancestry_result" ] && printf '%s' "$_ancestry_result" || return 1; }

assert_eq() {  # $1=expected $2=actual $3=ctx
    [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "${2:-<empty>}" >&2; exit 1; }
}

reset_case() {
    TMUX_PANE=""
    _TMUX_PANE_SOURCE=""
    SESSION_ID=""
    HOOK_CWD=""
    FAKE_SNAPSHOT=""
    FAKE_TREE=""
    _ancestry_result=""
    rm -rf "$TMUX_AI_STATUS_DIR"; mkdir -p "$TMUX_AI_STATUS_DIR"
}

# snapshot 行：pane|path|cmd|pane_pid|server|attached|title
pane_line() {  # $1=pane $2=pid $3=cmd $4=path $5=title $6=attached
    printf '%s|%s|%s|%s|%s|%s|%s' "$1" "${4:-/proj}" "${3:-codex}" "$2" "$FAKE_SERVER_PID" "${6:-1}" "${5:-}"
}

# ── 1: 祖先链命中 → 权威，即使继承值不同 ──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100)"; _ancestry_result='%16'
TMUX_PANE='%2'
resolve_tmux_pane
assert_eq '%16' "$TMUX_PANE" "ancestry overrides inherited"
assert_eq 'ancestry' "$_TMUX_PANE_SOURCE" "ancestry source"

# ── 2: daemon（祖先链不通）+ 单进程树候选 → 解析 ──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100)
$(pane_line '%17' 200 bash /proj2)"
FAKE_TREE="100"; TMUX_PANE='%29'
resolve_tmux_pane
assert_eq '%16' "$TMUX_PANE" "single process candidate"
assert_eq 'process' "$_TMUX_PANE_SOURCE" "process source"

# ── 3: 双候选 + adapter 标题提示 → 收窄 ──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100 codex /proj '✳ thread-A')
$(pane_line '%17' 200 codex /proj2 '✳ thread-B')"
FAKE_TREE="100 200"; SESSION_ID="sid-1"
adapter_pane_hints() { printf '%%17\n'; }
resolve_tmux_pane
assert_eq '%17' "$TMUX_PANE" "adapter title hint narrows"
unset -f adapter_pane_hints

# ── 4: 双候选 + cwd → 收窄 ──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100 codex /proj-a)
$(pane_line '%17' 200 codex /proj-b)"
FAKE_TREE="100 200"; HOOK_CWD="/proj-b/"
resolve_tmux_pane
assert_eq '%17' "$TMUX_PANE" "cwd narrows"

# ── 5: 仍多候选 → 不猜，且不创建状态目录 ──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100 codex /proj-a)
$(pane_line '%17' 200 codex /proj-b)"
FAKE_TREE="100 200"; HOOK_CWD="/elsewhere"
resolve_tmux_pane || true
assert_eq '' "$TMUX_PANE" "ambiguous stays unresolved"
[ ! -d "$TMUX_AI_STATUS_DIR/_16" ] && [ ! -d "$TMUX_AI_STATUS_DIR/_17" ] \
    || { echo "FAIL: unresolved 不应创建 pane 状态目录" >&2; exit 1; }

# ── 6: 映射缓存复用（meta 校验通过）──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100)"
FAKE_TREE="100"; SESSION_ID="sid-2"
resolve_tmux_pane
assert_eq '%16' "$TMUX_PANE" "precondition resolve"
_save_pane_id
# 第二次：进程树与祖先链都不可用，但映射仍有效
FAKE_TREE=""; TMUX_PANE='%99'; _ancestry_result=""
resolve_tmux_pane
assert_eq '%16' "$TMUX_PANE" "mapping reused"
assert_eq 'mapping' "$_TMUX_PANE_SOURCE" "mapping source"

# ── 7: server pid 变化 → 映射失效（不跨 server 误用）──
FAKE_SERVER_PID="9999"
FAKE_SNAPSHOT="$(pane_line '%16' 100)"
TMUX_PANE='%99'
resolve_tmux_pane || true
assert_eq '' "$TMUX_PANE" "stale mapping (server changed) rejected"
FAKE_SERVER_PID="1234"

# ── 8: 负缓存：失败后 5s 内不再扫描候选 ──
reset_case
FAKE_SNAPSHOT="$(pane_line '%16' 100 codex /proj-a)
$(pane_line '%17' 200 codex /proj-b)"
FAKE_TREE="100 200"; SESSION_ID="sid-3"
resolve_tmux_pane || true
scan_count=0
_pid_tree_has_names() { scan_count=$((scan_count + 1)); return 1; }
resolve_tmux_pane || true
assert_eq '0' "$scan_count" "negative cache skips scanning"

# ── 9: 标题/路径归一化 ──
assert_eq '回复问候' "$(_normalize_title '✳ 回复问候')" "title ✳ prefix"
assert_eq 'thread-A' "$(_normalize_title '*   thread-A ')" "title * prefix + spaces"
assert_eq "$PWD" "$(_normalize_path "$PWD/")" "path trailing slash"

# ── 10: 真实现快照爬链命中（eval 恢复 source 版）──
reset_case
eval "$_REAL_ANCESTRY_FN"
mypid=$$
_PANE_SNAPSHOT="$(pane_line '%42' "$mypid")"; _PANE_SNAPSHOT_OK=1
assert_eq '%42' "$(_pane_from_ancestry "4242 $mypid zsh")" "real ancestry: direct hit"

# ── 11: 真实现深度爬链（$$ → 500 → 400 → 300 → 100=pane_pid）──
_PANE_SNAPSHOT="$(pane_line '%42' 100)"
assert_eq '%42' "$(_pane_from_ancestry "500 400 a
400 300 b
300 100 c
100 1 init
$mypid 500 hook")" "real ancestry: deep walk"

# ── 11b: macOS 真实 ps 输出形态（pid 列右对齐 → 行带前导空格）──
# split 必须用单空格语义：正则 /[ \t]+/ 的首字段是空串，pid 全部错位丢弃，
# 爬链在低位 pid 断链（偶发 unresolved，2026-10-20 踩坑）
_PANE_SNAPSHOT="$(pane_line '%42' 100)"
assert_eq '%42' "$(_pane_from_ancestry "  500   400 a
  400   300 b
  300   100 c
  100     1 init
  $mypid   500 hook")" "real ancestry: macOS padded ps output"

# ── 12: 真实现无匹配 → return 1 ──
_PANE_SNAPSHOT="$(pane_line '%42' 999)"
_pane_from_ancestry "4242 $mypid zsh" >/dev/null 2>&1 \
    && { echo "FAIL: real ancestry should miss" >&2; exit 1; }

# ── 13: resolve 全程只取一次进程快照（ancestry 与候选共用）──
reset_case
# case 8 的计数 stub 覆盖了 FAKE_TREE 版，此处恢复
_pid_tree_has_names() { case " $FAKE_TREE " in *" $1 "*) return 0 ;; esac; return 1; }
FAKE_SNAPSHOT="$(pane_line '%16' 100)"
FAKE_TREE="100"; SESSION_ID="sid-ps"
# 计数用文件：_ps_process_snapshot 经 $(...) 命令替换执行，子 shell 里的变量
# 递增对父 shell 不可见，只能落盘
: > "$TEST_TMP/ps-count"
_ps_process_snapshot() { echo x >> "$TEST_TMP/ps-count"; printf '%s\n' "$mypid 1 zsh"; }
resolve_tmux_pane
assert_eq '%16' "$TMUX_PANE" "resolve via real ancestry + candidates"
assert_eq '1' "$(wc -l < "$TEST_TMP/ps-count" | tr -d ' ')" "single ps snapshot per resolve"

echo "PASS: pane-resolve 用例全部通过"
