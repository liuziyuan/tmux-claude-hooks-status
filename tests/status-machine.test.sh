#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export FAKE_TMUX_DIR="$TEST_TMP/tmux"
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
# 日志隔离：诊断用例要断言 SUSPECT 埋点，不能读写真实 /tmp 日志
export TMUX_AI_LOG_FILE="$TEST_TMP/ai-status.log"
# 祖先链解析：hook 进程的父进程就是本测试脚本 → 用 $$ 作为假 pane_pid，
# 让 resolve_tmux_pane 的 ancestry 路径稳定命中 %1。
export FAKE_PANE_PID="$$"
export FAKE_SERVER_PID="${FAKE_SERVER_PID:-1234}"
export FAKE_PANE_PATH="${FAKE_PANE_PATH:-$TEST_TMP/project}"
# 隔离修复路径：本文件不测 hooks 修复——HOME 指向临时目录，并预置三个
# suppressed 标记，让 _maybe_repair_hooks / _maybe_repair_other_tools 零子进程。
export HOME="$TEST_TMP/home"
export TMUX_AI_SUPPRESS_DIR="$TEST_TMP/suppress"
unset CLAUDE_CONFIG_DIR CODEX_HOME OPENCODE_CONFIG_DIR XDG_CONFIG_HOME || true
mkdir -p "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR" "$FAKE_PANE_PATH" "$HOME" "$TMUX_AI_SUPPRESS_DIR"
: > "$TMUX_AI_SUPPRESS_DIR/suppressed-claude"
: > "$TMUX_AI_SUPPRESS_DIR/suppressed-codex"
: > "$TMUX_AI_SUPPRESS_DIR/suppressed-opencode"

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
            elif [ "${2:-}" = "-gu" ]; then
                printf '%s\n' "${3:-}" >> "$FAKE_TMUX_DIR/gu.log"
            fi
            ;;
        show-options)
            [ "${2:-}" = "-g" ] && printf '%s' "${FAKE_OPTIONS:-}"
            ;;
        list-clients)
            [ -n "${FAKE_LIST_CLIENTS_FAIL:-}" ] && return 1
            printf '%s\n' "${FAKE_CLIENTS:-}"
            ;;
        list-panes)
            local status="" cmd="${FAKE_PANE_CMD:-opencode}" fmt="${4:-}"
            [ -f "$FAKE_TMUX_DIR/pane-status" ] && status=$(command cat "$FAKE_TMUX_DIR/pane-status")
            case "$fmt" in
                # pane 解析快照：pane|path|cmd|pane_pid|server_pid|attached|title
                *'#{pane_title}'*)
                    : > "$FAKE_TMUX_DIR/snapshot-called"
                    # 模拟 tmux 的 s/[|]/_/ 替换（仅在 format 带修饰符时）
                    local _sp="$FAKE_PANE_PATH" _sc="$cmd"
                    case "$fmt" in *'#{s/[|]/_/:pane_current_path}'*) _sp=$(printf '%s' "$_sp" | tr '|' '_') ;; esac
                    case "$fmt" in *'#{s/[|]/_/:pane_current_command}'*) _sc=$(printf '%s' "$_sc" | tr '|' '_') ;; esac
                    printf '%%1|%s|%s|%s|%s|1|%s\n' \
                        "$_sp" "$_sc" "$FAKE_PANE_PID" "$FAKE_SERVER_PID" "${FAKE_PANE_TITLE:-}"
                    ;;
                # 孤儿清理查询：pane|status|seen_claude|seen_codex|seen_opencode
                # （动态 seen 字段——终态清理认 monitor 标记）
                *'|#{@ai_pane_status}|#{@ai_monitor_seen_'*)
                    : > "$FAKE_TMUX_DIR/full-cleanup-called"
                    printf '%%1|%s|%s|%s|%s\n' "$status" \
                        "${FAKE_SEEN_CLAUDE:-}" "${FAKE_SEEN_CODEX:-}" "${FAKE_SEEN_OPENCODE:-}"
                    ;;
                # 聚合：pane|sess|win|idx|status|attached|created|entered|cur_cmd|prov|prov_id|seen...
                *'@ai_pane_status'*)
                    local _sess="${FAKE_SESSION_NAME:-test}" _cmd="$cmd" _prov="${FAKE_PROVIDER:-}" _provid="${FAKE_PROVIDER_ID:-}"
                    case "$fmt" in *'#{s/[|]/_/:session_name}'*) _sess=$(printf '%s' "$_sess" | tr '|' '_') ;; esac
                    case "$fmt" in *'#{s/[|]/_/:pane_current_command}'*) _cmd=$(printf '%s' "$_cmd" | tr '|' '_') ;; esac
                    case "$fmt" in *'#{s/[|]/_/:@ai_provider}'*) _prov=$(printf '%s' "$_prov" | tr '|' '_') ;; esac
                    case "$fmt" in *'#{s/[|]/_/:@ai_provider_id}'*) _provid=$(printf '%s' "$_provid" | tr '|' '_') ;; esac
                    printf '%%1|%s|1|1|%s|1|1|1|%s|%s|%s|%s|%s|%s\n' \
                        "$_sess" "$status" "$_cmd" "$_prov" "$_provid" \
                        "${FAKE_SEEN_CLAUDE:-}" "${FAKE_SEEN_CODEX:-}" "${FAKE_SEEN_OPENCODE:-}"
                    ;;
                # 孤儿目录清理的 pane 列表查询（format 恰为 #{pane_id}）：必须精确匹配，
                # 否则落到 default 返回聚合行 → 所有 pane 目录被误判孤儿删除
                '#{pane_id}') printf '%%1\n' ;;
                # pane 前台命令 / 进程树查找
                *'#{pane_current_command}'*) printf '%%1|%s\n' "$cmd" ;;
                *'#{pane_pid}'*)
                    case "$fmt" in
                        *'|'*) printf '%%1|%s\n' "$FAKE_PANE_PID" ;;
                        *) printf '%%1 %s\n' "$FAKE_PANE_PID" ;;
                    esac
                    ;;
                *) printf '%%1|test|1|1|%s|1|1|1|%s|||%s|%s|%s\n' \
                        "$status" "$cmd" "${FAKE_SEEN_CLAUDE:-}" "${FAKE_SEEN_CODEX:-}" "${FAKE_SEEN_OPENCODE:-}" ;;
            esac
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

