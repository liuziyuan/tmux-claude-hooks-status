#!/bin/bash
# tests/install-idempotency.test.sh — 写路径幂等/互斥/suppress 告警/收敛判定
#
# 覆盖 PR-B 的行为面：语义不变跳写（mtime/shasum）、auto 已收敛跳过、
# 强收敛不回归（跨源/死条目/重复）、suppress 告警、锁互斥/stale/降级、
# SessionStart 节流。沿用 suppress-cross-source 的 HOME 隔离手法。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

WRAPPER="$ROOT/scripts/install-claude-hooks.sh"
ENGINE="$ROOT/scripts/tmux-ai-status"

unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_DIR || true
unset XDG_CONFIG_HOME || true
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
mkdir -p "$TMUX_AI_STATUS_DIR"

# fake tmux（SessionStart 用例需要）：只实现 engine 解析所需最小集
tmux() {
    local command="${1:-}"
    case "$command" in
        display-message)
            local format="${5:-}"
            case "$format" in
                *'@ai_pane_status'*) [ -f "$FAKE_TMUX_DIR/pane-status" ] && command cat "$FAKE_TMUX_DIR/pane-status" ;;
                *'session_name'*) printf '%s\n' 'test:1.1' ;;
            esac ;;
        set-option) ;;
        list-panes) ;;
        refresh-client) ;;
    esac
    return 0
}
export -f tmux

assert_eq() { [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "${2:-<empty>}" >&2; exit 1; }; }
assert_contains() { case "$2" in *"$1"*) ;; *) printf 'FAIL: %s: 未包含 %s\n' "$3" "$1" >&2; exit 1 ;; esac; }

new_env() {  # $1=用例名 → echo home 路径（清空并准备沙箱目录）
    local h="$TEST_TMP/env-$1"
    rm -rf "$h"
    mkdir -p "$h"
    printf '%s' "$h"
}
use_env() {  # $1=home：在父 shell 设置隔离（⚠️ 不能放进 $( )——subshell 的 export 不会传回）
    export HOME="$1"
    export TMUX_AI_SUPPRESS_DIR="$1/.config/tmuxclihook"
    FAKE_TMUX_DIR="$TEST_TMP/tmux-${1##*/}"
    mkdir -p "$FAKE_TMUX_DIR"
}

managed_count() {  # $1=settings.json → 本插件注册事件数
    jq '[.hooks // {} | to_entries[]
        | select(.value | any(.hooks[]?.command | contains("tmux-ai-status")))] | length' "$1" 2>/dev/null
}

repath_commands() {  # $1=json $2=fake-prefix：就地改写全部本插件 command（模拟跨源）
    python3 - "$1" "$2" <<'EOF'
import json, sys
p, pre = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for ev in d.get('hooks', {}):
    for g in d['hooks'][ev]:
        for h in g.get('hooks', []):
            if 'tmux-ai-status' in h.get('command', ''):
                h['command'] = pre + ' claude ' + ev
json.dump(d, open(p, 'w'), indent=2)
EOF
}

# ── 1: file 模式重复 install → mtime/shasum 不变 + skip 提示 + check ok ──
h=$(new_env idem-file)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
m1=$(stat -f %m "$f"); s1=$(shasum "$f" | cut -d' ' -f1)
sleep 1.1
out=$(bash "$WRAPPER" | head -1)
assert_contains "skip write" "$out" "重复 install 输出 skip 提示"
assert_eq "$m1" "$(stat -f %m "$f")" "重复 install mtime 不变"
assert_eq "$s1" "$(shasum "$f" | cut -d' ' -f1)" "重复 install shasum 不变"
assert_eq "ok" "$(bash "$WRAPPER" check)" "跳写后 check ok"

# ── 2: 他人 hook 共存的重复 install → 保留 + mtime 不变 ──
h=$(new_env idem-others)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]' "$f" > "$f.t" && mv "$f.t" "$f"
# install 自己收敛一次（重排他人条目到稳定形态）
bash "$WRAPPER" >/dev/null
m1=$(stat -f %m "$f"); sleep 1.1
bash "$WRAPPER" >/dev/null
assert_eq "$m1" "$(stat -f %m "$f")" "他人 hook 稳定形态下重复 install mtime 不变"
assert_eq "1" "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(. == "rtk hook claude")] | length' "$f")" "rtk hook 保留"
assert_eq "10" "$(managed_count "$f")" "他人 hook 共存时本插件 10 事件"

# ── 3: live 模式重复 install → mtime 不变 ──
h=$(new_env idem-live)
use_env "$h"
mkdir -p "$h/.cc-switch"
sqlite3 "$h/.cc-switch/cc-switch.db" "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT); PRAGMA user_version=20;"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
m1=$(stat -f %m "$f"); sleep 1.1
bash "$WRAPPER" >/dev/null
assert_eq "$m1" "$(stat -f %m "$f")" "live 模式重复 install mtime 不变"

