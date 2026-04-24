# 功能手册：全生命周期状态流转

从用户操作视角，描述 Claude Code CLI 在 tmux 中从启动到退出的完整生命周期。
每个节点说明：用户做了什么 → 插件做了什么 → 状态符号如何变化。

---

## 状态符号速查

| 符号 | 含义 | 颜色 |
|------|------|------|
| `-` | 空闲 | 黄底 `#F1FA8C` |
| `>` | 处理中（Claude 正在工作） | 黄底 `#F1FA8C` |
| `!` | 等待权限授权 | 红底 `#FF5555` |
| `?` | 等待用户回答 AskUserQuestion | 红底 `#FF5555` |
| `✓` | 正常完成 | 黄底 `#F1FA8C` |
| (空) | 会话已结束 | — |

**聚合优先级**：`!` > `?` > `>` > 空。多个工具并发时，只要有一个等待授权就显示 `!`。

---

## 1. tmux 启动 / 插件加载

**用户操作**：启动 tmux 或执行 `prefix + r` 重载配置。

**触发**：TPM 加载 `tmux-claude-hooks-status.tmux`。

**处理流程**：

1. **配置 pane 边框**：开启 `pane-border-status`，所有 pane 顶部显示边框
2. **追加状态栏行**：扫描 `status-format[N]`，查找含 `@ai_all_status` 的行；若无则新增一行。**幂等**——重载不会重复追加
3. **注册重载保护**：覆盖 `prefix+r` 绑定，重载后自动重新执行本脚本（仅覆盖一次，由哨兵变量 `@claude_hooks_reload_registered` 控制）
4. **注册 Claude Code hooks**：调用 `install-claude-hooks.sh`，向 `~/.claude/settings.json` 写入 10 个事件的 hook（幂等）
5. **注册 tmux 生命周期 hook**：`session-closed`、`client-detached`、`client-attached` → 触发 `_refresh` 重建聚合状态
6. **绑定快捷键**：`prefix+C-h` 安装 hooks，`prefix+C-u` 卸载 hooks

**状态变化**：无（此时无 Claude 会话）。

---

## 2. 在 pane 中启动 Claude Code CLI

**用户操作**：在 tmux pane 中执行 `claude`。

**触发**：Claude Code 发出 `SessionStart` 事件 → hook 调用 `tmux-claude-status SessionStart`。

**输入数据**：`{ session_id, source, model }`

**处理流程**：

1. **解析 TMUX_PANE**：`resolve_tmux_pane()` 通过进程树（`ps -o ppid`）向上遍历，匹配 `tmux list-panes` 找到当前 pane ID。hook 子进程不继承 `$TMUX_PANE`，必须从进程树推断
2. **持久化 pane 映射**：写入 `/tmp/claude-status/${PANE_SANITIZED}/pane-${SESSION_ID}`，供 SessionEnd 回读
3. **清理旧状态**：`_clear_all_state()` 清除 tool_state map、ask flag、perm flag
4. **校验 hooks 完整性**：`_check_hooks_integrity()` 检查 `settings.json` 中 10 个事件是否都已注册。缺失则自动修复并提示
5. **孤儿清理**：`_maybe_cleanup_stale()` 检查其他 pane 是否有残留的活跃状态（60 秒节流）

**状态变化**：`@claude_pane_status` → `-`（空闲）

**日志示例**：
```
[2026-04-24T10:00:01] [claude] [SessionStart] [myproj:1.0]  '' → '-'  perm=N ask=N
  input: {"source":"cli","model":"claude-sonnet-4-6"}
```

---

## 3. 用户输入 prompt

**用户操作**：在 Claude Code 中输入自然语言 prompt 并提交。

**触发**：`UserPromptSubmit` 事件。

**输入数据**：`{ session_id }`

**处理流程**：

1. 清理上一轮所有状态：`_clear_all_state()` 清除 tool_state map、ask flag、perm flag
2. 状态切换为处理中

**状态变化**：`-` → `>`

**日志示例**：
```
[2026-04-24T10:00:05] [claude] [UserPromptSubmit] [myproj:1.0]  '-' → '>'  perm=N ask=N
```

---

## 4. Claude 调用工具（正常流程，无需权限）

**用户行为**：Claude 自动调用工具（如 Read、Grep 等）。

**事件链**：`PreToolUse` → `PostToolUse`

### 4a. PreToolUse

**输入数据**：`{ session_id, tool_name, tool_use_id, tool_input }`

