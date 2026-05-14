# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 术语

**AI Status** — 本项目核心功能的统称。通过 tmux 状态栏实时显示 Claude Code 运行状态，包括状态检测、事件监听、符号渲染、颜色编码等整套机制。

## 当前开发状态

**Claude Code 支持已稳定**。

## 项目概述

tmux 插件，在 tmux 状态栏和窗格边框中显示 Claude Code 的运行状态。通过 hook 系统实时显示每个 pane 的状态（空闲、处理中、等待授权等），以独立状态行呈现。

## 架构

### 文件结构

```
tmux-claude-hooks-status.tmux          # TPM 入口
scripts/
  lib-tmux-ai-status.sh                # 共享库：TMUX_PANE 解析、状态聚合、pane title 监控、日志
  tmux-claude-status                   # Claude Code 事件处理器
  tmux-claude-esc                      # Esc 键拒绝检测（!/? → -）
  install-claude-hooks.sh              # Claude Code hooks 注册/卸载
```

### 共享库 `lib-tmux-ai-status.sh`

被 `tmux-claude-status` 通过 `source` 引入。调用方需设置 `TOOL_ID`（`"claude"`）、`SESSION_ID`。提供：

- **日志** `_ai_log()` — 写入 `/tmp/tmux-ai-status.log`，自动轮转（>100KB 截断至 50KB）
- **TMUX_PANE 解析** `resolve_tmux_pane()` — 通过进程树向上查找所属 pane
- **状态聚合** `build_all_status()` — 扫描 attached session 的所有 pane，读取 `@claude_pane_status`，写入 `@ai_all_status`
- **Pane Title 监控** `_pane_title_is_processing` / `_start_approval_poll` / `_stop_approval_poll` — 后台监控 pane title 变化，检测用户批准权限

### 数据流

```
Claude Code 事件
    ↓
tmux-claude-status 脚本
    ├─ source lib-tmux-ai-status.sh
    ├─ resolve_tmux_pane()（进程树遍历）
    ├─ case "$EVENT" → 直接设置 STATUS 符号
    │   PermissionRequest: 启动后台 approval poll
    │   Stop/UserPromptSubmit/Session*: 停止 poll
    ├─ 写入 per-pane 状态（@claude_pane_status）
    ├─ build_all_status() → @ai_all_status
    └─ tmux refresh-client

后台 approval poll（per pane）:
    ├─ 每 0.3s 检查 pane title
    ├─ title 从 ✳ → 盲文 = 用户已批准
    ├─ 设置 @claude_pane_status ">"，rebuild
    └─ 退出（trap 清理 PID 文件）

tmux session/client 生命周期 hook
    (session-closed, client-detached, client-attached)
    ↓ _refresh → rebuild @ai_all_status

Esc 键拒绝检测（tmux bind-key -n Escape）:
    ├─ 全局拦截 Esc，读取 active pane 的 @claude_pane_status
    ├─ 状态为 ! / ? → 设为 -，rebuild，透传 Esc
    └─ 其余状态 → 直接透传 Esc（~15ms 开销）
```

### Pane Title 监控机制

Claude Code 通过 tmux pane title 显示状态：
- `✳ Claude Code`（U+2733）= 等待用户操作
- `⠐ Claude Code`（盲文字符 U+2800-U+28FF，动态变化）= 处理中/thinking

当 PermissionRequest 到达时：
1. 按 tool_name 直接设 `!` 或 `?`
2. 启动后台 poll 进程监控 pane title
3. Poll 每 0.3s 检查 title，若从 `✳` 变为盲文 = 用户已批准 → 转 `>`
4. 120s 超时自动退出

**Stop 拒绝推断**：Stop 时若 `$PREV_STATUS` 仍为 `!`/`?`，说明权限未被批准 → `-`；否则 → `✓`。

### Claude Code 特有

- **Hooks 完整性校验**：SessionStart 时 `_check_hooks_integrity()` 检测 10 个事件是否都注册了本插件的 hook，缺失则自动修复
- **Notification 事件细分**：idle_prompt / waiting for input → `-`；denied/cancelled → `-`
- **PreToolUse 竞态保护**：PreToolUse 检查 `$PREV_STATUS`，若为 `!`/`?` 则保持不变（不覆盖回 `>`）
- **Fallback 清理**：TMUX_PANE 未解析时，Stop/SessionEnd 遍历所有 pane 清理残留活跃状态

