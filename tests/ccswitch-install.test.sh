#!/bin/bash
# tests/ccswitch-install.test.sh — cc-switch 通用配置模式的 install/uninstall/check 测试
#
# 隔离方式：HOME 指向临时目录。wrapper 只依赖 _ccswitch_db（$HOME/.cc-switch/...）
# 与 ADAPTER_HOOKS_FILE（CLAUDE_CONFIG_DIR 未设时落在 $HOME/.claude），天然可注入，
# 无需任何代码级测试钩子。fixture db 与真实 cc-switch.db 的 settings 表同 schema。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

WRAPPER="$ROOT/scripts/install-claude-hooks.sh"

# 环境隔离：除 HOME 外还必须清掉 config 目录覆盖变量，否则在 cc-switch/实例
# 环境下 ADAPTER_HOOKS_FILE 会解析到宿主真实配置文件而非 $HOME 下的测试沙箱。
unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true

# 预置通用配置：他人 hook（rtk，matcher Bash）+ 非 hooks 顶层字段
FIXTURE_COMMON='{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"rtk hook claude"}]}]}}'

new_home() {  # $1=用例名 → echo home 路径（含空 db，无 key）
    local h="$TEST_TMP/home-$1"
    rm -rf "$h"
    mkdir -p "$h/.cc-switch"
    sqlite3 "$h/.cc-switch/cc-switch.db" \
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT);"
    printf '%s' "$h"
}

seed_common() {  # $1=home：写入 fixture 通用配置
    sqlite3 "$1/.cc-switch/cc-switch.db" \
        "INSERT INTO settings(key, value) VALUES('common_config_claude', '$FIXTURE_COMMON')"
}

common_value() {  # $1=home → 通用配置 value
    sqlite3 -readonly "$1/.cc-switch/cc-switch.db" \
        "SELECT value FROM settings WHERE key='common_config_claude'"
}

managed_events() {  # $1=home → 注册了 tmux-ai-status 的事件数
    common_value "$1" | jq '[.hooks // {} | to_entries[]
        | select(.value | any(.hooks[]?.command | contains("tmux-ai-status")))] | length'
}

assert_eq() {  # $1=expected $2=actual $3=ctx
    [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "$2" >&2; exit 1; }
}

assert_contains() {  # $1=needle $2=haystack $3=ctx
    case "$2" in
        *"$1"*) ;;
        *) printf 'FAIL: %s: missing %s\n' "$3" "$1" >&2; exit 1 ;;
    esac
}

assert_not_contains() {  # $1=needle $2=haystack $3=ctx
    case "$2" in
        *"$1"*) printf 'FAIL: %s: unexpectedly contains %s\n' "$3" "$1" >&2; exit 1 ;;
    esac
}

# ── 用例 1: install（active）→ 10 事件、rtk/model 保留、不写传统文件 ──
H=$(new_home install); seed_common "$H"
HOME="$H" bash "$WRAPPER" >/dev/null
assert_eq "10" "$(managed_events "$H")" "install 后注册 10 个事件"
val=$(common_value "$H")
assert_contains "rtk hook claude" "$val" "install 保留他人 rtk hook"
assert_contains '"opus"' "$val" "install 保留顶层 model 字段"
[ ! -f "$H/.claude/settings.json" ] || { echo "FAIL: active 模式不应写传统文件"; exit 1; }

# ── 用例 2: 幂等重跑 ──
v1=$(common_value "$H")
HOME="$H" bash "$WRAPPER" >/dev/null
assert_eq "$v1" "$(common_value "$H")" "重复 install 幂等"

# ── 用例 3: check → ok ──
out=$(HOME="$H" bash "$WRAPPER" check)
assert_eq "ok" "$out" "check 完整输出 ok"

# ── 用例 4: 缺 2 个事件 → check 失败（exit 1）──
sqlite3 "$H/.cc-switch/cc-switch.db" \
    "UPDATE settings SET value = json_remove(value, '\$.hooks.SessionStart', '\$.hooks.Stop') WHERE key='common_config_claude'"
if HOME="$H" bash "$WRAPPER" check >/dev/null 2>&1; then
    echo "FAIL: 缺事件时 check 应失败"; exit 1
fi

# ── 用例 5: uninstall → 本插件事件清空（删键）、rtk 保留 ──
HOME="$H" bash "$WRAPPER" uninstall >/dev/null
assert_eq "0" "$(managed_events "$H")" "卸载后本插件事件为 0"
val=$(common_value "$H")
assert_contains "rtk hook claude" "$val" "卸载保留他人 rtk hook"
assert_not_contains '"SessionStart"' "$val" "被清空的事件键已删除"
jq -e '.hooks | has("PreToolUse")' >/dev/null 2>&1 <<<"$val" \
    || { echo "FAIL: 卸载后 hooks.PreToolUse（rtk）应保留"; exit 1; }

# ── 用例 6: 重复 uninstall → no-op ──
out=$(HOME="$H" bash "$WRAPPER" uninstall)
assert_contains "nothing to uninstall" "$out" "重复卸载 no-op"

# ── 用例 7: 非 active（无 .cc-switch）→ 回退传统文件模式 ──
H2=$(new_home nofile)
rm -rf "$H2/.cc-switch"
HOME="$H2" bash "$WRAPPER" >/dev/null
[ -f "$H2/.claude/settings.json" ] || { echo "FAIL: 非 active 应写传统文件"; exit 1; }
file_count=$(jq '[.hooks // {} | to_entries[]
    | select(.value | any(.hooks[]?.command | contains("tmux-ai-status")))] | length' \
    "$H2/.claude/settings.json")
assert_eq "10" "$file_count" "文件模式注册 10 个事件"

# ── 用例 8: sqlite3 缺失（stub PATH）→ 一致回退文件模式 ──
H3=$(new_home nosqlite); seed_common "$H3"
STUB="$TEST_TMP/stubbin"
mkdir -p "$STUB"
for b in jq mktemp sed tr cat rm mkdir dirname mv; do
    p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$STUB/$b"
done
# PATH 限制为 stub 目录（无 sqlite3）时必须用绝对路径调 bash——PATH 赋值先于命令查找
HOME="$H3" PATH="$STUB" /bin/bash "$WRAPPER" >/dev/null
[ -f "$H3/.claude/settings.json" ] || { echo "FAIL: sqlite3 缺失应回退文件模式"; exit 1; }
assert_eq "0" "$(managed_events "$H3")" "回退时不写库"
[ ! -f "$H3/.claude/settings.json" ] && { echo "unreachable"; exit 1; } || true

# ── 用例 9: 通用配置为非法 JSON → 拒写、原值不动 ──
H4=$(new_home badjson)
sqlite3 "$H4/.cc-switch/cc-switch.db" \
    "INSERT INTO settings(key, value) VALUES('common_config_claude', 'not json{')"
if HOME="$H4" bash "$WRAPPER" >/dev/null 2>&1; then
    echo "FAIL: 非法 JSON 应报错退出"; exit 1
fi
assert_eq "not json{" "$(common_value "$H4")" "非法 JSON 未被覆盖"

# ── 用例 10: key 缺失 → upsert 建行 ──
H5=$(new_home nokey)
HOME="$H5" bash "$WRAPPER" >/dev/null
assert_eq "10" "$(managed_events "$H5")" "key 缺失时 upsert 建行并注册 10 事件"

echo "PASS: 10/10 cc-switch install 用例全部通过"