**处理流程**：

1. 提取 `tool_use_id`；若缺失则合成 `synthetic-$(date +%s)-$RANDOM`
2. `_toolmap_set_pending_guarded(tool_use_id)`：写入 `P`（PENDING）。**guarded** ——若该 id 已是 `A` 或 `C` 则不覆盖（防止反向竞态：PreToolUse async 到达晚于 PermissionRequest）
3. `_compute_status()` 聚合计算

**tool_state map 变化**：新增条目 `toolu_xxx:P`

**状态变化**：保持 `>`（或从任何状态变为 `>`）

### 4b. PostToolUse / PostToolUseFailure

**输入数据**：`{ session_id, tool_name, tool_use_id }`

**处理流程**：

1. 若有 `tool_use_id` → `_toolmap_set(id, "C")` 标记完成
2. 若无 `tool_use_id` → `_toolmap_downgrade_oldest_pending()` 将最早的 `P` 或 `A` 降级为 `C`
3. 若 map 中已无 `A` 条目 → `_clear_perm_flag()`
4. 若工具是 `AskUserQuestion` → `_clear_ask_flag()`
5. `_compute_status()` 聚合

**tool_state map 变化**：`toolu_xxx:P` → `toolu_xxx:C`

**状态变化**：保持 `>`（PostToolUse 后仍显示 `>`，因为 Claude 可能继续调用下一个工具）

**日志示例**：
```
[2026-04-24T10:00:06] [claude] [PreToolUse] [myproj:1.0]  '>' → '>'  perm=N ask=N
  tool: Read  id=toolu_01Abc
  input: {"file_path":"/src/main.sh"}
[2026-04-24T10:00:07] [claude] [PostToolUse] [myproj:1.0]  '>' → '>'  perm=N ask=N
  tool: Read  id=toolu_01Abc
```

---

## 5. 工具需要权限授权

**用户行为**：Claude 调用需要权限的工具（如 Bash），用户在终端中批准或拒绝。

**事件链**：`PreToolUse` → `PermissionRequest` → (用户操作) → `PostToolUse` 或 `Stop`

### 5a. PreToolUse（同上）

写入 `toolu_xxx:P`，状态 `>`。

### 5b. PermissionRequest

**输入数据**：`{ session_id, tool_name, tool_use_id, tool_input }`

**处理流程**：

1. **非 AskUserQuestion**：
   - `_set_perm_flag()`：写入权限等待标志（防止后续 PreToolUse async 竞态覆盖）
   - 若有 `tool_use_id` → `_toolmap_set(id, "A")` 标记 AWAITING_PERM
   - 若无 `tool_use_id` → `_toolmap_upgrade_oldest_pending_to_awaiting()` 升级最早的 `P` 为 `A`
2. `_compute_status()` 聚合

**tool_state map 变化**：`toolu_xxx:P` → `toolu_xxx:A`

**状态变化**：`>` → `!`（红底，等待授权）

**日志示例**：
```
[2026-04-24T10:00:08] [claude] [PermissionRequest] [myproj:1.0]  '>' → '!'  perm=Y ask=N
  tool: Bash  id=toolu_01Def
  input: {"command":"rm -rf /tmp/test"}
```

### 5c. 用户批准 → PostToolUse

toolmap: `toolu_xxx:A` → `toolu_xxx:C`，`_clear_perm_flag()`

**状态变化**：`!` → `>`（回到处理中）

### 5d. 用户拒绝 → Stop

（见第 7 节）Stop 时检测 map 有 `:A` 条目 → 推断拒绝 → 状态 `-`

---

## 6. AskUserQuestion 场景

**用户行为**：Claude 通过 AskUserQuestion 工具向用户提问。

**事件链**：`PreToolUse` → `PermissionRequest(AskUserQuestion)` → (用户回答) → `PostToolUse`

### 6a. PermissionRequest（tool_name=AskUserQuestion）

**处理流程**：

1. `_set_ask_flag()`：写入独立的 ask 标志文件
2. **不写 tool_state map**（AskUserQuestion 使用独立的 ask 标志，不走 `:A` 路径）

**状态变化**：`>` → `?`（红底，等待用户回答）

### 6b. 用户回答 → PostToolUse

`_clear_ask_flag()`，map 中对应条目标记 `C`

**状态变化**：`?` → `>`

### 为什么 AskUserQuestion 用独立标志？

