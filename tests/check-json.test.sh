#!/bin/bash
# tests/check-json.test.sh — check --json 明细模式测试（mode/events/suppress/drift）
#
# 隔离方式同 ccswitch-install.test.sh：HOME 指向临时目录 + 清 config 目录覆盖变量。
# 覆盖：三工具的正常/缺失/漂移/force 收敛、默认 check 的 ok/missing 回归、
# suppress 标记、jq 缺失的 error JSON。判定契约：--json 的 exit code 与默认 check 一致。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

W_CLAUDE="$ROOT/scripts/install-claude-hooks.sh"
W_CODEX="$ROOT/scripts/install-codex-hooks.sh"
W_OPENCODE="$ROOT/scripts/install-opencode-hooks.sh"

unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true
unset TMUX_AI_SUPPRESS_DIR || true
unset TMUX_AI_FORCE_INSTALL || true

new_home() {  # $1=用例名 → echo home 路径
    local h="$TEST_TMP/home-$1"
    rm -rf "$h"
    mkdir -p "$h"
    printf '%s' "$h"
}

new_stub_scripts() {  # $1=名字 → 造一个含可执行 tmux-ai-status 的假安装源，echo 其 scripts 目录
    local d="$TEST_TMP/$1"
    mkdir -p "$d/scripts"
    printf '#!/bin/sh\nexit 0\n' > "$d/scripts/tmux-ai-status"
    chmod +x "$d/scripts/tmux-ai-status"
    printf '%s' "$d/scripts"
}

