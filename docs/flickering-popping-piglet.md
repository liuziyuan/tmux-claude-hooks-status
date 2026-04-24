# 调查:`!` / `?` 状态下用户自定义输入后的 hook 触发行为

## Context

**问题**:当 tmux 状态栏处于 `!`(PermissionRequest,等待授权)或 `?`(AskUserQuestion,等待输入)状态时,用户若**不点选预设选项,而是输入自定义文本**(相当于拒绝当前 tool_use 并给出新指令),Claude Code 随即进入 thinking。怀疑此过渡**没有任何 hook 事件被触发**,导致:

- `toolmap` 中的 `:A` 项残留
- `perm_flag` / `ask_flag` 残留
- 状态栏持续显示 `!` 或 `?`,直到下一个 Stop / UserPromptSubmit / 60s 孤儿清理才消失,**视觉严重误导**

**静态代码分析确认两个清理缺口**(`scripts/tmux-claude-status`):

1. **`ask_flag` 永不被 PostToolUse 清理**(L102-115 只清 `perm_flag`,无 `_clear_ask_flag` 调用)
2. **Notification(denied) 故意不清 map/flag**(L63-64),依赖 Stop 兜底

**静态分析无法确定的关键事实**:
Claude Code 实际会不会为"permission/question 被自定义输入打断"这种过渡触发 hook?可能的三种行为:

| 假设 | 行为 | 当前代码表现 |
|---|---|---|
| A | 触发 PostToolUse(带 rejected tool_result) | `!` 正常清理;`?` 会残留(ask_flag 不清 bug) |
| B | 触发 UserPromptSubmit(反馈成为新 prompt) | `_clear_all_state` 全清 ✓ |
| C | 仅 UI 内部流转,无 hook | `!`/`?` 残留直到 Stop 或 60s 孤儿清理(**用户看到的现象**) |

→ 必须实证,否则修复方向不明。

## 关键文件

- `scripts/tmux-claude-status:48-184` — 事件分派主体
- `scripts/lib-tmux-ai-status.sh:107-215` — toolmap 操作
- `scripts/lib-tmux-ai-status.sh:217-247` — ask_flag / perm_flag
- `/tmp/tmux-ai-status.log` — 每个 hook 调用的 `_ai_log` 记录
- `/tmp/claude-*-toolmap`、`/tmp/claude-*-ask`、`/tmp/claude-*-perm` — per-pane 状态文件

## Phase 1:实证

### 准备

1. 清空日志,便于观察:

   ```bash
   : > /tmp/tmux-ai-status.log
   ```

2. 打开两个终端窗格。终端 A 里跑 Claude Code(保证 hook 生效),终端 B 里 `tail -f /tmp/tmux-ai-status.log`。

### 实验 1 — AskUserQuestion(`?` 状态)的自定义输入

在 Claude Code 里让它调用 AskUserQuestion(例如问它"你觉得我该用 A 还是 B?请询问我"),等状态栏变 `?` 后:

1. 不点 A 也不点 B,**用 Other 输入自定义回答**(或直接打字后回车)
2. 观察日志里从 `PermissionRequest` 到下一次 `UserPromptSubmit`/`Stop` 之间出现了哪些事件
3. 实时查看 toolmap/ask_flag 文件:
   ```bash
   ls -la /tmp/claude-*-ask /tmp/claude-*-toolmap 2>/dev/null
   cat /tmp/claude-*-toolmap 2>/dev/null
   ```
4. 观察状态栏 `?` 符号何时消失

**记录**:有无 PostToolUse?有无 UserPromptSubmit?ask_flag 何时被删?

### 实验 2 — 其他工具 PermissionRequest(`!` 状态)的 Deny-with-feedback

让 Claude Code 尝试跑一个需要授权的 Bash(例如 `rm` 某文件),等状态栏变 `!` 后:

1. 在授权对话框里选 **Deny** 并在反馈框输入自定义文本(例如"改用 mv 到 trash")
2. 同上观察日志里 `PermissionRequest` 与 `Stop` 之间的事件序列
3. 观察 toolmap(`:A` 是否被清或升级 `:C`)、perm_flag 何时消失、`!` 何时消失

**记录**:PostToolUse 有没有来?tool_use_id 匹配吗?UserPromptSubmit 先到还是后到?

### 实验 3(对照组)— 正常 Approve

同样流程,但选 Approve。用于对照确认 PostToolUse 一定触发,用来隔离"是否自定义输入才导致缺失"。

## Phase 2:根据实证结果决定修复方向

| 实证结果 | 修复动作 |
|---|---|
| 实验 1 触发 PostToolUse 但 `?` 残留 | 在 `tmux-claude-status:102-115` 加 `_clear_ask_flag`(可能需按 tool_name=AskUserQuestion 判断,避免误清其他并发 ? 状态) |
| 实验 2 触发 PostToolUse 或 UserPromptSubmit | 无需修复,现有清理路径已覆盖 |
| 任一实验无 hook 触发(假设 C) | 引入兜底机制。候选方案:(a) `!`/`?` 状态在 `_maybe_cleanup_stale` 里加本地 mtime 超时(例如 300s),独立于 pane 销毁判断;(b) PermissionRequest 写入时间戳,下次任意 hook 调用时若当前 `!`/`?` 状态但时间戳过旧则自动清理 |

**不预先写修复代码**。Phase 2 需要另起一轮对话(脱离 plan mode)才能实施。

## 验证(Phase 2 之后)

- **实验 1 回归**:触发 AskUserQuestion 自定义输入,观察 `?` 是否在 PostToolUse/UserPromptSubmit 到达时立即消失(不等 Stop)
- **实验 2 回归**:Deny-with-feedback 后 `!` 立即消失
- **回归旧场景**:
  - Approve 正常跑 Bash → `>` → `✓` ✓
  - AskUserQuestion 点选项(非自定义) → `?` → 消失 ✓
  - Stop 拒绝推断仍生效(map 有 `:A` 时 `-`,否则 `✓`)
- **命令速查**:
  ```bash
  tmux list-panes -a -F "#{pane_id} #{@claude_pane_status}"
  ls /tmp/claude-*-{toolmap,ask,perm} 2>/dev/null
  tail -f /tmp/tmux-ai-status.log
  ```