`_compute_status()` 优先级：`!`（perm flag + map awaiting）> `?`（ask flag）> `>`（map pending）。当同时有权限请求和提问时，权限请求优先显示 `!`。

---

## 7. Claude 完成响应（Stop / StopFailure）

**用户行为**：Claude 结束当前响应。

**触发**：`Stop` 或 `StopFailure` 事件。

**处理流程 — 拒绝推断**：

```
1. map 有 AWAITING_PERM (:A) ?  → 是 → STATUS="-"  （权限被拒绝）
                                  → 否 ↓
2. 当前状态已经是 "-" ?          → 是 → STATUS="-"  （前置 Notification 已置为拒绝）
                                  → 否 ↓
3. 当前状态是 "?" ?              → 是 → STATUS="-"  （AskUserQuestion 被取消）
                                  → 否 ↓
4. 正常完成                      → STATUS="✓"
```

然后 `_clear_all_state()` 清理所有状态文件。

**状态变化**：`>` → `✓`（正常完成）或 `>` → `-`（被拒绝/取消）

**Fallback**：若 `TMUX_PANE` 未解析，遍历所有 pane，将残留的 `>` 改为 `✓`，`!`/`?` 改为 `-`。

**日志示例**：
```
[2026-04-24T10:00:15] [claude] [Stop] [myproj:1.0]  '>' → '✓'  perm=N ask=N
```

---

## 8. Notification 事件

**用户行为**：无直接操作。Claude Code 在各种场景下发通知。

**触发**：`Notification` 事件。

**输入数据**：`{ notification_type, message }`

**处理逻辑**：

| 条件 | 状态 |
|------|------|
| `notification_type == "idle_prompt"` | `-`（空闲） |
| message 含 "waiting for your input" | `-`（空闲） |
| message 含 denied/cancelled/rejected | `-`（冗余拒绝清理路径，Stop 仍独立推断） |
| 其他 | 保持当前状态不变 |

Notification 不修改 tool_state map，仅改变显示状态。后续 Stop 事件会做最终清理。

---

## 9. 用户执行 `/new`

**用户行为**：在 Claude Code 中输入 `/new` 开始新会话。

**触发**：Claude Code 连续发出 `SessionEnd` + `SessionStart`，两个都是 async，存在竞态。

**处理流程**：

### SessionEnd（可能先执行或后执行）

1. 若 `TMUX_PANE` 为空 → `_load_pane_id()` 从持久化文件回读
2. `_clear_all_state()` + `_clear_pane_id()`
3. **竞态保护**：`_new_session_owns_pane()` 检查是否有新 session 的 `pane-${SESSION_ID}` 文件已接管此 pane
   - 有新 session → 状态设为 `-`（不覆盖，保留给新 session）
   - 无新 session → 状态设为 `""`（清空）

### SessionStart

正常初始化，写入新的 `pane-${SESSION_ID}`，状态 `-`。

**关键**：即使 SessionEnd 晚于 SessionStart 执行，`_new_session_owns_pane()` 也会检测到新 session 已存在，避免错误清空。

---

## 10. 用户执行 `/exit` 或 Ctrl+C 退出

**用户行为**：退出 Claude Code。

**触发**：`SessionEnd` 事件。

**输入数据**：`{ session_id, reason }`

**处理流程**：

1. 若 `TMUX_PANE` 为空 → `_load_pane_id()` 从文件回读 pane ID
2. `_clear_all_state()` 清理 toolmap、ask flag、perm flag
3. `_clear_pane_id()` 删除 pane 映射文件
4. `_new_session_owns_pane()` 检查（此时通常为 false——无新 session 接管）

**状态变化**：当前状态 → `""`（空，从状态栏消失）

**Fallback**：若 pane 仍未解析，遍历所有 pane 清除残留活跃状态。

**日志示例**：
```
[2026-04-24T10:05:00] [claude] [SessionEnd] [myproj:1.0]  '✓' → ''  perm=N ask=N
  input: {"reason":"user_exit"}
```

---

## 11. pane 被关闭 / 进程崩溃

**用户行为**：关闭 tmux pane（`exit` / `prefix+x`）或 Claude 进程崩溃（kill -9）。

**问题**：此时可能没有 hook 触发，pane 的 `@claude_pane_status` 可能残留 `>` 或 `!`。

**清理机制**：

### 11a. 频率限制的孤儿清理（`_maybe_cleanup_stale`）

每次任何 hook 事件触发时执行（60 秒节流）。扫描所有有活跃状态的 pane：