run_event() {
    local tool="$1" event="$2" payload="$3"
    printf '%s' "$payload" | TMUX_PANE='%1' TMUX='test' bash "$ROOT/scripts/tmux-ai-status" "$tool" "$event"
}

assert_status() {
    local expected="$1" context="$2" actual=""
    [ -f "$FAKE_TMUX_DIR/pane-status" ] && actual=$(command cat "$FAKE_TMUX_DIR/pane-status")
    if [ "$actual" != "$expected" ]; then
        printf 'FAIL: %s: expected status %s, got %s\n' "$context" "$expected" "${actual:-<empty>}" >&2
        printf '  pending-perm: [%s]\n' "$(command cat "$TMUX_AI_STATUS_DIR"/_1/pending-perm 2>/dev/null)" >&2
        printf '  pending-pre:  [%s]\n' "$(command cat "$TMUX_AI_STATUS_DIR"/_1/pending-pre 2>/dev/null)" >&2
        printf '  status dir:   [%s]\n' "$(ls "$TMUX_AI_STATUS_DIR"/_1/ 2>/dev/null | tr '\n' ' ')" >&2
        printf '  log tail:     [%s]\n' "$(tail -3 "$TMUX_AI_LOG_FILE" 2>/dev/null | tr '\n' '|')" >&2
        exit 1
    fi
}

reset_state() {
    rm -rf "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR"
    mkdir -p "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR"
}

assert_log_contains() {
    local pattern="$1" context="$2"
    if ! grep -q "$pattern" "$TMUX_AI_LOG_FILE" 2>/dev/null; then
        printf 'FAIL: %s: log missing %s\n' "$context" "$pattern" >&2
        printf '  log tail: [%s]\n' "$(tail -8 "$TMUX_AI_LOG_FILE" 2>/dev/null | tr '\n' '|')" >&2
        exit 1
    fi
}

assert_log_absent() {
    local pattern="$1" context="$2"
    if grep -q "$pattern" "$TMUX_AI_LOG_FILE" 2>/dev/null; then
        printf 'FAIL: %s: log unexpectedly contains %s\n' "$context" "$pattern" >&2
        printf '  log: [%s]\n' "$(grep "$pattern" "$TMUX_AI_LOG_FILE" | tr '\n' '|')" >&2
        exit 1
    fi
}

# Codex PermissionRequest 无 ID，但应绑定紧邻 PreToolUse 的 ID，批准执行后恢复处理中。
run_event codex PreToolUse '{"session_id":"codex-s","tool_use_id":"a","tool_name":"Bash"}'
run_event codex PermissionRequest '{"session_id":"codex-s","tool_name":"Bash"}'
run_event codex PostToolUse '{"session_id":"codex-s","tool_use_id":"a","tool_name":"Bash"}'
assert_status '>' 'Approved Codex permission resumes after matching tool completion'

reset_state

# 并行同类工具只让后启动者请求权限时，应绑定最近的 PreToolUse。
run_event codex PreToolUse '{"session_id":"codex-p","tool_use_id":"a","tool_name":"Bash"}'
run_event codex PreToolUse '{"session_id":"codex-p","tool_use_id":"b","tool_name":"Bash"}'
run_event codex PermissionRequest '{"session_id":"codex-p","tool_name":"Bash"}'
run_event codex PostToolUse '{"session_id":"codex-p","tool_use_id":"a","tool_name":"Bash"}'
assert_status '!' 'Completing an earlier Codex tool preserves the later pending permission'
run_event codex PostToolUse '{"session_id":"codex-p","tool_use_id":"b","tool_name":"Bash"}'
assert_status '>' 'Codex resumes after all bound permissions complete'

reset_state

