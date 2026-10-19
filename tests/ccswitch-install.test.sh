#!/bin/bash
# tests/ccswitch-install.test.sh — cc-switch 共享配置模式的 install/uninstall/check 测试
#
# 覆盖两种真源：legacy（db common_config_claude；fixture 默认 user_version=0）与
# live（cc-switch 4.0.2+，user_version>=20，真源 ~/.claude/settings.json）。
# 隔离方式：HOME 指向临时目录。wrapper 只依赖 _ccswitch_db（$HOME/.cc-switch/...）、
# _ccswitch_live_file（$HOME/.claude/settings.json）与 ADAPTER_HOOKS_FILE
# （CLAUDE_CONFIG_DIR 未设时落在 $HOME/.claude），天然可注入，无需代码级测试钩子。
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

# 把全部本插件 command 改为挂在前缀 <prefix> 下（模拟条目由另一安装源写入）
repath_commands() {  # $1=home $2=fake-prefix
    local newval
    newval=$(common_value "$1" | jq --arg p "$2" \
        'walk(if type == "object" and ((.command // "") | contains("tmux-ai-status"))
              then .command = ($p + ((.command // "") | sub(".*tmux-ai-status"; "tmux-ai-status")))
              else . end)')
    sqlite3 "$1/.cc-switch/cc-switch.db" \
        "UPDATE settings SET value='$newval' WHERE key='common_config_claude'"
}

# ── 用例 11: 跨源卸载（路径无关剥离回归：条目路径非执行者路径时也必须剥干净）──
H6=$(new_home crosssrc); seed_common "$H6"
HOME="$H6" bash "$WRAPPER" >/dev/null
repath_commands "$H6" "/opt/fake-src"
assert_eq "10" "$(managed_events "$H6")" "前置：假路径条目仍被计数识别"
HOME="$H6" bash "$WRAPPER" uninstall >/dev/null
assert_eq "0" "$(managed_events "$H6")" "假路径（跨源）条目被完整剥离"
assert_contains "rtk hook claude" "$(common_value "$H6")" "跨源卸载仍保留他人 rtk hook"
[ -f "$H6/.config/tmuxclihook/suppressed-claude" ] \
    || { echo "FAIL: uninstall 应写卸载意图标记"; exit 1; }

# ── 用例 12: check 脚本存活校验（死路径 → missing → install 收敛恢复）──
H7=$(new_home deadscript); seed_common "$H7"
HOME="$H7" bash "$WRAPPER" >/dev/null
repath_commands "$H7" "/nonexistent"
if HOME="$H7" bash "$WRAPPER" check >/dev/null 2>&1; then
    echo "FAIL: 死路径条目 check 应失败"; exit 1
fi
HOME="$H7" bash "$WRAPPER" >/dev/null
out=$(HOME="$H7" bash "$WRAPPER" check)
assert_eq "ok" "$out" "install 收敛为执行者路径后 check 恢复 ok"

# ── live 模式（cc-switch 4.0.2+，db user_version >= 20）：真源 = ~/.claude/settings.json ──
new_home_live() {  # $1=用例名 → echo home（v4 schema）
    local h="$TEST_TMP/home-live-$1"
    rm -rf "$h"
    mkdir -p "$h/.cc-switch" "$h/.claude"
    sqlite3 "$h/.cc-switch/cc-switch.db" \
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT); PRAGMA user_version = 20;"
    printf '%s' "$h"
}

file_events() {  # $1=home → settings.json 中本插件管理的事件数
    jq '[.hooks // {} | to_entries[]
        | select(.value | any(.hooks[]?.command | contains("tmux-ai-status")))] | length' \
        "$1/.claude/settings.json"
}

# ── 用例 13: live install → 写 settings.json、保留他人 hook/顶层字段、库不写 ──
H8=$(new_home_live install)
printf '%s\n' "$FIXTURE_COMMON" > "$H8/.claude/settings.json"
HOME="$H8" bash "$WRAPPER" >/dev/null
assert_eq "10" "$(file_events "$H8")" "live install 注册 10 个事件"
jq -e '.model == "opus" and (.hooks.PreToolUse | length == 2)' "$H8/.claude/settings.json" >/dev/null \
    || { echo "FAIL: live install 应保留 model 与他人 hook"; exit 1; }
assert_eq "0" "$(sqlite3 "$H8/.cc-switch/cc-switch.db" "SELECT count(*) FROM settings WHERE key='common_config_claude'")" \
    "live install 不写 legacy 库"
assert_eq "ok" "$(HOME="$H8" bash "$WRAPPER" check)" "live check 输出 ok"
assert_eq "ccswitch-live" "$(HOME="$H8" bash "$WRAPPER" check --json | jq -r .mode)" \
    "check --json mode=ccswitch-live"

# ── 用例 14: live + settings.json 不存在 → 自动创建 ──
H9=$(new_home_live newfile)
HOME="$H9" bash "$WRAPPER" >/dev/null
assert_eq "10" "$(file_events "$H9")" "settings.json 缺失时自动创建并注册"

# ── 用例 15: live 缺事件 → check 失败；重装收敛 ──
jq '.hooks |= del(.SessionStart, .Stop)' "$H9/.claude/settings.json" > "$H9/.tmp.json" \
    && mv "$H9/.tmp.json" "$H9/.claude/settings.json"
if HOME="$H9" bash "$WRAPPER" check >/dev/null 2>&1; then
    echo "FAIL: live 缺事件时 check 应失败"; exit 1
fi
HOME="$H9" bash "$WRAPPER" >/dev/null
assert_eq "ok" "$(HOME="$H9" bash "$WRAPPER" check)" "live 重装后恢复 ok"

# ── 用例 16: live uninstall → 剥离本插件、保留他人 hook/顶层字段 ──
HOME="$H8" bash "$WRAPPER" uninstall >/dev/null
assert_eq "0" "$(file_events "$H8")" "live 卸载后本插件事件为 0"
jq -e '.model == "opus" and (.hooks.PreToolUse | length == 1)' "$H8/.claude/settings.json" >/dev/null \
    || { echo "FAIL: live 卸载应保留 model 与他人 hook"; exit 1; }

# ── 用例 17/18: CC_SWITCH_SHARED_SOURCE 显式覆盖（与 cc-switch 同款逃生阀）──
H10=$(new_home_live override-legacy)
HOME="$H10" CC_SWITCH_SHARED_SOURCE=legacy bash "$WRAPPER" >/dev/null
assert_eq "10" "$(managed_events "$H10")" "override=legacy 写库"
[ ! -f "$H10/.claude/settings.json" ] || { echo "FAIL: override=legacy 不应写 live 文件"; exit 1; }

H11=$(new_home override-live); seed_common "$H11"
HOME="$H11" CC_SWITCH_SHARED_SOURCE=live bash "$WRAPPER" >/dev/null
assert_eq "10" "$(file_events "$H11")" "override=live 写 live 文件"
assert_eq "0" "$(sqlite3 "$H11/.cc-switch/cc-switch.db" \
    "SELECT count(*) FROM settings WHERE key='common_config_claude' AND value LIKE '%tmux-ai-status%'")" \
    "override=live 不改 legacy 库"

echo "PASS: 18/18 cc-switch install 用例全部通过"