## 状态符号

| 事件 | 状态 | 含义 |
|------|------|------|
| SessionStart | `-` | 会话空闲 |
| UserPromptSubmit / PreToolUse / PostToolUse | `>` | 处理中 |
| PermissionRequest (AskUserQuestion) | `?` | 等待用户输入 |
| PermissionRequest (其他工具) | `!` | 等待授权 |
| Stop / StopFailure | `✓` 或 `-` | `PREV_STATUS` 为 `!`/`?`/`-` → `-`；否则 → `✓` |
| SessionEnd | (空) | 会话结束 |

**聚合优先级**：`!` > `?` > `>` > 空。

## 开发

### 本地设置

```bash
ln -s /Users/liuziyuan/work/home/tmux-claude-hooks-status ~/.tmux/plugins/tmux-claude-hooks-status
prefix + C-h    # 安装 Claude hooks
prefix + r      # 重载（自动触发初始化）
```

### 测试命令

```bash
# 手动触发 Claude 事件
echo '{}' | bash scripts/tmux-claude-status SessionStart
tmux show-option -g @ai_all_status

# 查看 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# 查看 Claude hooks 注册
jq '.hooks | keys' ~/.claude/settings.json

# 查看日志（每次 hook 事件 = 一个多行块：头行含状态转移，缩进行含 tool/input 摘要）
tail -f /tmp/tmux-ai-status.log
# 块头格式: [时间] [claude] [EVENT] [pane]  'prev' → 'curr'
# 示例:
#   [2026-04-30T12:00:00] [claude] [PermissionRequest] [session:1.3]  '>' → '!'
#     tool: Bash  id=toolu_01KwepCiVxbU8eoBYBvwgCxi
#     input: {"command":"ls -la"}

# 模拟权限请求流程
echo '{"tool_use_id":"t1"}' | bash scripts/tmux-claude-status PreToolUse
echo '{"tool_use_id":"t1","tool_name":"Bash"}' | bash scripts/tmux-claude-status PermissionRequest

# 模拟拒绝流程
echo '{}' | bash scripts/tmux-claude-status Stop

# 查看 poll 进程
ls /tmp/claude-status/*/*-poll-pid
```

### 快捷键

| 快捷键 | 操作 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + r` | 重载 tmux 配置（含插件初始化） |

## 关键设计决策

- **共享库架构**：通过 `lib-tmux-ai-status.sh` 提供通用功能，`TOOL_ID` 区分状态变量和临时文件
- **Attached-only 显示**：`build_all_status()` 按 `session_last_attached` 升序、`window_index`/`pane_index` 升序排列，仅显示 attached session
- **进程树解析**：hook 子进程不继承 `$TMUX_PANE`，通过 `ps -o ppid` 向上遍历找到 pane PID
- **多行状态栏**：AI 状态占据独立 `status-format[N]` 行，不修改用户的 `status-right`
- **幂等初始化**：`prefix+r` 重载无副作用（检测已占行、hook 已存在则跳过）
- **Stale hook 清理**：安装时清理指向不存在脚本的旧 hook 和重复路径
- **`!` 和 `?` 对等原则**：两者本质相同——都需要人类审批。对 `!`（PermissionRequest）的任何逻辑变更（竞态保护、Stop 推断、清理路径）必须同步应用到 `?`（AskUserQuestion），反之亦然。差异仅限显示优先级（`!` > `?`）和符号本身
- **Pane title 作为 ground truth**：用 Claude Code 的 pane title 变化（`✳` ↔ 盲文）检测用户批准，替代复杂的 toolmap/flag 状态机
- **Esc 键拒绝检测**：`bind-key -n Escape` 全局拦截，仅在 `!`/`?` 状态时设 `-` 并透传 Esc，其余直接透传。Poll 检测到状态变 `-` 后自动退出，无需显式 stop

## 依赖

- tmux >= 3.1
- jq
- bash >= 4.0

## Hook 事件注册

**Claude Code**（10 个事件，注册到 `~/.claude/settings.json`）：
SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure

全部 async=true，PermissionRequest 例外（async=false 用于立即阻塞）。