# 把 hooks JSON 里本插件 command 的前缀替换为 $2（须带尾斜杠），模拟另一安装源写入
repath_prefix() {  # $1=hooks.json 路径 $2=前缀(含尾斜杠) $3=codex 时传 "codex"
    local marker="tmux-ai-status"
    [ "${3:-}" = "codex" ] && marker="tmux-ai-status codex"
    local tmp
    tmp=$(jq --arg p "$2" --arg m "$marker" \
        'walk(if type == "object" and ((.command // "") | contains($m))
              then .command = ($p + ((.command // "") | sub(".*tmux-ai-status"; "tmux-ai-status")))
              else . end)' "$1")
    printf '%s\n' "$tmp" > "$1"
}

assert_eq() {  # $1=expected $2=actual $3=ctx
    [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "$2" >&2; exit 1; }
}

jqa() {  # $1=json $2=jq 程序 → 输出值
    jq -r "$2" <<<"$1"
}

# ── 用例 1: claude 文件模式 install → ok / file / 10 事件 / 无漂移 / exit 0 ──
H=$(new_home c1); export HOME="$H"
bash "$W_CLAUDE" >/dev/null
rc=0; out=$(bash "$W_CLAUDE" check --json) || rc=$?
assert_eq "0" "$rc" "claude 正常态 exit 0"
assert_eq "ok" "$(jqa "$out" .status)" "claude 正常态 status"
assert_eq "file" "$(jqa "$out" .mode)" "claude 正常态 mode"
assert_eq "10" "$(jqa "$out" '[.events[] | select(.registered == 1 and .alive == 1)] | length')" "claude 10 事件全注册且存活"
assert_eq "false" "$(jqa "$out" .drift.drifted)" "claude 正常态无漂移"
assert_eq "$ROOT/scripts/tmux-ai-status" "$(jqa "$out" '.drift.expected')" "expected 为执行者路径"
assert_eq "false" "$(jqa "$out" .suppress)" "claude 正常态无 suppress"

# ── 用例 2: 默认 check 回归（逐字节 ok）──
assert_eq "ok" "$(bash "$W_CLAUDE" check)" "默认 check 输出恰为 ok"

# ── 用例 3: 死脚本 → missing + alive=0 + exit 1 ──
repath_prefix "$H/.claude/settings.json" "/nonexistent/"
rc=0; out=$(bash "$W_CLAUDE" check --json) || rc=$?
assert_eq "1" "$rc" "死脚本 exit 1"
assert_eq "missing" "$(jqa "$out" .status)" "死脚本 status"
assert_eq "0" "$(jqa "$out" .events.SessionStart.alive)" "死脚本 alive=0"
assert_eq "missing" "$(bash "$W_CLAUDE" check)" "默认 check 回归 missing"

# ── 用例 4: 纯漂移（脚本存活）→ ok + drifted=true + stale ──
H=$(new_home c4); export HOME="$H"
bash "$W_CLAUDE" >/dev/null
STUB=$(new_stub_scripts drift-stub)
repath_prefix "$H/.claude/settings.json" "$STUB/"
rc=0; out=$(bash "$W_CLAUDE" check --json) || rc=$?
assert_eq "0" "$rc" "纯漂移 exit 0（脚本存活，功能未坏）"
assert_eq "ok" "$(jqa "$out" .status)" "纯漂移 status 仍 ok"
assert_eq "true" "$(jqa "$out" .drift.drifted)" "纯漂移 drifted=true"
assert_eq "$STUB/tmux-ai-status" "$(jqa "$out" '.drift.stale[0]')" "stale 记录旧路径"
assert_eq "1" "$(jqa "$out" .events.SessionStart.alive)" "漂移路径脚本存活 alive=1"
assert_eq "ok" "$(bash "$W_CLAUDE" check)" "纯漂移默认 check 仍 ok（漂移不改变功能判定）"

# ── 用例 5: suppress 标记 → suppress=true ──
H=$(new_home c5); export HOME="$H"
bash "$W_CLAUDE" >/dev/null
bash "$W_CLAUDE" uninstall >/dev/null
out=$(bash "$W_CLAUDE" check --json || true)
assert_eq "true" "$(jqa "$out" .suppress)" "uninstall 后 suppress=true"

# ── 用例 6: cc-switch 模式 → mode=ccswitch ──
H=$(new_home c6); export HOME="$H"
mkdir -p "$H/.cc-switch"
sqlite3 "$H/.cc-switch/cc-switch.db" "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)"
bash "$W_CLAUDE" >/dev/null
out=$(bash "$W_CLAUDE" check --json)
assert_eq "ccswitch" "$(jqa "$out" .mode)" "cc-switch 激活时 mode=ccswitch"
assert_eq "ok" "$(jqa "$out" .status)" "cc-switch 模式 status ok"
[ ! -f "$H/.claude/settings.json" ] || { echo "FAIL: cc-switch 模式不应写传统文件"; exit 1; }

# ── 用例 7: codex 同构 + no-op 门禁与 force 收敛 ──
H=$(new_home c7); export HOME="$H"
bash "$W_CODEX" >/dev/null
out=$(bash "$W_CODEX" check --json)
assert_eq "ok" "$(jqa "$out" .status)" "codex 正常态 status"
assert_eq "6" "$(jqa "$out" '[.events[] | select(.registered == 1 and .alive == 1)] | length')" "codex 6 事件"
STUB=$(new_stub_scripts codex-stub)
repath_prefix "$H/.codex/hooks.json" "$STUB/" codex
out=$(bash "$W_CODEX" check --json)
assert_eq "true" "$(jqa "$out" .drift.drifted)" "codex 漂移检出"
assert_eq "ok" "$(jqa "$out" .status)" "codex 纯漂移 status 仍 ok"
# 无 force → install no-op（trust preserved），漂移保持
no_op_out=$(bash "$W_CODEX")
case "$no_op_out" in
    *"no-op"*) ;;
    *) echo "FAIL: codex 漂移态 install 应 no-op"; exit 1 ;;
esac
out=$(bash "$W_CODEX" check --json)
assert_eq "true" "$(jqa "$out" .drift.drifted)" "no-op 后漂移仍在"
# force → 收敛到执行者路径
TMUX_AI_FORCE_INSTALL=1 bash "$W_CODEX" >/dev/null
out=$(bash "$W_CODEX" check --json)
assert_eq "false" "$(jqa "$out" .drift.drifted)" "force 后漂移消除"
assert_eq "$ROOT/scripts/tmux-ai-status" "$(jqa "$out" '.events.PreToolUse.scriptPaths[0]')" "force 后路径收敛"

# ── 用例 7b: codex trust 维度（check --json 只读，不重算 trusted_hash）──
H=$(new_home c7b); export HOME="$H"
bash "$W_CODEX" >/dev/null
out=$(bash "$W_CODEX" check --json)
assert_eq "null" "$(jqa "$out" .trust.trusted)" "无 config.toml 时 trust=null"
assert_eq "0" "$(jqa "$out" '.trust.instances | length')" "无 config.toml 时 instances 为空"

# 写入 6 个事件的授信键（只判键存在，trusted_hash 值不参与判定）
write_trust_keys() {  # $1=config.toml $2=hooks.json 路径 $3=事件（缺省全部）
    local cfg="$1" hooks="$2" ev
    : > "$cfg"
    for ev in ${3:-session_start user_prompt_submit pre_tool_use permission_request post_tool_use stop}; do
        printf '[hooks.state."%s:%s:0:0"]\ntrusted_hash = "sha256:x"\n' "$hooks" "$ev" >> "$cfg"
    done
}
write_trust_keys "$H/.codex/config.toml" "$H/.codex/hooks.json"
out=$(bash "$W_CODEX" check --json)
assert_eq "true" "$(jqa "$out" .trust.trusted)" "6 事件受益键齐全 → trust=true"
assert_eq "0" "$(jqa "$out" '.trust.missingEvents | length')" "无缺失事件"

# 缺一个事件键 → false + missingEvents
write_trust_keys "$H/.codex/config.toml" "$H/.codex/hooks.json" "session_start user_prompt_submit pre_tool_use permission_request post_tool_use"
before=$(shasum "$H/.codex/config.toml" | cut -d' ' -f1)
out=$(bash "$W_CODEX" check --json)
assert_eq "false" "$(jqa "$out" .trust.trusted)" "缺 1 个事件键 → trust=false"
assert_eq "stop" "$(jqa "$out" '.trust.missingEvents[0]')" "missingEvents 标出缺失事件"
after=$(shasum "$H/.codex/config.toml" | cut -d' ' -f1)
assert_eq "$before" "$after" "trust 判定不改写 config.toml"

# 汇总 cc-switch 实例（当前实例先补齐，验证只有 abc 未授信）
write_trust_keys "$H/.codex/config.toml" "$H/.codex/hooks.json"
mkdir -p "$H/.cc-switch/instances/codex/abc"
write_trust_keys "$H/.cc-switch/instances/codex/abc/config.toml" "$H/.cc-switch/instances/codex/abc/hooks.json" "session_start"
out=$(bash "$W_CODEX" check --json)
assert_eq "2" "$(jqa "$out" '.trust.instances | length')" "instances 汇总当前 + cc-switch 实例"
assert_eq "1" "$(jqa "$out" '[.trust.instances[] | select(.trusted == false)] | length')" "未授信实例被标出"
assert_eq "false" "$(jqa "$out" '[.trust.instances[] | select(.configFile | contains("/instances/codex/abc/"))] | .[0].trusted')" "abc 实例判为未授信"

# ── 用例 7c: codex 重复注册——status 仍 ok、exit 0、普通 install 不自动收敛 ──
H=$(new_home c7c); export HOME="$H"
bash "$W_CODEX" >/dev/null
jq '.hooks.PreToolUse += [.hooks.PreToolUse[0]]' "$H/.codex/hooks.json" > "$H/.codex/hooks.json.tmp" \
    && mv "$H/.codex/hooks.json.tmp" "$H/.codex/hooks.json"
rc=0; out=$(bash "$W_CODEX" check --json) || rc=$?
assert_eq "0" "$rc" "重复条目 check --json 仍 exit 0"
assert_eq "ok" "$(jqa "$out" .status)" "重复条目 status 仍 ok"
assert_eq "2" "$(jqa "$out" '.events.PreToolUse.registered')" "重复条目 registered=2"
assert_eq "ok" "$(bash "$W_CODEX" check)" "重复条目默认 check 仍 ok"
# 普通 install 走 no-op 门禁（重写会 re-trust），重复保持——这是修复 2 提示的前提
no_op_out=$(bash "$W_CODEX")
case "$no_op_out" in
    *"no-op"*) ;;
    *) echo "FAIL: 重复条目普通 install 应 no-op"; exit 1 ;;