# 多个并行审批分别绑定不同 ID；完成一个不能清除另一个审批态。
run_event codex PreToolUse '{"session_id":"codex-p2","tool_use_id":"a","tool_name":"Bash"}'
run_event codex PermissionRequest '{"session_id":"codex-p2","tool_name":"Bash"}'
run_event codex PreToolUse '{"session_id":"codex-p2","tool_use_id":"b","tool_name":"Bash"}'
run_event codex PermissionRequest '{"session_id":"codex-p2","tool_name":"Bash"}'
run_event codex PostToolUse '{"session_id":"codex-p2","tool_use_id":"a","tool_name":"Bash"}'
assert_status '!' 'Completing one Codex permission preserves another pending permission'
run_event codex PostToolUse '{"session_id":"codex-p2","tool_use_id":"b","tool_name":"Bash"}'
assert_status '>' 'Codex resumes after all parallel permissions complete'

reset_state

# 找不到对应 PreToolUse 时仍使用 sentinel，避免未知并发事件漏报审批。
run_event codex PermissionRequest '{"session_id":"codex-fallback","tool_name":"Bash"}'
run_event codex PostToolUse '{"session_id":"codex-fallback","tool_use_id":"other","tool_name":"Bash"}'
assert_status '!' 'Unmatched Codex permission keeps conservative sentinel'
run_event codex Stop '{"session_id":"codex-fallback"}'
assert_status '-' 'Codex Stop clears conservative permission state'

reset_state

# Codex request_permissions 绕过 PermissionRequest hook；其 Pre/PostToolUse ID 可精确维护审批态。
run_event codex PreToolUse '{"session_id":"codex-rp","tool_use_id":"rp-1","tool_name":"request_permissions","tool_input":{"permissions":{"file_system":{"write":["/tmp"]}}}}'
assert_status '!' 'Codex request_permissions PreToolUse enters permission state'
run_event codex PreToolUse '{"session_id":"codex-rp","tool_use_id":"other","tool_name":"Bash"}'
run_event codex PostToolUse '{"session_id":"codex-rp","tool_use_id":"other","tool_name":"Bash"}'
assert_status '!' 'Other Codex tools cannot clear request_permissions state'
run_event codex PostToolUse '{"session_id":"codex-rp","tool_use_id":"rp-1","tool_name":"request_permissions"}'
assert_status '>' 'Matching request_permissions PostToolUse resumes processing'

reset_state

# Claude 保留原有串行语义：无 ID 审批在对应工具完成后恢复处理中。
run_event claude PreToolUse '{"session_id":"claude-s","tool_use_id":"a","tool_name":"Bash"}'
run_event claude PermissionRequest '{"session_id":"claude-s","tool_name":"Bash"}'
run_event claude PostToolUse '{"session_id":"claude-s","tool_use_id":"a","tool_name":"Bash"}'
assert_status '>' 'Claude serial permission resumes after tool completion'

reset_state

# Claude async hook 乱序：PermissionRequest 先于 PreToolUse 到达。
# 写入前的 re-derive 只有 pending-perm 派生的 !/? 才可覆写；pending-pre 派生的 '>'
# 不得推翻 live 审批态（AskUserQuestion 的 PreToolUse 项会挂到用户答完才清除）。
: > "$TMUX_AI_LOG_FILE"
run_event claude PermissionRequest '{"session_id":"claude-auq","tool_name":"AskUserQuestion"}'
assert_status '?' 'AskUserQuestion permission enters question state'
run_event claude PreToolUse '{"session_id":"claude-auq","tool_use_id":"q1","tool_name":"AskUserQuestion"}'
assert_status '?' 'Late AskUserQuestion PreToolUse keeps ? state'
assert_log_absent 'SUSPECT' 'Preserving ? raises no SUSPECT'
run_event claude PostToolUse '{"session_id":"claude-auq","tool_use_id":"q1","tool_name":"AskUserQuestion"}'
assert_status '>' 'Completing AskUserQuestion resumes processing'

reset_state

# 同形态的普通工具：晚到的 PreToolUse 不得把 ! 降级为 >。
run_event claude PermissionRequest '{"session_id":"claude-async","tool_name":"Bash"}'
assert_status '!' 'Late Claude permission enters ! state'
run_event claude PreToolUse '{"session_id":"claude-async","tool_use_id":"b1","tool_name":"Bash"}'
assert_status '!' 'Late PreToolUse keeps ! state'
run_event claude PostToolUse '{"session_id":"claude-async","tool_use_id":"b1","tool_name":"Bash"}'
assert_status '>' 'Approved Bash resumes processing'

reset_state

