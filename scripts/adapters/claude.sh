#!/bin/bash
# adapters/claude.sh — Claude Code 工具适配器
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=claude 后 source。声明 Claude Code 与其他
# AI CLI 的差异；核心引擎读本文件暴露的变量/函数分派，不再写 case "$TOOL_ID"。
#
# 契约（每个 adapter 必须定义）：
#   ADAPTER_EVENTS            该工具触发的事件集合（空格分隔）
#   ADAPTER_PROCESS_NAMES     进程名（basename）集合，供 _pane_has_ai_process 识别
#   ADAPTER_HOOKS_FILE        hooks 配置文件绝对路径
#   ADAPTER_HAS_SESSION_END   "true"|"false" 是否有 SessionEnd 事件
#   ADAPTER_SESSION_START_TIMING  "immediate"|"deferred" SessionStart 时机
#   ADAPTER_INSTALLER         install 脚本绝对路径（供自修复/TUI 调用）
#   adapter_check_integrity() hooks 是否完整注册本插件（返回 0=完整）

# Claude Code 注册 10 个事件，全部 async（PermissionRequest 例外 sync）。
ADAPTER_EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse PostToolUseFailure PermissionRequest Notification Stop StopFailure"

# 前台进程名（BFS pane 进程树匹配 basename）
ADAPTER_PROCESS_NAMES="claude"

# hooks 配置：~/.claude/settings.json（CLAUDE_CONFIG_DIR 可覆盖）
ADAPTER_HOOKS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

# Claude Code 有 SessionEnd 事件，退出即发 hook → 状态可主动清。
ADAPTER_HAS_SESSION_END="true"
# SessionStart 在 CLI 启动时立即触发（对比 codex 延迟到首个 turn）。
ADAPTER_SESSION_START_TIMING="immediate"

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-claude-hooks.sh"

# 完整性检查：settings.json 的 10 个事件是否都注册了本插件 hook。
# 缺失（外部应用覆盖配置）→ 返回 1。
adapter_check_integrity() {
    [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
    local registered
    registered=$(jq '
        .hooks as $h |
        ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
         "PostToolUseFailure","PermissionRequest","Notification","Stop","StopFailure"]
        | map(select([$h[.][]?.hooks[]?.command // empty] | any(contains("tmux-ai-status"))))
        | length
    ' "$ADAPTER_HOOKS_FILE" 2>/dev/null)
    [ "${registered:-0}" -ge 10 ]
}
