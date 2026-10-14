#!/bin/bash
# adapters/codex.sh — Codex CLI 工具适配器（需 codex ≥ 0.144）
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=codex 后 source。契约见 adapters/claude.sh 头注释。
#
# ⚠️ Codex 0.144 与 Claude 的关键差异（本 adapter 声明的语义）：
#   - 无 SessionEnd 事件：codex 退出无任何 hook，pane 内 shell 仍活时 pane-exited 也不触发。
#     退出状态由 tmux-ai-monitor 跟踪已见 Codex 的 pane，进程消失后精确清除。
#   - SessionStart 延迟：codex 的 SessionStart hook 延迟到首个 turn 才发（上游
#     run_pending_session_start_hooks），空闲蹲提示符时无事件。空窗期靠 build_all_status
#     用 pane_current_command 补 idle `-`。
#   - hook trust 门禁：user 来源 hook 需 hooks.state.<key>.trusted_hash 匹配才运行；
#     hash 无法在 bash 复现，靠用户首启 codex TUI 点 "Trust all and continue"。

# Codex 只触发 6 个事件（无 SessionEnd/Notification/PostToolUseFailure/StopFailure）。
ADAPTER_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"

# 前台进程名（macOS 上 codex 二进制常为 codex-aarch64-* 等，basename 前缀匹配见
# _pane_has_ai_process 的 case codex*)）
ADAPTER_PROCESS_NAMES="codex"

# hooks 配置：~/.codex/hooks.json（CODEX_HOME 可覆盖）
ADAPTER_HOOKS_FILE="${CODEX_HOME:-$HOME/.codex}/hooks.json"

# Codex 无 SessionEnd → 退出由 tmux-ai-monitor 做进程检测
ADAPTER_HAS_SESSION_END="false"
# SessionStart 延迟到首个 turn
ADAPTER_SESSION_START_TIMING="deferred"
# PermissionRequest 不含 tool_use_id，而 Codex 支持并行工具。核心会将请求绑定到同工具的
# pending PreToolUse ID；无法绑定时用 sentinel 保持 `!` 到 turn/session 边界。
ADAPTER_HOLD_UNMATCHED_PERMISSION="true"
# request_permissions 直接弹出 Codex 权限 UI，但上游不会发送 PermissionRequest hook。
# 它仍发送可配对的 PreToolUse/PostToolUse，因此可在 PreToolUse 阶段精确进入审批态。
ADAPTER_PERMISSION_PRE_TOOL_NAMES="request_permissions"

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-codex-hooks.sh"

