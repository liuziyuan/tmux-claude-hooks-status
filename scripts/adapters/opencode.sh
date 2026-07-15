#!/bin/bash
# adapters/opencode.sh — opencode (sst/opencode) 工具适配器
#
# 由 lib-tmux-ai-status.sh 在确定 TOOL_ID=opencode 后 source。契约见 adapters/claude.sh 头注释。
#
# ⚠️ opencode 与 Claude/Codex 的关键差异（本 adapter 声明的语义）：
#   - 无独立 hooks 配置文件：opencode 用 JS/TS **plugin** 模型（~/.config/opencode/plugins/），
#     不是 Claude 的 settings.json / Codex 的 hooks.json。ADAPTER_HOOKS_FILE 指向本插件生成的
#     单个 plugin 文件（.ts），install/uninstall 是整文件写入/删除，不做 jq 合并。
#   - plugin 内部订阅 opencode 的命名 hook（chat.message / tool.execute.before/after /
#     permission.ask）+ 通用 event 流（session.created/idle），拼成 Claude 规范 JSON 后
#     pipe 给本仓库 tmux-ai-status，核心引擎（tmux-ai-status 的事件 case）零改动。
#   - opencode 无法区分「等待普通授权」与「AskUserQuestion」，permission.asked 统一映射
#     PermissionRequest 且不传 tool_name=AskUserQuestion，故派生状态固定为 `!`（不出现 `?`）。
#   - 无 SessionEnd：退出无 hook，由 tmux-ai-monitor 做进程检测清理（同 codex）。
#   - SessionStart 即时：session.created 在会话建立时立即触发（不同于 codex 的 deferred）。

# opencode 只触发 6 个规范事件（无 SessionEnd/Notification/PostToolUseFailure/StopFailure）
ADAPTER_EVENTS="SessionStart UserPromptSubmit PreToolUse PermissionRequest PostToolUse Stop"

# 前台进程名：opencode 二进制无 arch 后缀（区别于 codex 的 codex-aarch64-* 等）
ADAPTER_PROCESS_NAMES="opencode"

# plugin 文件路径（XDG 全局目录，OPENCODE_CONFIG_DIR 可覆盖）
ADAPTER_HOOKS_FILE="${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}/plugins/tmux-ai-status.ts"

# opencode 无 SessionEnd → 退出由 tmux-ai-monitor 做进程检测
ADAPTER_HAS_SESSION_END="false"
# session.created 即时触发
ADAPTER_SESSION_START_TIMING="immediate"

# 自修复/TUI 调用的安装脚本
ADAPTER_INSTALLER="${_LIB_DIR}/install-opencode-hooks.sh"

_OPENCODE_MARKER="tmux-ai-status (managed by tmux-ai-hooks-status)"

# 完整性检查：plugin 文件存在且含本插件标记 + 指向当前仓库的 hook 脚本路径。
adapter_check_integrity() {
    [ -f "$ADAPTER_HOOKS_FILE" ] || return 1
    grep -q "$_OPENCODE_MARKER" "$ADAPTER_HOOKS_FILE" 2>/dev/null || return 1
    grep -q "${_LIB_DIR}/tmux-ai-status" "$ADAPTER_HOOKS_FILE" 2>/dev/null
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

  // opencode 用「命名 hook」派发大多数生命周期点（chat.message / tool.execute.* /
  // permission.ask），仅 session 级用通用 event 流（session.idle）。分开映射：
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
    // 权限询问命名 hook（部分场景由 permission.ask 触发；opencode 无法区分普通授权
    // 与 AskUserQuestion，统一 → \`!\`）
    "permission.ask": async (input) => {
      await fire("PermissionRequest", {
        session_id: input.sessionID || "",
        tool_name: input.type || input.permission || "",
      })
    },
    // 通用事件流：会话建立即时 SessionStart，会话空闲 → Stop（turn 完成），
    // permission.asked（弹窗通知，字段 permission=工具名 / sessionID）→ PermissionRequest
    event: async ({ event }) => {
      const p = event.properties || {}
      switch (event.type) {
        case "session.created":
          return fire("SessionStart", { session_id: p.sessionID || p.id || "" })
        case "session.idle":
          return fire("Stop", { session_id: p.sessionID || p.id || "" })
        case "permission.asked":
          return fire("PermissionRequest", {
            session_id: p.sessionID || p.session_id || "",
            tool_name: p.permission || p.type || p.tool || "",
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
