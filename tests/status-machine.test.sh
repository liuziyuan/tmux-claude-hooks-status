#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

export FAKE_TMUX_DIR="$TEST_TMP/tmux"
export TMUX_AI_STATUS_DIR="$TEST_TMP/status"
mkdir -p "$FAKE_TMUX_DIR" "$TMUX_AI_STATUS_DIR"

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
            local status=""
            [ -f "$FAKE_TMUX_DIR/pane-status" ] && status=$(command cat "$FAKE_TMUX_DIR/pane-status")
            printf '%%1|test|1|1|%s|1|1|opencode\n' "$status"
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

printf 'status-machine tests passed\n'