# 状态漂移诊断：审批态被降级为运行态时必须留 SUSPECT，供下次复现时定位事件。
# 构造：两个 AskUserQuestion 并存，完成其一后另一个仍在等 → '?' 被降级为 '>'
# （Post 侧当前未做 live 保护，此用例固定该行为的可观测性）。
: > "$TMUX_AI_LOG_FILE"
run_event claude PreToolUse '{"session_id":"drift","tool_use_id":"q1","tool_name":"AskUserQuestion"}'
run_event claude PreToolUse '{"session_id":"drift","tool_use_id":"q2","tool_name":"AskUserQuestion"}'
run_event claude PermissionRequest '{"session_id":"drift","tool_name":"AskUserQuestion"}'
assert_status '?' 'Drift case: AskUserQuestion enters ? state'
assert_log_absent 'SUSPECT' 'Entering ? state raises no SUSPECT'
run_event claude PostToolUse '{"session_id":"drift","tool_use_id":"q1","tool_name":"AskUserQuestion"}'
assert_status '>' 'Drift case: completing one question downgrades ? (current behavior)'
assert_log_contains 'SUSPECT: downgrade' 'Downgrade with another AskUserQuestion pending is logged'

# 正常路径不误报：唯一的 AskUserQuestion 完成后降级属设计行为
reset_state
: > "$TMUX_AI_LOG_FILE"
run_event claude PreToolUse '{"session_id":"drift-ok","tool_use_id":"q1","tool_name":"AskUserQuestion"}'
run_event claude PermissionRequest '{"session_id":"drift-ok","tool_name":"AskUserQuestion"}'
run_event claude PostToolUse '{"session_id":"drift-ok","tool_use_id":"q1","tool_name":"AskUserQuestion"}'
assert_status '>' 'Normal AskUserQuestion completion resumes processing'
assert_log_absent 'SUSPECT' 'Normal completion raises no SUSPECT'

reset_state

# Notification 隐式路径不得降级活跃状态（async 通知可能乱序晚到）
# 1) 工具有 pending：idle_prompt 迟到 → 保持 '>'
run_event claude PreToolUse '{"session_id":"ntf","tool_use_id":"t1","tool_name":"Bash"}'
run_event claude Notification '{"session_id":"ntf","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
assert_status '>' 'Late idle_prompt keeps pending tool state'

# 2) live 审批态：idle_prompt 不得清 !（claude 不写 pending-perm，需 live 守卫）
reset_state
printf '!' > "$FAKE_TMUX_DIR/pane-status"
run_event claude Notification '{"session_id":"ntf","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
assert_status '!' 'Idle prompt preserves live permission state'

# 3) 显式 denial 消息仍无条件重置为 '-'
reset_state
printf '!' > "$FAKE_TMUX_DIR/pane-status"
run_event claude Notification '{"session_id":"ntf","notification_type":"permission_prompt","message":"Permission denied by user"}'
assert_status '-' 'Explicit denial message resets to idle'

# 4) 审批等待期间 pending-pre 非空（PreToolUse 先于 PermissionRequest）：
#    idle_prompt 不得把 live '!' 降级为 '>'（derive-first 会犯此错）
reset_state
printf '!' > "$FAKE_TMUX_DIR/pane-status"
mkdir -p "$TMUX_AI_STATUS_DIR/_1"
printf 'call_perm Bash %s\n' "$(date +%s)" > "$TMUX_AI_STATUS_DIR/_1/pending-pre"
run_event claude Notification '{"session_id":"ntf","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
assert_status '!' 'Idle prompt must not downgrade live permission state via pending-pre'

# 5) 陈旧 pending（泄漏）不应把 idle 抬成 '>'：条目时间戳超出新鲜窗口
reset_state
rm -f "$FAKE_TMUX_DIR/pane-status"
mkdir -p "$TMUX_AI_STATUS_DIR/_1"
printf 'call_stale Bash %s\n' "$(( $(date +%s) - 3600 ))" > "$TMUX_AI_STATUS_DIR/_1/pending-pre"
run_event claude Notification '{"session_id":"ntf","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
assert_status '-' 'Stale pending entry must not keep busy state on idle prompt'

reset_state

# OpenCode 用 request ID 精确清理：回复一个请求后，另一个请求仍保持审批态。
run_event opencode PreToolUse '{"session_id":"open-s","tool_use_id":"call-a","tool_name":"bash"}'
run_event opencode PreToolUse '{"session_id":"open-s","tool_use_id":"call-b","tool_name":"bash"}'
run_event opencode PermissionRequest '{"session_id":"open-s","tool_use_id":"perm-a","tool_name":"external_directory"}'
run_event opencode PermissionRequest '{"session_id":"open-s","tool_use_id":"perm-b","tool_name":"external_directory"}'
run_event opencode PermissionResolved '{"session_id":"open-s","request_id":"perm-a","reply":"once"}'
run_event opencode PostToolUse '{"session_id":"open-s","tool_use_id":"call-a","tool_name":"bash"}'
assert_status '!' 'OpenCode must keep the second permission pending'
run_event opencode PermissionResolved '{"session_id":"open-s","request_id":"perm-b","reply":"once"}'
assert_status '>' 'OpenCode resumes processing after all permissions resolve'

reset_state