1. **无对应 pane 目录** → 孤儿，清除状态 + 删除目录
2. **pane 文件 >5 分钟且无 claude 进程** → 已死，清除状态 + 删除目录

进程检测用 BFS 遍历 pane 的进程树（最大深度 10），查找命令含 "claude" 的进程。

### 11b. tmux 生命周期 hook

`session-closed` 触发 `_refresh` → `_cleanup_stale_panes()` → 重建 `@ai_all_status`。

---

## 12. tmux session 关闭 / client detach / client attach

**用户行为**：`prefix+d`（detach）、关闭终端、重新 attach。

**触发**：tmux 内置 hook → `_refresh` 命令。

**处理流程**：

1. `_cleanup_stale_panes()`：清理孤儿状态
2. `build_all_status()`：扫描所有 attached session 的 pane，重建聚合状态
3. 更新 `@ai_all_status`

`build_all_status()` 只显示 **attached** session 的 pane，按 `session_last_attached` 降序排列（最近使用的 session 在前面）。

---

## 13. tmux 重载（prefix + r）

**用户行为**：按 `prefix+r` 重载 tmux 配置。

**触发**：插件覆盖的 key binding → `source-file ~/.tmux.conf` → `run-shell tmux-claude-hooks-status.tmux`。

**处理流程**：

重新执行初始化脚本，所有操作幂等：
- 状态栏行：检测已有 `@ai_all_status` 行则复用
- hooks 注册：检测已存在则跳过
- 重载保护：哨兵变量防止重复覆盖绑定

---

## tool_state map 生命周期总结

```
Per-pane 文件: /tmp/claude-status/${PANE_SANITIZED}/${SESSION_ID}-toolmap

写入时机:
  PreToolUse        →  toolu_xxx:P    (guarded, 不覆盖 A/C)
  PermissionRequest →  toolu_xxx:A    (覆盖 P)
  PostToolUse       →  toolu_xxx:C    (覆盖 P/A)

清理时机:
  UserPromptSubmit  →  全部清除
  Stop/StopFailure  →  全部清除
  SessionStart      →  全部清除
  SessionEnd        →  全部清除
```

---

## 状态流转图

```
SessionStart ──→ - (空闲)
                    │
UserPromptSubmit ──→ > (处理中)
                    │
          ┌─────────┼─────────┐
          ↓         ↓         ↓
    PreToolUse   AskUserQ   (正常完成)
          │         │         │
          ↓         ↓         ↓
   [map: P]    [ask flag]    │
          │         │         │
          ↓         ↓         │
  PermissionReq  PermissionReq│
   (其他工具)    (AskUserQ)  │
          │         │         │
          ↓         ↓         ↓
    [map: A]      [?状态]     │
          │         │         │
          ↓         ↓         ↓
   PostToolUse  PostToolUse  │
   [map: C]     [清除ask]    │
          │         │         │
          └─────────┼─────────┘
                    ↓
              Stop/StopFailure
                    │
        ┌───────────┼───────────┐
        ↓           ↓           ↓
   有 :A 残留    状态为 -/?    正常
   (被拒绝)     (被取消)      ↓
        ↓           ↓           ↓
        -           -           ✓
```

---

## 测试命令速查

```bash
# 模拟完整会话生命周期
echo '{}' | bash scripts/tmux-claude-status SessionStart      # → -
echo '{}' | bash scripts/tmux-claude-status UserPromptSubmit   # → >
echo '{"tool_use_id":"t1"}' | bash scripts/tmux-claude-status PreToolUse  # → >
echo '{"tool_use_id":"t1","tool_name":"Bash"}' | bash scripts/tmux-claude-status PermissionRequest  # → !
echo '{"tool_use_id":"t1"}' | bash scripts/tmux-claude-status PostToolUse  # → >
echo '{}' | bash scripts/tmux-claude-status Stop               # → ✓

# 模拟拒绝场景
echo '{"tool_use_id":"t2"}' | bash scripts/tmux-claude-status PreToolUse
echo '{"tool_use_id":"t2","tool_name":"Bash"}' | bash scripts/tmux-claude-status PermissionRequest
echo '{}' | bash scripts/tmux-claude-status Stop  # → - (有 :A 残留 = 被拒绝)

# 查看 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# 查看聚合状态
tmux show-option -g @ai_all_status

# 查看 toolmap
cat /tmp/claude-status/*/toolmap 2>/dev/null

# 查看日志
tail -f /tmp/tmux-ai-status.log
```
