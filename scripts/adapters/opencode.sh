#!/bin/bash
# adapters/opencode.sh — opencode (sst/opencode) 工具适配器
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=opencode 后 source。契约见 adapters/claude.sh 头注释。
#
# ⚠️ opencode 与 Claude/Codex 的关键差异（本 adapter 声明的语义）：
#   - 无独立 hooks 配置文件：opencode 用 JS/TS **plugin** 模型（~/.config/opencode/plugins/），
#     不是 Claude 的 settings.json / Codex 的 hooks.json。ADAPTER_HOOKS_FILE 指向本插件生成的
#     单个 plugin 文件（.ts），install/uninstall 是整文件写入/删除，不做 jq 合并。
#   - plugin 内部订阅 opencode 的命名 hook（chat.message / tool.execute.before/after）+ 通用
#     event 流（session.created/idle、permission.*、question.*），拼成 Claude 规范 JSON 后
#     pipe 给本仓库 tmux-ai-status，核心引擎（tmux-ai-status 的事件 case）零改动。
#   - opencode 有两套独立「问用户」系统，均经 event 流（非命名 hook，见 issue #7006
#     permission.ask hook 从不触发）：Permission（bash/edit 授权）发 permission.asked/replied
#     → `!`；Question（AskUserQuestion 选项弹窗）发 question.asked/replied/rejected，adapter
#     把 tool_name 填 "AskUserQuestion" → core 派生 `?`。两套的 request_id 用事件 .id/.requestID
#     精确配对解除。
#   - 无 SessionEnd：退出无 hook，由 tmux-ai-monitor 做进程检测清理（同 codex）。
#   - SessionStart 即时：session.created 在会话建立时立即触发（不同于 codex 的 deferred）。

# 6 个规范生命周期事件 + 精确解除审批态的内部 PermissionResolved 事件。
ADAPTER_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PermissionResolved PostToolUse Stop"

# 前台进程名：opencode 二进制无 arch 后缀（区别于 codex 的 codex-aarch64-* 等）
ADAPTER_PROCESS_NAMES="opencode"

# plugin 文件路径（XDG 全局目录，OPENCODE_CONFIG_DIR 可覆盖）
ADAPTER_HOOKS_FILE="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/plugins/tmux-ai-status.ts"

# opencode 无 SessionEnd → 退出由 tmux-ai-monitor 做进程检测
ADAPTER_HAS_SESSION_END="false"
# session.created 即时触发
ADAPTER_SESSION_START_TIMING="immediate"
# permission.asked / question.asked 均携带请求 ID（.id），不需要无 ID sentinel。
ADAPTER_HOLD_UNMATCHED_PERMISSION="false"

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-opencode-hooks.sh"

_OPENCODE_MARKER="tmux-ai-status (managed by tmux-ai-hooks-status)"