esac
out=$(bash "$W_CODEX" check --json)
assert_eq "2" "$(jqa "$out" '.events.PreToolUse.registered')" "no-op 后重复仍在"

# ── 用例 8: opencode plugin 漂移 + force 收敛 ──
H=$(new_home c8); export HOME="$H"
bash "$W_OPENCODE" >/dev/null
STUB=$(new_stub_scripts oc-stub)
sed -i '' "s|^const HOOK_SCRIPT = \".*\"$|const HOOK_SCRIPT = \"$STUB/tmux-ai-status\"|" \
    "$H/.config/opencode/plugins/tmux-ai-status.ts" 2>/dev/null \
    || sed -i "s|^const HOOK_SCRIPT = \".*\"$|const HOOK_SCRIPT = \"$STUB/tmux-ai-status\"|" \
    "$H/.config/opencode/plugins/tmux-ai-status.ts"
out=$(bash "$W_OPENCODE" check --json)
assert_eq "true" "$(jqa "$out" .drift.drifted)" "opencode 漂移检出"
assert_eq "ok" "$(jqa "$out" .status)" "opencode 纯漂移 status 仍 ok"
TMUX_AI_FORCE_INSTALL=1 bash "$W_OPENCODE" >/dev/null
out=$(bash "$W_OPENCODE" check --json)
assert_eq "false" "$(jqa "$out" .drift.drifted)" "opencode force 后漂移消除"
assert_eq "true" "$(jqa "$out" .plugin.hookScriptAlive)" "opencode force 后 HOOK_SCRIPT 存活"

# ── 用例 9: jq 缺失 → error JSON + exit 1 ──
H=$(new_home c9); export HOME="$H"
STUBBIN="$TEST_TMP/stubbin-nojq"
mkdir -p "$STUBBIN"
# wrapper 解析 _LIB_DIR 需要 dirname（jq 必须缺席，其余按需补）
for b in dirname; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$STUBBIN/$b"
done
rc=0; out=$(PATH="$STUBBIN" /bin/bash "$W_CLAUDE" check --json) || rc=$?
assert_eq "1" "$rc" "jq 缺失 exit 1"
assert_eq "jq not found" "$(jqa "$out" .error)" "jq 缺失 error 字段"
assert_eq "unknown" "$(jqa "$out" .mode)" "jq 缺失 mode=unknown"

echo "PASS: 9/9 check --json 用例全部通过"
