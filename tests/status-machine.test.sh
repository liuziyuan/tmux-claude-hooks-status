#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export FAKE_TMUX_DIR="$TEST_TMP/tmux"
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
# 祖先链解析：hook 进程的父进程就是本测试脚本 → 用 $$ 作为假 pane_pid，
# 让 resolve_tmux_pane 的 ancestry 路径稳定命中 %1。
export FAKE_PANE_PID="$$"
export FAKE_SERVER_PID="${FAKE_SERVER_PID:-1234}"
export FAKE_PANE_PATH="${FAKE_PANE_PATH:-$TEST_TMP/project}"
mkdir -p "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR" "$FAKE_PANE_PATH"

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
                # 孤儿清理查询（fmt 恰以 |#{@ai_pane_status} 结尾）：哨兵 + 两字段行
                *'|#{@ai_pane_status}')
                    : > "$FAKE_TMUX_DIR/full-cleanup-called"
                    printf '%%1|%s\n' "$status"
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
        printf '  log tail:     [%s]\n' "$(tail -3 /tmp/tmux-ai-status.log 2>/dev/null | tr '\n' '|')" >&2
        exit 1
    fi
}

reset_state() {
    rm -rf "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR"
    mkdir -p "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR"
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
: > /tmp/tmux-ai-status.log
FAKE_PANE_PID=999999
printf '%s' '{"session_id":"stop-u"}' | TMUX=test TMUX_PANE= bash "$ROOT/scripts/tmux-ai-status" claude Stop >/dev/null 2>&1
FAKE_PANE_PID=$$
st=$(command cat "$FAKE_TMUX_DIR/pane-status" 2>/dev/null || true)
[ "$st" != "✓" ] || { echo "FAIL: 未解析 pane 的 Stop 不应写入 ✓" >&2; exit 1; }
grep -q "PANE=unresolved" /tmp/tmux-ai-status.log \
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

printf 'status-machine tests passed\n'