# 相反事件顺序也必须收敛到相同结果：先完成其他工具，再收到第二个审批请求。
run_event opencode PreToolUse '{"session_id":"open-s2","tool_use_id":"call-a","tool_name":"bash"}'
run_event opencode PreToolUse '{"session_id":"open-s2","tool_use_id":"call-b","tool_name":"bash"}'
run_event opencode PermissionRequest '{"session_id":"open-s2","tool_use_id":"perm-a","tool_name":"external_directory"}'
run_event opencode PostToolUse '{"session_id":"open-s2","tool_use_id":"call-a","tool_name":"bash"}'
run_event opencode PermissionRequest '{"session_id":"open-s2","tool_use_id":"perm-b","tool_name":"external_directory"}'
run_event opencode PermissionResolved '{"session_id":"open-s2","request_id":"perm-a","reply":"once"}'
assert_status '!' 'OpenCode interleaving must preserve the unresolved permission'

reset_state

# 两个 hook 真并发启动时，事件锁必须保证最终审批态不被完成事件覆盖。
run_event opencode PreToolUse '{"session_id":"open-s3","tool_use_id":"call-a","tool_name":"bash"}'
run_event opencode PostToolUse '{"session_id":"open-s3","tool_use_id":"call-a","tool_name":"bash"}' &
post_pid=$!
run_event opencode PermissionRequest '{"session_id":"open-s3","tool_use_id":"perm-a","tool_name":"external_directory"}' &
perm_pid=$!
wait "$post_pid"
wait "$perm_pid"
assert_status '!' 'Concurrent OpenCode events must serialize to pending permission state'

# 安装器生成的 plugin 必须传递 request ID 并订阅 reply 事件。
_LIB_DIR="$ROOT/scripts"
source "$ROOT/scripts/adapters/opencode.sh"
PLUGIN_CONTENT=$(_opencode_plugin_content "$ROOT/scripts/tmux-ai-status")
case "$PLUGIN_CONTENT" in
    *'tool_use_id: p.id || ""'*'case "permission.replied"'*'request_id: p.requestID || ""'*) ;;
    *)
        printf 'FAIL: generated OpenCode plugin is missing permission ID/reply mapping\n' >&2
        exit 1
        ;;
esac

# monitor 进程树标记 → switch/volta-shim 前台下补 idle `-`
# （pane_current_command 不是 codex，但 monitor 已确认进程树里有；见 tmux-ai-monitor）
reset_state
rm -f "$FAKE_TMUX_DIR/ai_all_status"
FAKE_PANE_CMD=volta-shim FAKE_SEEN_CODEX=1 run_event claude SessionEnd '{}'
all=$(command cat "$FAKE_TMUX_DIR/ai_all_status" 2>/dev/null || true)
case "$all" in
    *'1.1'*' - '*) ;;
    *) printf 'FAIL: monitor seen 标记应补 idle -（got: %s）\n' "$all" >&2; exit 1 ;;
esac

# 无标记时不应把普通 launcher pane 误显示为 AI
reset_state
rm -f "$FAKE_TMUX_DIR/ai_all_status"
FAKE_PANE_CMD=volta-shim run_event claude SessionEnd '{}'
all=$(command cat "$FAKE_TMUX_DIR/ai_all_status" 2>/dev/null || true)
case "$all" in
    *'1.1'*) printf 'FAIL: 无 seen 标记不应显示 pane\n' >&2; exit 1 ;;
esac

# 聚合字段注入防护：session 名/provider 名含 `|` 不得劈裂字段
# （旧实现：attached 位错位 → $6>0 误判 → 整行消失）
reset_state
rm -f "$FAKE_TMUX_DIR/ai_all_status"
FAKE_SESSION_NAME='evil|sess' FAKE_PROVIDER='prov|name' FAKE_PROVIDER_ID='id|1' \
    run_event claude PreToolUse '{"session_id":"inj","tool_use_id":"i1","tool_name":"Bash"}'
all=$(command cat "$FAKE_TMUX_DIR/ai_all_status" 2>/dev/null || true)
case "$all" in
    *'evil_sess'*) ;;
    *) printf 'FAIL: session 名未被消毒（got: %s）\n' "$all" >&2; exit 1 ;;
esac
case "$all" in
    *'evil|sess'*)
        printf 'FAIL: session 名仍含裸 |（字段会劈裂）\n' >&2; exit 1 ;;
esac
case "$all" in
    *'[prov_name]'*) ;;
    *) printf 'FAIL: provider 名未被消毒（got: %s）\n' "$all" >&2; exit 1 ;;
esac
case "$all" in
    *'1.1'*) ;;
    *) printf 'FAIL: 注入字段导致 pane 段落消失\n' >&2; exit 1 ;;
esac

reset_state

# Stop 在 pane 未解析时不伪造 ✓ 写入日志（真实 pane 可能仍是 !）
printf '!' > "$FAKE_TMUX_DIR/pane-status"
: > "$TMUX_AI_LOG_FILE"
FAKE_PANE_PID=999999
printf '%s' '{"session_id":"stop-u"}' | TMUX=test TMUX_PANE= bash "$ROOT/scripts/tmux-ai-status" claude Stop >/dev/null 2>&1
FAKE_PANE_PID=$$
st=$(command cat "$FAKE_TMUX_DIR/pane-status" 2>/dev/null || true)
[ "$st" != "✓" ] || { echo "FAIL: 未解析 pane 的 Stop 不应写入 ✓" >&2; exit 1; }
grep -q "PANE=unresolved" "$TMUX_AI_LOG_FILE" \
    || { echo "FAIL: Stop 未解析日志应标注 PANE=unresolved" >&2; exit 1; }