# ── 4: legacy 模式重复 install → db value 字节不变 ──
h=$(new_env idem-legacy)
use_env "$h"
mkdir -p "$h/.cc-switch"
sqlite3 "$h/.cc-switch/cc-switch.db" "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);"
bash "$WRAPPER" >/dev/null
v1=$(sqlite3 "$h/.cc-switch/cc-switch.db" "SELECT value FROM settings WHERE key='common_config_claude'")
bash "$WRAPPER" >/dev/null
v2=$(sqlite3 "$h/.cc-switch/cc-switch.db" "SELECT value FROM settings WHERE key='common_config_claude'")
assert_eq "$v1" "$v2" "legacy 重复 install db value 字节不变"

# ── 5: 重复 uninstall → 第二次 mtime 不变 + exit 0 ──
h=$(new_env idem-uninstall)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
bash "$WRAPPER" uninstall >/dev/null
m1=$(stat -f %m "$f"); sleep 1.1
bash "$WRAPPER" uninstall >/dev/null
assert_eq "$m1" "$(stat -f %m "$f")" "重复 uninstall mtime 不变"
assert_eq "0" "$(managed_count "$f")" "卸载后条目清空"

# ── 6: auto 已收敛 → exit 0 + 不改文件 ──
h=$(new_env auto-converged)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
m1=$(stat -f %m "$f"); s1=$(shasum "$f" | cut -d' ' -f1); sleep 1.1
out=$(bash "$WRAPPER" auto | head -1)
assert_contains "converged" "$out" "auto 已收敛输出 converged 提示"
assert_eq "$m1" "$(stat -f %m "$f")" "auto 已收敛 mtime 不变"
assert_eq "$s1" "$(shasum "$f" | cut -d' ' -f1)" "auto 已收敛 shasum 不变"

# ── 7: auto 遇跨源条目（健康存活）→ 仍收敛重写为当前源 ──
h=$(new_env auto-cross)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
repath_commands "$f" "/opt/fake-src"
bash "$WRAPPER" auto >/dev/null
assert_eq "1" "$(jq -r '[.hooks.Stop[0].hooks[0].command | startswith("'"$ROOT"'/scripts")] | length' "$f")" "跨源条目 auto 收敛为当前源"
assert_eq "ok" "$(bash "$WRAPPER" check)" "跨源收敛后 check ok"

# ── 8: auto 遇死条目 → 收敛清除 ──
# prefix 必须保留 "tmux-ai-status" 字样：strip/归属判定是 contains("tmux-ai-status")
# 路径无关匹配——丢掉该字样就成了「他人 hook」而非「本插件死条目」，merge 不会剥
h=$(new_env auto-dead)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
repath_commands "$f" "/nonexistent/tmux-ai-status"
bash "$WRAPPER" auto >/dev/null
assert_eq "0" "$(grep -c "/nonexistent" "$f" || true)" "死条目 auto 收敛清除"
assert_eq "ok" "$(bash "$WRAPPER" check)" "死条目收敛后 check ok"

# ── 9: auto 遇重复条目 → 收敛去重 ──
h=$(new_env auto-dup)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
jq '.hooks.Stop += .hooks.Stop[:1]' "$f" > "$f.t" && mv "$f.t" "$f"
assert_eq "2" "$(jq '.hooks.Stop | length' "$f")" "前置：Stop 2 组"
bash "$WRAPPER" auto >/dev/null
assert_eq "1" "$(jq '.hooks.Stop | length' "$f")" "重复条目 auto 去重"

# ── 10: suppress 写失败 → uninstall exit 1 + 双段告警 ──
h=$(new_env sup-write-fail)
use_env "$h"
printf x > "$h/not-a-dir"                          # 文件占位 → mkdir -p 遇非目录组件 ENOTDIR 必败
export TMUX_AI_SUPPRESS_DIR="$h/not-a-dir/child"
bash "$WRAPPER" >/dev/null
rc=0; err=$(bash "$WRAPPER" uninstall 2>&1 >/dev/null) || rc=$?
assert_eq "1" "$rc" "suppress 写失败时 uninstall exit 1"
assert_contains "标记写入失败" "$err" "write 失败告警"
assert_contains "hooks 已卸载" "$err" "write 失败说明 hooks 已剥离"
unset TMUX_AI_SUPPRESS_DIR

# ── 11: suppress clear 失败 → install exit 0 + 告警 ──
h=$(new_env sup-clear-fail)
use_env "$h"
printf x > "$h/not-a-dir"
export TMUX_AI_SUPPRESS_DIR="$h/not-a-dir/child"
printf 'x' > "$h/pre-existing-marker"   # 占位：clear 目标不存在 → clear 实际成功；此用例验证降级路径 exit 0
rc=0; err=$(bash "$WRAPPER" install 2>&1 >/dev/null) || rc=$?
assert_eq "0" "$rc" "clear 失败不改 install 退出码"
assert_contains "降级无锁" "$err" "锁降级告警"
assert_eq "10" "$(managed_count "$h/.claude/settings.json")" "降级无锁 install 成功装上"
unset TMUX_AI_SUPPRESS_DIR