# 完整性检查：plugin 文件存在且含本插件标记 + 指向当前仓库的 hook 脚本路径。
adapter_check_integrity() {
    [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
    grep -q "$_OPENCODE_MARKER" "$ADAPTER_HOOKS_FILE" 2>/dev/null || return 1
    grep -q "${_LIB_DIR}/tmux-ai-status" "$ADAPTER_HOOKS_FILE" 2>/dev/null || return 1
    grep -q 'case "permission.asked"' "$ADAPTER_HOOKS_FILE" 2>/dev/null || return 1
    grep -q 'case "question.asked"' "$ADAPTER_HOOKS_FILE" 2>/dev/null || return 1
    grep -q 'case "permission.replied"' "$ADAPTER_HOOKS_FILE" 2>/dev/null || return 1
    grep -q 'request_id: p.requestID' "$ADAPTER_HOOKS_FILE" 2>/dev/null
}

# 生成 plugin 文件内容。$1 = tmux-ai-status 绝对路径。
_opencode_plugin_content() {
    local hook_script="$1"
    cat <<EOF
// ${_OPENCODE_MARKER} — do not edit, changes will be overwritten on reinstall
// 由 install-opencode-hooks.sh 生成。把 opencode 原生事件映射为 Claude 规范事件，
// 拼规范 JSON 喂给 tmux-ai-status，核心引擎（tmux-ai-status 的事件 case）零改动。

const HOOK_SCRIPT = "${hook_script}"

export const TmuxAiStatus = async ({ \$ }) => {
  const fire = (eventName, payload) => {
    const json = JSON.stringify(payload || {})
    return \$\`printf '%s' \${json} | \${HOOK_SCRIPT} opencode \${eventName}\`.quiet().nothrow()
  }

  // opencode 用「命名 hook」派发消息/工具执行点（chat.message / tool.execute.*），
  // 权限与提问走通用 event 流（permission.* / question.*），会话生命周期也走 event 流
  // （session.created/idle）。分开映射：
  return {
    // 用户提交提示词
    "chat.message": async (input) => {
      await fire("UserPromptSubmit", { session_id: input.sessionID || "" })
    },
    // 工具开始执行
    "tool.execute.before": async (input) => {
      await fire("PreToolUse", {
        session_id: input.sessionID || "",
        tool_name: input.tool || "",
        tool_use_id: input.callID || "",
      })
    },
    // 工具执行完毕
    "tool.execute.after": async (input) => {
      await fire("PostToolUse", {
        session_id: input.sessionID || "",
        tool_name: input.tool || "",
        tool_use_id: input.callID || "",
      })
    },
    // 通用事件流。opencode 有两套独立「问用户」系统，各发各的事件（均经 event 流，
    // 不经命名 hook —— permission.ask 命名 hook 上游从不触发，见 issue #7006）：
    //
    //   1. Permission（bash/edit 等授权）：
    //      permission.asked   → PermissionRequest（tool_name≠AskUserQuestion → \`!\`）
    //        properties: {id, sessionID, permission=工具名, tool:{callID}}
    //      permission.replied → PermissionResolved
    //        properties: {sessionID, requestID, reply: once|always|reject}
    //
    //   2. Question（AskUserQuestion 选项弹窗）：
    //      question.asked    → PermissionRequest（tool_name=AskUserQuestion → \`?\`）
    //        properties: {id, sessionID, questions[], tool:{callID}}
    //      question.replied  → PermissionResolved（用户作答）
    //      question.rejected → PermissionResolved（用户 dismiss）
    //        properties: {sessionID, requestID, ...}
    //
    // 两套的 request_id 均取事件的 .id（ask）/.requestID（reply），core 精确配对解除。
    event: async ({ event }) => {
      const p = event.properties || {}
      switch (event.type) {
        case "session.created":
          return fire("SessionStart", { session_id: p.sessionID || p.id || "" })
        case "session.idle":
          return fire("Stop", { session_id: p.sessionID || p.id || "" })
        case "permission.asked":
          return fire("PermissionRequest", {
            session_id: p.sessionID || "",
            tool_name: p.permission || "",
            tool_use_id: p.id || "",
          })
        case "question.asked":
          return fire("PermissionRequest", {
            session_id: p.sessionID || "",
            tool_name: "AskUserQuestion",
            tool_use_id: p.id || "",
          })
        case "permission.replied":
        case "question.replied":
        case "question.rejected":
          return fire("PermissionResolved", {
            session_id: p.sessionID || "",
            request_id: p.requestID || "",
            reply: p.reply || "",
          })
      }
    },
  }
}
EOF
}

# 安装：写出/覆盖 plugin 文件。整文件替换（非合并）——同目录下他人 plugin 文件不受影响。
adapter_install_hooks() {
    mkdir -p "$(dirname "$ADAPTER_HOOKS_FILE")" 2>/dev/null || true
    local hook_script="${_LIB_DIR}/tmux-ai-status"
    local content
    content=$(_opencode_plugin_content "$hook_script")
    _install_atomic_write "$content" "$ADAPTER_HOOKS_FILE"
    echo "opencode plugin installed to $ADAPTER_HOOKS_FILE"
    echo "Events: $ADAPTER_EVENTS"
    echo ""
    echo "⚠️  下次启动 opencode 会自动加载该 plugin（本地文件插件无需额外授信）。"
}

# 卸载：仅当文件由本插件生成（含 marker）时删除，避免误删用户自建同名 plugin。
adapter_uninstall_hooks() {
    if [ -f "$ADAPTER_HOOKS_FILE" ]; then
        if grep -q "$_OPENCODE_MARKER" "$ADAPTER_HOOKS_FILE" 2>/dev/null; then
            rm -f "$ADAPTER_HOOKS_FILE"
            echo "opencode plugin uninstalled (removed $ADAPTER_HOOKS_FILE)"
        else
            echo "opencode plugin: $ADAPTER_HOOKS_FILE 非本插件生成，跳过删除"
        fi
    else
        echo "opencode plugin: nothing to uninstall ($ADAPTER_HOOKS_FILE not found)"
    fi
}