reset_state

# @ai_prev_sess_* 残留剪枝：只清已断开 client 的键
# （进程内调用需先 source lib——本用例位于下方批量快照用例之前）
declare -f _maybe_cleanup_stale >/dev/null 2>&1 || { TOOL_ID="claude"; source "$ROOT/scripts/lib-tmux-ai-status.sh"; }
rm -f "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts" "$FAKE_TMUX_DIR/gu.log"
FAKE_OPTIONS='@ai_prev_sess__dev_ttys001 x
@ai_prev_sess__dev_ttys999 y
'
FAKE_CLIENTS='/dev/ttys001'
if _maybe_cleanup_stale; then :; fi
gu=$(command cat "$FAKE_TMUX_DIR/gu.log" 2>/dev/null || true)
case "$gu" in *"@ai_prev_sess__dev_ttys999"*) ;; *) printf 'FAIL: 已断开 client 的 prev_sess 未清理（got: %s）\n' "$gu" >&2; exit 1 ;; esac
case "$gu" in *"@ai_prev_sess__dev_ttys001"*) printf 'FAIL: 存活 client 的 prev_sess 被误清\n' >&2; exit 1 ;; esac

# tmux 抖动（list-clients 失败）时不得把键全删光
rm -f "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts" "$FAKE_TMUX_DIR/gu.log"
FAKE_LIST_CLIENTS_FAIL=1
if _maybe_cleanup_stale; then :; fi
unset FAKE_LIST_CLIENTS_FAIL
[ ! -s "$FAKE_TMUX_DIR/gu.log" ] \
    || { echo "FAIL: list-clients 失败时不应剪枝" >&2; exit 1; }

reset_state

# _refresh 只重建聚合，不应触发 pane 解析快照（避免每次生命周期 hook 做 BFS）
reset_state
rm -f "$FAKE_TMUX_DIR/snapshot-called"
run_event claude _refresh '{}'
[ ! -f "$FAKE_TMUX_DIR/snapshot-called" ] \
    || { echo "FAIL: _refresh 不应解析 pane" >&2; exit 1; }

# _run_refresh 的清理走 60s 节流版（_maybe_cleanup_stale）：
# marker 新鲜时 _refresh 跳过全价清理（哨兵文件由 tmux stub 的清理分支触发）
reset_state
echo "$(( $(date +%s) + 3600 ))" > "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts"
rm -f "$FAKE_TMUX_DIR/full-cleanup-called"
run_event claude _refresh '{}'
[ ! -f "$FAKE_TMUX_DIR/full-cleanup-called" ] \
    || { echo "FAIL: marker 新鲜时 _refresh 应跳过全价清理" >&2; exit 1; }
# 无 marker → 全价清理执行一次
reset_state
rm -f "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts"
run_event claude _refresh '{}'
[ -f "$FAKE_TMUX_DIR/full-cleanup-called" ] \
    || { echo "FAIL: 无 marker 时 _refresh 应跑全价清理" >&2; exit 1; }

# 终态清理认 monitor seen：launcher/daemon 场景进程树不可见时保留 ✓
reset_state
printf '✓' > "$FAKE_TMUX_DIR/pane-status"
rm -f "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts"
FAKE_PANE_CMD=bash FAKE_SEEN_CODEX=1 run_event claude _refresh '{}'
assert_status '✓' 'seen=1 时 ✓ 不被进程树清理'

# 对照组：无 seen 且无 AI 进程 → 清
reset_state
printf '✓' > "$FAKE_TMUX_DIR/pane-status"
rm -f "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts"
FAKE_PANE_CMD=bash run_event claude _refresh '{}'
assert_status '' '无 seen 且无 AI 进程时 ✓ 被清除'

# _cleanup_stale_panes 批量快照：多个 pane 需要进程判定时 ps 只取一次。
# run_event 是子进程、stub 传不进去，改为进程内 source lib 直接调用。
reset_state
TOOL_ID="claude"
source "$ROOT/scripts/lib-tmux-ai-status.sh"
ps_count_file="$TEST_TMP/ps-count"
: > "$ps_count_file"
_ps_process_snapshot() { echo x >> "$ps_count_file"; printf '%s\n' "$$ 1 zsh"; }
run_event claude Stop '{}'   # 留下 ✓ 状态（pane-status=%1|✓）
# if 条件上下文豁免 set -e：_ai_log 末行 `[ size -gt MAX ] && rotate` 在
# 日志未超限时短路返回 1，会让进程内直接调用炸掉 set -e
if _cleanup_stale_panes; then :; fi
[ "$(wc -l < "$ps_count_file" | tr -d ' ')" = "1" ] \
    || { echo "FAIL: cleanup 应只取一次进程快照" >&2; exit 1; }

