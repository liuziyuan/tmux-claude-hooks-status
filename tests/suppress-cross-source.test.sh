#!/bin/bash
# tests/suppress-cross-source.test.sh — 卸载意图标记（suppression marker）生命周期 +
# 跨安装源收敛 + codex/opencode no-op-if-valid 测试。
#
# 隔离方式：HOME 指向临时目录（marker 落 $HOME/.config/tmuxclihook/）；
# codex/opencode 分别用 CODEX_HOME / OPENCODE_CONFIG_DIR 沙箱；
# tmux 命令用 stub 函数（同 status-machine.test.sh 手法）拦截自修复路径。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true

CLAUDE_WRAPPER="$ROOT/scripts/install-claude-hooks.sh"
CODEX_WRAPPER="$ROOT/scripts/install-codex-hooks.sh"
OPENCODE_WRAPPER="$ROOT/scripts/install-opencode-hooks.sh"
ENGINE="$ROOT/scripts/tmux-ai-status"

FAKE_TMUX_DIR="$TEST_TMP/tmux"
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
mkdir -p "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR"

# status-machine.test.sh 同款 fake tmux（_refresh 的 build_all_status 需要）
tmux() {
    local command="${1:-}"
    case "$command" in
        display-message)
            local format="${5:-}"
            case "$format" in
                *'@ai_pane_status'*) [ -f "$FAKE_TMUX_DIR/pane-status" ] && command cat "$FAKE_TMUX_DIR/pane-status" ;;
                *'session_name'*) printf '%s\n' 'test:1.1' ;;
            esac
            ;;
        set-option)
            if [ "${2:-}" = "-pt" ]; then
                [ "${4:-}" = "@ai_pane_status" ] && printf '%s' "${5:-}" > "$FAKE_TMUX_DIR/pane-status"
            elif [ "${2:-}" = "-g" ]; then
                printf '%s' "${4:-}" > "$FAKE_TMUX_DIR/${3#@}"
            fi
            ;;
        list-panes)
            printf '%s\n' '%1|test|1|1||1|1|bash'
            ;;
        refresh-client)
            ;;
        *)
            printf 'unexpected tmux command: %s\n' "$*" >&2
            return 1
            ;;
    esac
}
export -f tmux

assert_eq() {  # $1=expected $2=actual $3=ctx
    [ "$2" = "$1" ] || { printf 'FAIL: %s: expected %s, got %s\n' "$3" "$1" "$2" >&2; exit 1; }
}

marker_file() {  # $1=home $2=tool
    printf '%s/.config/tmuxclihook/suppressed-%s' "$1" "$2"
}

managed_count_claude_file() {  # $1=settings.json 路径
    jq '[.hooks // {} | to_entries[]
        | select(.value | any(.hooks[]?.command | contains("tmux-ai-status")))] | length' "$1"
}

