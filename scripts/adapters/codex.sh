#!/bin/bash
# adapters/codex.sh — Codex CLI 工具适配器（需 codex ≥ 0.144）
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=codex 后 source。契约见 adapters/claude.sh 头注释。
#
# ⚠️ Codex 0.144 与 Claude 的关键差异（本 adapter 声明的语义）：
#   - 无 SessionEnd 事件：codex 退出无任何 hook，pane 内 shell 仍活时 pane-exited 也不触发。
#     退出残留状态只能靠 _cleanup_stale_panes 的进程树检测（codex 进程消失即清）。
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

# Codex 无 SessionEnd → 退出靠进程检测兜底
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