# PermissionRequest 锁超时降级：事件锁被占用（owner 活着、锁新鲜）时，
# PermReq 应无锁写 ! / ?，且不落 pending 文件、不写 pane 映射、不跑清理。
# 其他事件（PreToolUse）超时丢弃、不写。
# 注意：降级路径实测耗时 = 锁重试预算 ~2s，用例需容忍该延迟。
permreq_downgrade() {  # $1=期望状态 $2=工具名
    reset_state
    local lock="$TMUX_AI_STATUS_DIR/_1/.event-lock"
    mkdir -p "$lock"
    echo "$$" > "$lock/owner"          # 活着的 owner（本测试进程）
    permreq_downgrade_expected="$1"
    if [ "$2" = "AskUserQuestion" ]; then
        run_event claude PermissionRequest '{"session_id":"dg-s","tool_name":"AskUserQuestion"}'
    else
        run_event claude PermissionRequest "{\"session_id\":\"dg-s\",\"tool_name\":\"$2\"}"
    fi
    assert_status "$permreq_downgrade_expected" "PermReq downgrade writes $1 under lock contention"
    [ ! -f "$TMUX_AI_STATUS_DIR/_1/pending-perm" ] \
        || { echo "FAIL: 降级不应写 pending-perm" >&2; exit 1; }
    [ ! -f "$TMUX_AI_STATUS_DIR/_1/pane-dg-s" ] \
        || { echo "FAIL: 降级不应写 pane 映射（跳过 _save_pane_id）" >&2; exit 1; }
    [ ! -f "$TMUX_AI_STATUS_DIR/.stale-cleanup-ts" ] \
        || { echo "FAIL: 降级不应跑 _maybe_cleanup_stale" >&2; exit 1; }
}
permreq_downgrade '!' 'Bash'
permreq_downgrade '?' 'AskUserQuestion'

# 锁占用下非 PermReq 事件仍静默丢弃（无锁写 > 会覆盖并发审批态）
reset_state
mkdir -p "$TMUX_AI_STATUS_DIR/_1/.event-lock"
echo "$$" > "$TMUX_AI_STATUS_DIR/_1/.event-lock/owner"
rm -f "$FAKE_TMUX_DIR/pane-status"
run_event claude PreToolUse '{"session_id":"dg-s","tool_use_id":"x","tool_name":"Bash"}'
[ ! -f "$FAKE_TMUX_DIR/pane-status" ] \
    || { echo "FAIL: 锁占用下 PreToolUse 不应写状态" >&2; exit 1; }

# ── Post 先于 Pre 到达（乱序）：recent-post 拦截迟到的 Pre ──
PANE_DIR="$TMUX_AI_STATUS_DIR/_1"
recent_has() { grep -q "^$1 " "$PANE_DIR/recent-post" 2>/dev/null; }
pre_has() { grep -q "^$1 " "$PANE_DIR/pending-pre" 2>/dev/null; }
perm_has() { grep -q "^$1 " "$PANE_DIR/pending-perm" 2>/dev/null; }

# 1) Post 先到 → 迟到 Pre 不重建 pending，状态保持 >
reset_state
run_event codex PostToolUse '{"session_id":"late-s","tool_use_id":"late-a","tool_name":"Bash"}'
assert_status '>' 'Post 先到：状态为处理中'
run_event codex PreToolUse '{"session_id":"late-s","tool_use_id":"late-a","tool_name":"Bash"}'
assert_status '>' '迟到 Pre 不应改变已完成状态'
pre_has 'late-a' && { echo "FAIL: 迟到 Pre 不应写 pending-pre" >&2; exit 1; }
recent_has 'late-a' || { echo "FAIL: recent-post 应记录已完成 id" >&2; exit 1; }

# 2) 过期 tombstone（>60s）不拦截合法 Pre
reset_state
run_event codex PostToolUse '{"session_id":"exp-s","tool_use_id":"exp-a","tool_name":"Bash"}'
now=$(date +%s)
awk -v ts="$((now - 61))" '{ print $1, ts }' "$PANE_DIR/recent-post" > "$PANE_DIR/recent-post.tmp"
mv "$PANE_DIR/recent-post.tmp" "$PANE_DIR/recent-post"
run_event codex PreToolUse '{"session_id":"exp-s","tool_use_id":"exp-a","tool_name":"Bash"}'
pre_has 'exp-a' || { echo "FAIL: 过期 tombstone 不应拦截 Pre" >&2; exit 1; }
assert_status '>' '过期 tombstone 后 Pre 正常进入处理中'

# 3) 正常 Pre → Post 不回归
reset_state
run_event codex PreToolUse '{"session_id":"ord-s","tool_use_id":"ord-a","tool_name":"Bash"}'
pre_has 'ord-a' || { echo "FAIL: 正常 Pre 应写 pending-pre" >&2; exit 1; }
run_event codex PostToolUse '{"session_id":"ord-s","tool_use_id":"ord-a","tool_name":"Bash"}'
pre_has 'ord-a' && { echo "FAIL: Post 应清 pending-pre" >&2; exit 1; }
recent_has 'ord-a' || { echo "FAIL: Post 应写 recent-post" >&2; exit 1; }

