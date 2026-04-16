# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 术语

**AI Status** — 本项目核心功能的统称。通过 tmux 状态栏实时显示 AI 编程助手（Claude Code、GitHub Copilot CLI 等）运行状态，包括状态检测、事件监听、符号渲染、颜色编码等整套机制。

## 当前开发状态

**Claude Code 支持已稳定**，不需要进一步调试。后续工作重点在 **Copilot CLI 支持的调试和完善**。

## 项目概述

tmux 插件，在 tmux 状态栏和窗格边框中显示 AI 编程助手的运行状态。通过 hook 系统实时显示每个 pane 的状态（空闲、处理中、等待授权等），以独立状态行呈现。

## 架构

### 文件结构

```
tmux-claude-hooks-status.tmux          # TPM 入口（85行）
scripts/
  lib-tmux-ai-status.sh                # 共享库：TMUX_PANE 解析、状态聚合、watcher、竞态保护、日志（216行）
  tmux-claude-status                   # Claude Code 事件处理器（174行）
  tmux-copilot-status                  # Copilot CLI 事件处理器（67行）
  install-claude-hooks.sh              # Claude Code hooks 注册/卸载（125行）
  install-copilot-hooks.sh             # Copilot CLI hooks 注册/卸载（93行）
```

### 共享库 `lib-tmux-ai-status.sh`

被 `tmux-claude-status` 和 `tmux-copilot-status` 通过 `source` 引入。调用方需设置 `TOOL_ID`（`"claude"` 或 `"copilot"`）。提供：

- **日志** `_ai_log()` — 写入 `/tmp/tmux-ai-status.log`，自动轮转（>100KB 截断至 50KB）
- **TMUX_PANE 解析** `resolve_tmux_pane()` — 通过进程树向上查找所属 pane
- **状态聚合** `build_all_status()` — 扫描 attached session 的所有 pane，合并 `@claude_pane_status` 和 `@copilot_pane_status`，写入 `@ai_all_status`
- **竞态保护** `_set_protection` / `_is_protected` / `_clear_protection` — 基于时间戳文件，3 秒窗口
- **Watcher 管理** `start_status_watcher()` / `kill_watcher()` — 后台进程监控 !/? 状态，防止被竞态覆盖

### 数据流

```
AI 事件（Claude Code / Copilot CLI）
    ↓
对应 tmux-*-status 脚本
    ├─ source lib-tmux-ai-status.sh
    ├─ resolve_tmux_pane()（进程树遍历）
    ├─ case "$EVENT" → 映射状态符号
    ├─ 写入 per-pane 状态（@claude_pane_status 或 @copilot_pane_status）
    ├─ build_all_status() → @ai_all_status
    ├─ 可选: spawn watcher（!/? 状态）
    └─ tmux refresh-client

tmux session/client 生命周期 hook
    (session-closed, client-detached, client-attached)
    ↓ _refresh → rebuild @ai_all_status
```

### 竞态保护机制

PermissionRequest 和 AskUserQuestion 设置 !/? 时，写入时间戳文件 `/tmp/${TOOL_ID}-protect-${TMUX_PANE}`。异步 PostToolUse 检查此文件，3 秒窗口内跳过。Watcher 进程在 ! 被竞态覆盖为 > 时重新断言。

### Claude Code 特有

- **Hooks 完整性校验**：SessionStart 时 `_check_hooks_integrity()` 检测 10 个事件是否都注册了本插件的 hook，缺失则自动修复
- **Notification 事件细分**：根据消息内容（waiting for input / denied / permission）分发到不同状态
- **Stop/StopFailure 智能状态**：当前状态为 ! 时回到 -（被拒绝），其余显示 ✓
- **Fallback 清理**：TMUX_PANE 未解析时，遍历所有 pane 清理残留的 > 和 ! 状态

### Copilot CLI 特有

- **Hooks 安装方式**：通过 `copilot plugin install` 注册，fallback 到直接复制到 `~/.copilot/installed-plugins/_direct/`
- **事件映射**：SessionStart → -，PreToolUse/PostToolUse → >，ErrorOccurred → !（带 watcher）
- **JSON 字段差异**：Copilot 使用 `toolName` 而非 Claude 的 `tool_name`

## 状态符号

| 事件 | 状态 | 含义 |
|------|------|------|
| SessionStart | `-` | 会话空闲 |
| PreToolUse / PostToolUse | `>` | 处理中 |
| PreToolUse (AskUserQuestion) | `?` | 等待用户输入 |
| PermissionRequest | `!` | 等待授权 |
| Stop / StopFailure | `✓` 或 `-` | 完成或回到空闲 |
| SessionEnd | (空) | 会话结束 |

## 开发

### 本地设置

```bash
ln -s /Users/liuziyuan/work/home/tmux-claude-hooks-status ~/.tmux/plugins/tmux-claude-hooks-status
prefix + C-h    # 安装 Claude hooks
prefix + C-g    # 安装 Copilot hooks
prefix + r      # 重载（自动触发初始化）
```

### 测试命令

```bash
# 手动触发 Claude 事件
echo '{}' | bash scripts/tmux-claude-status SessionStart
tmux show-option -g @ai_all_status

# 查看 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status} #{@copilot_pane_status}"

# 查看 Claude hooks 注册
jq '.hooks | keys' ~/.claude/settings.json

# 查看日志
tail -f /tmp/tmux-ai-status.log

# 模拟权限请求
echo '{}' | bash scripts/tmux-claude-status PermissionRequest
```

### 快捷键

| 快捷键 | 操作 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + C-g` | 安装 Copilot hooks |
| `prefix + C-G` | 卸载 Copilot hooks |
| `prefix + r` | 重载 tmux 配置（含插件初始化） |

## 关键设计决策

- **共享库架构**：Claude 和 Copilot 共用 `lib-tmux-ai-status.sh`，通过 `TOOL_ID` 区分状态变量和临时文件
- **Attached-only 显示**：`build_all_status()` 按 `session_last_attached` 降序、`window_index`/`pane_index` 升序排列，仅显示 attached session
- **进程树解析**：hook 子进程不继承 `$TMUX_PANE`，通过 `ps -o ppid` 向上遍历找到 pane PID
- **多行状态栏**：AI 状态占据独立 `status-format[N]` 行，不修改用户的 `status-right`
- **幂等初始化**：`prefix+r` 重载无副作用（检测已占行、hook 已存在则跳过）
- **Stale hook 清理**：安装时清理指向不存在脚本的旧 hook 和重复路径

## 依赖

- tmux >= 3.1
- jq
- bash >= 4.0

## Hook 事件注册

**Claude Code**（10 个事件，注册到 `~/.claude/settings.json`）：
SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure

全部 async=true，PermissionRequest 例外（async=false 用于立即阻塞）。

**Copilot CLI**（6 个事件，通过 plugin 系统注册）：
sessionStart, sessionEnd, userPromptSubmit, preToolUse, postToolUse, errorOccurred