repath_json_commands() {  # $1=json 文件 $2=fake-prefix（就地改写全部本插件 command）
    local tmp="$1.tmp"
    jq --arg p "$2" 'walk(if type == "object" and ((.command // "") | contains("tmux-ai-status"))
        then .command = ($p + ((.command // "") | sub(".*tmux-ai-status"; "tmux-ai-status")))
        else . end)' "$1" > "$tmp" && mv "$tmp" "$1"
}

# ── claude 文件模式：install/uninstall 标记生命周期 ──
H1="$TEST_TMP/home-claude"; mkdir -p "$H1"
HOME="$H1" bash "$CLAUDE_WRAPPER" >/dev/null
[ ! -f "$(marker_file "$H1" claude)" ] || { echo "FAIL: install 不应写标记"; exit 1; }
assert_eq "10" "$(managed_count_claude_file "$H1/.claude/settings.json")" "文件模式安装 10 事件"

HOME="$H1" bash "$CLAUDE_WRAPPER" uninstall >/dev/null
assert_eq "0" "$(managed_count_claude_file "$H1/.claude/settings.json")" "卸载后条目清空"
[ -f "$(marker_file "$H1" claude)" ] || { echo "FAIL: uninstall 应写标记"; exit 1; }

# ── auto 被标记拦截：exit 0 且不写文件 ──
before=$(shasum "$H1/.claude/settings.json" | cut -d' ' -f1)
HOME="$H1" bash "$CLAUDE_WRAPPER" auto
assert_eq "0" "$?" "auto 被拦截时 exit 0"
after=$(shasum "$H1/.claude/settings.json" | cut -d' ' -f1)
assert_eq "$before" "$after" "auto 被拦截时不改写 settings.json"

# ── _refresh 自修复被标记拦截（死路径条目 + marker → 不回装）──
repath_json_commands "$H1/.claude/settings.json" "/nonexistent"
rm -f "$TMUX_AI_STATUS_DIR/.hooks-repair-claude-ts"
printf '%s' '{}' | HOME="$H1" TMUX_PANE='%1' TMUX='test' bash "$ENGINE" claude _refresh >/dev/null 2>&1
assert_eq "0" "$(managed_count_claude_file "$H1/.claude/settings.json")" "标记在：_refresh 不重装"

# 对照组：无标记时 _refresh 自修复重装
rm -f "$(marker_file "$H1" claude)"
rm -f "$TMUX_AI_STATUS_DIR/.hooks-repair-claude-ts"
printf '%s' '{}' | HOME="$H1" TMUX_PANE='%1' TMUX='test' bash "$ENGINE" claude _refresh >/dev/null 2>&1
assert_eq "10" "$(managed_count_claude_file "$H1/.claude/settings.json")" "无标记：_refresh 自修复重装"

# ── SessionStart 重装路径被标记拦截 ──
HOME="$H1" bash "$CLAUDE_WRAPPER" uninstall >/dev/null
repath_json_commands "$H1/.claude/settings.json" "/nonexistent"
rm -f "$TMUX_AI_STATUS_DIR/.hooks-repair-claude-ts"
printf '%s' '{"session_id":"s"}' | HOME="$H1" TMUX_PANE='%1' TMUX='test' bash "$ENGINE" claude SessionStart >/dev/null 2>&1
assert_eq "0" "$(managed_count_claude_file "$H1/.claude/settings.json")" "标记在：SessionStart 不重装"

# ── 显式 install 清标记并恢复 ──
HOME="$H1" bash "$CLAUDE_WRAPPER" >/dev/null
[ ! -f "$(marker_file "$H1" claude)" ] || { echo "FAIL: 显式 install 应清标记"; exit 1; }
out=$(HOME="$H1" bash "$CLAUDE_WRAPPER" check)
assert_eq "ok" "$out" "显式 install 后 check ok"

# ── codex：no-op if valid（trust 保持）+ 死路径收敛 ──
H2="$TEST_TMP/home-codex"; mkdir -p "$H2/.codex"
CODEX_FILE="$H2/.codex/hooks.json"
HOME="$H2" bash "$CODEX_WRAPPER" >/dev/null
before=$(shasum "$CODEX_FILE" | cut -d' ' -f1)
HOME="$H2" bash "$CODEX_WRAPPER" >/dev/null   # 跨「执行者」重复安装
after=$(shasum "$CODEX_FILE" | cut -d' ' -f1)
assert_eq "$before" "$after" "codex 健康状态重复 install 为 no-op"

# 跨源健康条目（假路径但存活——用 repo 真实脚本挂前缀前的替身：直接用 $ROOT 路径语义）
# 部分事件死路径 → check missing → install 收敛
jq '.hooks.Stop[0].hooks[0].command = "/nonexistent/tmux-ai-status codex Stop"' "$CODEX_FILE" > "$CODEX_FILE.tmp" \
    && mv "$CODEX_FILE.tmp" "$CODEX_FILE"
if HOME="$H2" bash "$CODEX_WRAPPER" check >/dev/null 2>&1; then
    echo "FAIL: codex 部分事件死路径 check 应失败"; exit 1
fi
HOME="$H2" bash "$CODEX_WRAPPER" >/dev/null
jq -e '.hooks.Stop[0].hooks[0].command | startswith("/nonexistent") | not' "$CODEX_FILE" >/dev/null \
    || { echo "FAIL: codex install 应回收敛写 Stop 条目"; exit 1; }
out=$(HOME="$H2" bash "$CODEX_WRAPPER" check)
assert_eq "ok" "$out" "codex 收敛后 check ok"
# check 无副作用
before=$(shasum "$CODEX_FILE" | cut -d' ' -f1)
HOME="$H2" bash "$CODEX_WRAPPER" check >/dev/null
after=$(shasum "$CODEX_FILE" | cut -d' ' -f1)
assert_eq "$before" "$after" "codex check 不改写文件"

# ── opencode：跨源 check ok + 死路径 missing → 收敛 ──
H3="$TEST_TMP/home-opencode"; mkdir -p "$H3/.config/opencode/plugins"
OPENCODE_FILE="$H3/.config/opencode/plugins/tmux-ai-status.ts"
HOME="$H3" bash "$OPENCODE_WRAPPER" >/dev/null
out=$(HOME="$H3" bash "$OPENCODE_WRAPPER" check)
assert_eq "ok" "$out" "opencode 安装后 check ok"
# 模拟跨源：HOOK_SCRIPT 改为另一个存活路径（repo 引擎脚本存在）
sed 's|^const HOOK_SCRIPT = .*|const HOOK_SCRIPT = "/bin/echo"|' "$OPENCODE_FILE" > "$OPENCODE_FILE.tmp" \
    && mv "$OPENCODE_FILE.tmp" "$OPENCODE_FILE"
out=$(HOME="$H3" bash "$OPENCODE_WRAPPER" check)
assert_eq "ok" "$out" "opencode 跨源（脚本存活）check ok"
# 死路径 → missing → install 收敛
sed 's|^const HOOK_SCRIPT = .*|const HOOK_SCRIPT = "/nonexistent/tmux-ai-status"|' "$OPENCODE_FILE" > "$OPENCODE_FILE.tmp" \
    && mv "$OPENCODE_FILE.tmp" "$OPENCODE_FILE"
if HOME="$H3" bash "$OPENCODE_WRAPPER" check >/dev/null 2>&1; then
    echo "FAIL: opencode 死路径 check 应失败"; exit 1
fi
HOME="$H3" bash "$OPENCODE_WRAPPER" >/dev/null
out=$(HOME="$H3" bash "$OPENCODE_WRAPPER" check)
assert_eq "ok" "$out" "opencode 收敛后 check ok"
# check 无副作用
before=$(shasum "$OPENCODE_FILE" | cut -d' ' -f1)
HOME="$H3" bash "$OPENCODE_WRAPPER" check >/dev/null
after=$(shasum "$OPENCODE_FILE" | cut -d' ' -f1)
assert_eq "$before" "$after" "opencode check 不改写文件"

echo "PASS: suppress-cross-source 全部用例通过"