# 4) Stop 清 pending 后，迟到的 Pre 仍被 tombstone 拦截
reset_state
run_event codex PostToolUse '{"session_id":"stop-s","tool_use_id":"stop-a","tool_name":"Bash"}'
run_event codex Stop '{"session_id":"stop-s"}'
assert_status '✓' 'Stop 后状态为 ✓'
run_event codex PreToolUse '{"session_id":"stop-s","tool_use_id":"stop-a","tool_name":"Bash"}'
assert_status '✓' 'Stop 后迟到 Pre 不应回退状态'
pre_has 'stop-a' && { echo "FAIL: Stop 后迟到 Pre 不应写 pending-pre" >&2; exit 1; }

# 5) codex request_permissions：迟到 Pre 不得复活审批态
reset_state
run_event codex PostToolUse '{"session_id":"rp-s","tool_use_id":"rp-a","tool_name":"request_permissions"}'
run_event codex PreToolUse '{"session_id":"rp-s","tool_use_id":"rp-a","tool_name":"request_permissions"}'
assert_status '>' 'request_permissions 迟到 Pre 不应复活 !'
perm_has 'rp-a' && { echo "FAIL: 迟到 Pre 不应写 pending-perm" >&2; exit 1; }

# 6) opencode 同构（callID）
reset_state
run_event opencode PostToolUse '{"session_id":"oc-s","tool_use_id":"oc-a","tool_name":"bash"}'
run_event opencode PreToolUse '{"session_id":"oc-s","tool_use_id":"oc-a","tool_name":"bash"}'
pre_has 'oc-a' && { echo "FAIL: opencode 迟到 Pre 不应写 pending-pre" >&2; exit 1; }
run_event opencode PreToolUse '{"session_id":"oc-s","tool_use_id":"oc-b","tool_name":"bash"}'
run_event opencode PostToolUse '{"session_id":"oc-s","tool_use_id":"oc-b","tool_name":"bash"}'
pre_has 'oc-b' && { echo "FAIL: opencode 正常配对应清理" >&2; exit 1; }

# 7) 重复 Post 只保留一条 tombstone
reset_state
run_event codex PostToolUse '{"session_id":"dup-s","tool_use_id":"dup-a","tool_name":"Bash"}'
run_event codex PostToolUse '{"session_id":"dup-s","tool_use_id":"dup-a","tool_name":"Bash"}'
[ "$(grep -c '^dup-a ' "$PANE_DIR/recent-post" 2>/dev/null || true)" = "1" ] \
    || { echo "FAIL: recent-post 同 id 应只有一条" >&2; exit 1; }

# 8) 300s 修剪：旧记录在下次写入时移除
reset_state
run_event codex PostToolUse '{"session_id":"prune-s","tool_use_id":"seed","tool_name":"Bash"}'
printf 'old-id %s\n' "$(( $(date +%s) - 400 ))" >> "$PANE_DIR/recent-post"
run_event codex PostToolUse '{"session_id":"prune-s","tool_use_id":"prune-new","tool_name":"Bash"}'
recent_has 'old-id' && { echo "FAIL: 过期 recent-post 应被修剪" >&2; exit 1; }
recent_has 'prune-new' || { echo "FAIL: 新记录应写入 recent-post" >&2; exit 1; }

# 9) 日志轮转：保留轮转前完整现场（.1），主文件只留尾部
declare -f _ai_log_rotate >/dev/null 2>&1 || { TOOL_ID="claude"; source "$ROOT/scripts/lib-tmux-ai-log.sh"; }
_rot="$TEST_TMP/rotate.log"
AI_LOG_FILE="$_rot"
AI_LOG_BACKUP_FILE="${_rot}.1"
AI_LOG_LOCK_DIR="${_rot}.lock"
for i in $(seq 1 6000); do
    printf '%s\n' "0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789"
done > "$AI_LOG_FILE"
_rot_full=$(wc -c < "$AI_LOG_FILE" | tr -d ' ')
_ai_log_rotate
_rot_backup=$(wc -c < "$AI_LOG_BACKUP_FILE" 2>/dev/null | tr -d ' ' || echo 0)
_rot_kept=$(wc -c < "$AI_LOG_FILE" | tr -d ' ')
[ "${_rot_full:-0}" -gt 524288 ] || { echo "FAIL: 轮转用例样本不足 512KB" >&2; exit 1; }
[ "${_rot_backup:-0}" = "${_rot_full:-1}" ] || { echo "FAIL: 轮转应保留完整备份（${_rot_backup:-0} vs ${_rot_full:-0}）" >&2; exit 1; }
[ "${_rot_kept:-0}" -le 262144 ] || { echo "FAIL: 轮转后主文件应截断到 256KB" >&2; exit 1; }

printf 'status-machine tests passed\n'
