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
  lib-tmux-ai-status.sh                # 共享库：TMUX_PANE 解析、状态聚合、tool_state map、日志
  tmux-claude-status                   # Claude Code 事件处理器
  install-claude-hooks.sh              # Claude Code hooks 注册/卸载
```

### 共享库 `lib-tmux-ai-status.sh`

被 `tmux-claude-status` 通过 `source` 引入。调用方需设置 `TOOL_ID`（`"claude"`）、`SESSION_ID`。提供：

- **日志** `_ai_log()` — 写入 `/tmp/tmux-ai-status.log`，自动轮转（>100KB 截断至 50KB）
- **TMUX_PANE 解析** `resolve_tmux_pane()` — 通过进程树向上查找所属 pane
- **状态聚合** `build_all_status()` — 扫描 attached session 的所有 pane，读取 `@claude_pane_status`，写入 `@ai_all_status`
- **tool_state map** `_toolmap_set` / `_toolmap_set_pending_guarded` / `_toolmap_clear` / `_toolmap_has_awaiting` / `_toolmap_has_pending` — per-pane 工具状态队列，mkdir 原子锁
- **Ask 标志** `_set_ask_flag` / `_clear_ask_flag` / `_has_ask_flag` — AskUserQuestion 的独立 `?` 状态标志
- **状态聚合计算** `_compute_status` — 按优先级 `!` > `?` > `>` > 空 计算显示符号

### 数据流

```
Claude Code 事件
    ↓
tmux-claude-status 脚本
    ├─ source lib-tmux-ai-status.sh
    ├─ resolve_tmux_pane()（进程树遍历）
    ├─ case "$EVENT" → 更新 tool_state map / ask flag
    ├─ _compute_status → 聚合符号
    ├─ 写入 per-pane 状态（@claude_pane_status）
    ├─ build_all_status() → @ai_all_status
    └─ tmux refresh-client

tmux session/client 生命周期 hook
    (session-closed, client-detached, client-attached)
    ↓ _refresh → rebuild @ai_all_status
```

### tool_state 队列机制

每 pane 一个 map 文件 `/tmp/claude-${SESSION_ID}-${PANE_SANITIZED}-toolmap`，每行 `tool_use_id:STATE`：

| STATE | 含义 | 何时写入 |
|-------|------|----------|
| `P` | PENDING | PreToolUse（未知是否需权限） |
| `A` | AWAITING_PERM | PermissionRequest（等用户响应） |
| `C` | COMPLETED | PostToolUse |

所有读改写用 `mkdir $file.lock` 原子锁保护，防止并行 hook 冲突。

**Stop 拒绝推断**：Stop 时若 map 有 `:A` 项（从未被 PostToolUse 提升为 `:C`），推断为用户拒绝权限 → 状态 `-`；否则 → `✓`。这消除了对 Notification(denied) 事件的依赖（该事件不保证触发），也消除了 watcher 进程。

### Claude Code 特有

- **Hooks 完整性校验**：SessionStart 时 `_check_hooks_integrity()` 检测 10 个事件是否都注册了本插件的 hook，缺失则自动修复
- **Notification 事件细分**：idle_prompt / waiting for input → `-`；denied/cancelled → `-`（冗余清理路径，Stop 仍独立推断）
- **反向竞态保护**：PreToolUse 用 `_toolmap_set_pending_guarded` 写入，不会把已存在的 `A`/`C` 降级为 `P`
- **tool_use_id 缺失容错**：PreToolUse 无 id 时合成 `synthetic-*`；PostToolUse 无 id 时降级最早 PENDING
- **Fallback 清理**：TMUX_PANE 未解析时，Stop/SessionEnd 遍历所有 pane 清理残留活跃状态

## 状态符号

| 事件 | 状态 | 含义 |
|------|------|------|
| SessionStart | `-` | 会话空闲 |
| UserPromptSubmit / PreToolUse / PostToolUse | `>` | 处理中（map 有 PENDING 或过渡态） |
| PermissionRequest (AskUserQuestion) | `?` | 等待用户输入（ask 标志；优先级低于 `!`） |
| PermissionRequest (其他工具) | `!` | 等待授权（map 有 AWAITING_PERM） |
| Stop / StopFailure | `✓` 或 `-` | 无 `:A` 则 `✓`；有 `:A` 则推断拒绝 → `-` |
| SessionEnd | (空) | 会话结束 |

**聚合优先级**：`!` > `?` > `>` > 空。多个工具并发时，只要有一个 AWAITING_PERM 即显示 `!`。

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
# 块头格式: [时间] [claude] [EVENT] [pane]  'prev' → 'curr'  perm=Y/N ask=Y/N
# 示例:
#   [2026-04-24T11:31:35] [claude] [PermissionRequest] [tmux-claude-hooks-status:1.3]  '>' → '!'  perm=Y ask=N
#     tool: Bash  id=toolu_01KwepCiVxbU8eoBYBvwgCxi
#     input: {"command":"ls -la"}

# 模拟带 tool_use_id 的权限请求流程
echo '{"tool_use_id":"t1"}' | bash scripts/tmux-claude-status PreToolUse
echo '{"tool_use_id":"t1","tool_name":"Bash"}' | bash scripts/tmux-claude-status PermissionRequest
echo '{"tool_use_id":"t1"}' | bash scripts/tmux-claude-status PostToolUse

# 查看 tool_state map
cat /tmp/claude-*-toolmap
```

### 快捷键

| 快捷键 | 操作 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + r` | 重载 tmux 配置（含插件初始化） |

## 关键设计决策

- **共享库架构**：通过 `lib-tmux-ai-status.sh` 提供通用功能，`TOOL_ID` 区分状态变量和临时文件
- **Attached-only 显示**：`build_all_status()` 按 `session_last_attached` 降序、`window_index`/`pane_index` 升序排列，仅显示 attached session
- **进程树解析**：hook 子进程不继承 `$TMUX_PANE`，通过 `ps -o ppid` 向上遍历找到 pane PID
- **多行状态栏**：AI 状态占据独立 `status-format[N]` 行，不修改用户的 `status-right`
- **幂等初始化**：`prefix+r` 重载无副作用（检测已占行、hook 已存在则跳过）
- **Stale hook 清理**：安装时清理指向不存在脚本的旧 hook 和重复路径
- **`!` 和 `?` 对等原则**：两者本质相同——都需要人类审批。对 `!`（PermissionRequest）的任何逻辑变更（竞态保护、Stop 推断、清理路径）必须同步应用到 `?`（AskUserQuestion），反之亦然。差异仅限显示优先级（`!` > `?`）和符号本身

## 依赖

- tmux >= 3.1
- jq
- bash >= 4.0

## Hook 事件注册

**Claude Code**（10 个事件，注册到 `~/.claude/settings.json`）：
SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure

全部 async=true，PermissionRequest 例外（async=false 用于立即阻塞）。