# 完整性计数：6 个事件中注册了含 tmux-ai-status codex 的 command 的事件数（按事件，
# 非扁平总数——重复+缺失的组合在扁平计数下会假阳性）。
_CODEX_JQ_COUNT='
    .hooks as $h |
    ["SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop"]
    | map(select([$h[.][]?.hooks[]?.command // empty] | any(contains("tmux-ai-status codex"))))
    | length
'

# 完整性检查：6 事件计数 + 每个事件至少一条条目的脚本文件存活（test -x）。
# 跨安装源路径无关（contains）；脚本死路径（npm 包卸载/volta 换路径，含部分事件死）
# → missing → install 收敛（no-op 门禁随之放行，接受一次 re-trust 代价换功能恢复）。
adapter_check_integrity() {
    [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
    local n ev p ok_events=""
    n=$(jq "$_CODEX_JQ_COUNT" "$ADAPTER_HOOKS_FILE" 2>/dev/null)
    [ "${n:-0}" -ge 6 ] || return 1
    while IFS=$'\t' read -r ev p; do
        if [ -n "$ev" ] && [ -x "$p" ]; then
            case ",$ok_events," in *",$ev,"*) ;; *) ok_events="$ok_events,$ev" ;; esac
        fi
    done < <(jq -r '.hooks as $h |
        ["SessionStart","UserPromptSubmit","PreToolUse","PermissionRequest","PostToolUse","Stop"] as $events |
        $events[] as $e |
        [$h[$e][]?.hooks[]?.command // empty
         | select(contains("tmux-ai-status codex")) | split(" ")[0]] as $scripts |
        select(($scripts | length) > 0) |
        $scripts[] | "\($e)\t\(.)"' "$ADAPTER_HOOKS_FILE" 2>/dev/null)
    for ev in SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop; do
        case ",$ok_events," in *",$ev,"*) ;; *) return 1 ;; esac
    done
    return 0
}

# Codex 6 事件（全部同步——0.144 静默跳过 async=true 的 hook）
_CODEX_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"
_CODEX_LEGACY_TOML="${CODEX_HOME:-$HOME/.codex}/hooks.toml"

# 从每个事件数组剔除本插件 group（command 含 tmux-ai-status），事件/hooks 清空后删键。
_codex_strip_managed() {
    jq '
      def clean_event:
        map(select(
          (.hooks // []) | any(.type == "command" and (.command // "" | contains("tmux-ai-status"))) | not
        ));
      if .hooks then
        .hooks |= (with_entries(.value |= clean_event) | with_entries(select(.value | length > 0)))
      else . end
      | if (.hooks // {}) == {} then del(.hooks) else . end
    '
}

_codex_read_existing() {
    if [ -f "$ADAPTER_HOOKS_FILE" ] && jq empty "$ADAPTER_HOOKS_FILE" >/dev/null 2>&1; then
        cat "$ADAPTER_HOOKS_FILE"
    else
        echo '{}'
    fi
}

# 安装：改写 hooks.json（剥离旧 managed group 后为每事件追加本插件 group），保留他人 hook。
# no-op if valid：事件齐全且脚本存活时不改写——重写即 trusted_hash 失效（command 路径
# 变化 → codex 启动要重新 Trust all），跨安装源重复安装因此保持既有授信。
# 清理旧 hooks.toml（0.144 不再读取）。trust 无法在 bash 复现，靠用户首启 codex TUI 授信。
adapter_install_hooks() {
    _install_require_jq
    mkdir -p "$(dirname "$ADAPTER_HOOKS_FILE")" 2>/dev/null || true
    [ -f "$_CODEX_LEGACY_TOML" ] && rm -f "$_CODEX_LEGACY_TOML" && echo "移除旧 hooks.toml（0.144 不再读取）"
    if adapter_check_integrity; then
        echo "Codex hooks already installed and valid at $ADAPTER_HOOKS_FILE (no-op, trust preserved)"
        return 0
    fi
    local hook_script="${_LIB_DIR}/tmux-ai-status"
    local new_json
    new_json=$(_codex_read_existing | _codex_strip_managed | jq \
        --arg script "$hook_script" \
        --arg events "$_CODEX_EVENTS" '
          .hooks //= {}
          | reduce ($events | split(" ")[]) as $ev (.;
              .hooks[$ev] = ((.hooks[$ev] // []) + [{
                hooks: [{ type: "command", command: ($script + " codex " + $ev), timeout: 5 }]
              }])
            )
        ')
    _install_atomic_write "$new_json" "$ADAPTER_HOOKS_FILE"
    echo "Codex hooks installed to $ADAPTER_HOOKS_FILE"
    echo "Events: $_CODEX_EVENTS"
    echo ""
    echo "⚠️  下次启动 codex 时 TUI 会提示 \"Hooks need review\"，选择 \"Trust all and continue\" 授信一次即可永久生效。"
}

# 卸载：剥离本插件 group，剩空对象则删文件，否则写回。清理旧 toml。
adapter_uninstall_hooks() {
    _install_require_jq
    [ -f "$_CODEX_LEGACY_TOML" ] && rm -f "$_CODEX_LEGACY_TOML" && echo "移除旧 hooks.toml"
    if [ -f "$ADAPTER_HOOKS_FILE" ]; then
        local stripped
        stripped=$(_codex_read_existing | _codex_strip_managed)
        if [ "$(printf '%s' "$stripped" | jq -c .)" = "{}" ]; then
            rm -f "$ADAPTER_HOOKS_FILE"
            echo "Codex hooks uninstalled (removed empty $ADAPTER_HOOKS_FILE)"
        else
            _install_atomic_write "$stripped" "$ADAPTER_HOOKS_FILE"
            echo "Codex hooks uninstalled from $ADAPTER_HOOKS_FILE (preserved external content)"
        fi
    else
        echo "Codex hooks: nothing to uninstall ($ADAPTER_HOOKS_FILE not found)"
    fi
}