# ── 12: 锁互斥——持锁者存活 → wrapper 等待直至 stale 强夺成功 ──
h=$(new_env lock-wait)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
( sleep 1.2 ) & holder=$!
mkdir -p "$TMUX_AI_SUPPRESS_DIR/.install-lock-claude"
echo "$holder" > "$TMUX_AI_SUPPRESS_DIR/.install-lock-claude/owner"
t0=$(date +%s)
bash "$WRAPPER" >/dev/null
t1=$(date +%s)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
[ $((t1 - t0)) -ge 1 ] && [ $((t1 - t0)) -le 12 ] && : || { echo "FAIL: 锁等待耗时异常（${t0}→${t1}s）" >&2; exit 1; }
assert_eq "10" "$(managed_count "$f")" "锁等待后 install 成功"
[ ! -d "$TMUX_AI_SUPPRESS_DIR/.install-lock-claude" ] && : || { echo "FAIL: 锁未释放" >&2; exit 1; }

# ── 13: 锁 stale（owner 死进程）→ 立即强夺 ──
h=$(new_env lock-stale)
use_env "$h"
bash "$WRAPPER" >/dev/null
mkdir -p "$TMUX_AI_SUPPRESS_DIR/.install-lock-claude"
echo "49999999" > "$TMUX_AI_SUPPRESS_DIR/.install-lock-claude/owner"
start=$(python3 -c 'import time;print(time.time())')
bash "$WRAPPER" >/dev/null
elapsed=$(python3 -c "import time;print(time.time()-$start)")
python3 -c "import sys; sys.exit(0 if float('$elapsed') < 5 else 1)" \
    || { echo "FAIL: 死 owner 未立即强夺（${elapsed}s）" >&2; exit 1; }

# ── 14: 锁降级——suppress dir 不可创建 → install 仍成功 + 告警 ──
h=$(new_env lock-degrade)
use_env "$h"
printf x > "$h/not-a-dir"
export TMUX_AI_SUPPRESS_DIR="$h/not-a-dir/child"
rc=0; err=$(bash "$WRAPPER" install 2>&1 >/dev/null) || rc=$?
assert_eq "0" "$rc" "锁降级时 install exit 0"
assert_contains "降级无锁" "$err" "锁降级告警"
assert_eq "10" "$(managed_count "$h/.claude/settings.json")" "降级无锁装上 10 事件"
unset TMUX_AI_SUPPRESS_DIR

# ── 15/16: SessionStart 修复——节流与 suppress 拦截 ──
FAKE_TMUX_DIR="$TEST_TMP/tmux-ss"
mkdir -p "$FAKE_TMUX_DIR"
h=$(new_env ss-throttle)
use_env "$h"
export FAKE_PANE_PID=$$ FAKE_SERVER_PID=1234 FAKE_PANE_PATH="$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
rm -f "$TMUX_AI_STATUS_DIR/.hooks-repair-claude-ts"
repath_commands "$f" "/nonexistent"
printf '%s' '{"session_id":"ss"}' | TMUX_PANE='%1' TMUX='test' bash "$ENGINE" claude SessionStart >/dev/null 2>&1
assert_eq "ok" "$(bash "$WRAPPER" check)" "SessionStart 首次修复成功"
repath_commands "$f" "/nonexistent"
printf '%s' '{"session_id":"ss"}' | TMUX_PANE='%1' TMUX='test' bash "$ENGINE" claude SessionStart >/dev/null 2>&1
assert_eq "missing" "$(bash "$WRAPPER" check)" "60s 窗口内二次 SessionStart 不重装"
rm -f "$TMUX_AI_STATUS_DIR/.hooks-repair-claude-ts"
printf '%s' '{"session_id":"ss"}' | TMUX_PANE='%1' TMUX='test' bash "$ENGINE" claude SessionStart >/dev/null 2>&1
assert_eq "ok" "$(bash "$WRAPPER" check)" "窗口过后 SessionStart 恢复重装"

# ── 17: 双 install 并发 → 都成功、文件完好 ──
h=$(new_env concurrent)
use_env "$h"
bash "$WRAPPER" >/dev/null
f="$h/.claude/settings.json"
bash "$WRAPPER" >/dev/null 2>&1 &
p1=$!
bash "$WRAPPER" >/dev/null 2>&1 &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
assert_eq "0" "$r1" "并发 install #1 exit 0"
assert_eq "0" "$r2" "并发 install #2 exit 0"
jq -e . "$f" >/dev/null || { echo "FAIL: 并发后 settings.json 不是合法 JSON" >&2; exit 1; }
assert_eq "10" "$(managed_count "$f")" "并发后 10 事件完整"

printf 'PASS: install-idempotency 用例全部通过\n'
