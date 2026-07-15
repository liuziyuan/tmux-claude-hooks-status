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

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-codex-hooks.sh"

# 完整性检查：hooks.json 是否含 6 个本插件 command（0.144+）。
adapter_check_integrity() {
    [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
    local n
    n=$(jq '[.hooks[]?[]?.hooks[]?.command // empty
             | select(contains("tmux-ai-status codex"))] | length' \
        "$ADAPTER_HOOKS_FILE" 2>/dev/null)
    [ "${n:-0}" -ge 6 ]
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
# 清理旧 hooks.toml（0.144 不再读取）。trust 无法在 bash 复现，靠用户首启 codex TUI 授信。
adapter_install_hooks() {
    _install_require_jq
    mkdir -p "$(dirname "$ADAPTER_HOOKS_FILE")" 2>/dev/null || true
    [ -f "$_CODEX_LEGACY_TOML" ] && rm -f "$_CODEX_LEGACY_TOML" && echo "移除旧 hooks.toml（0.144 不再读取）"
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
