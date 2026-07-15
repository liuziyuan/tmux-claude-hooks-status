# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 术语

**AI Status** — 本项目核心功能的统称。通过 tmux 状态栏实时显示 AI CLI（Claude Code / Codex）运行状态，包括状态检测、事件监听、符号渲染、颜色编码等整套机制。

## 当前开发状态

**Claude Code 支持已稳定。Codex CLI 支持已加入**（需 codex ≥ v0.144，hooks.json + hook trust）。

## 项目概述

tmux 插件，在 tmux 状态栏和窗格边框中显示 AI CLI（Claude Code / Codex）的运行状态。通过各工具的 hook 系统实时显示每个 pane 的状态（空闲、处理中、等待授权等），以独立状态行呈现。Claude Code 与 Codex 的 hook 语义同构（事件名、stdin JSON 字段一致），共用一套核心脚本，以 `TOOL_ID`（`claude`/`codex`）区分。

## 架构

### 文件结构

```
tmux-ai-hooks-status.tmux              # TPM 入口
scripts/
  lib-tmux-ai-status.sh                # 共享库：TMUX_PANE 解析、状态聚合、pane title 监控、日志
  tmux-ai-status                       # 事件处理器（参数化：<TOOL_ID> <EVENT>，claude/codex 共用）
  tmux-ai-esc                          # Esc 键拒绝检测（!/? → -）
  lib-install-hooks.sh                 # 安装公共骨架（依赖检查 + 原子写）
  adapters/
    claude.sh                          # Claude Code 差异声明 + 完整性检查 + install/uninstall
    codex.sh                           # Codex 差异声明 + install/uninstall（无SessionEnd/延迟SessionStart/trust）
  install-claude-hooks.sh              # 薄 wrapper → adapters/claude.sh
  install-codex-hooks.sh               # 薄 wrapper → adapters/codex.sh
```

### 工具适配器架构（adapters/）

**核心引擎工具无关（一份），工具个性抽成薄 adapter（每工具一个文件）。** 加新 CLI = 加一个 `adapters/<tool>.sh`，核心零改动。

`lib-tmux-ai-status.sh` 被 source 后调 `_load_adapter` 载入 `adapters/${TOOL_ID}.sh`。每个 adapter 声明契约：

- `ADAPTER_EVENTS` — 该工具触发的事件集合（claude 10 个 / codex 6 个）
- `ADAPTER_PROCESS_NAMES` — 进程名（basename），供 `_pane_has_ai_process` 前缀匹配（`codex` 匹配 `codex-aarch64-*`）
- `ADAPTER_HOOKS_FILE` — hooks 配置绝对路径
- `ADAPTER_HAS_SESSION_END` — 是否有 SessionEnd（codex 无 → 退出靠进程检测兜底）
- `ADAPTER_SESSION_START_TIMING` — `immediate`（claude）/`deferred`（codex 延迟到首个 turn）
- `ADAPTER_INSTALLER` — install 脚本路径（自修复/TUI 调用）
- `adapter_check_integrity()` — hooks 是否完整注册本插件（返回 0=完整）
- `adapter_install_hooks()` / `adapter_uninstall_hooks()` — 安装/卸载 hooks（合并式，保留他人 hook）

install 逻辑归并：公共骨架（依赖检查 `_install_require_jq` + 原子写 `_install_atomic_write`）在 `lib-install-hooks.sh`；工具特定的 jq 合并在各 adapter 的 install 函数；`install-<tool>-hooks.sh` 瘦成薄 wrapper（source 骨架 + adapter → dispatch）。加新 CLI 的 install 只需在其 adapter 加两个函数 + 5 行 wrapper。

核心引擎不再写 `case "$TOOL_ID"`：`_check_hooks_integrity` 委托 `adapter_check_integrity`；`_maybe_repair_hooks` 用 `ADAPTER_INSTALLER`；`_pane_has_ai_process`/`build_all_status` 用 `_collect_ai_process_names`（扫所有 `adapters/*.sh` 汇总进程名，聚合/清理路径认全部工具）。

### 共享库 `lib-tmux-ai-status.sh`

被 `tmux-ai-status` 通过 `source` 引入。调用方需设置 `TOOL_ID`（`"claude"`/`"codex"`）、`SESSION_ID`。source 后自动 `_load_adapter` 载入对应适配器。提供：

- **日志** `_ai_log()` — 写入 `/tmp/tmux-ai-status.log`，自动轮转（>100KB 截断至 50KB）
- **TMUX_PANE 解析** `resolve_tmux_pane()` — 通过进程树向上查找所属 pane
- **状态聚合** `build_all_status()` — 扫描 attached session 的所有 pane，读取 `@ai_pane_status`，写入 `@ai_all_status`
- **进程树检查** `_pane_has_ai_process()` — BFS 遍历 pane 进程树，匹配所有 adapter 汇总的进程名（前缀匹配）
- **Hooks 完整性** `_check_hooks_integrity()` / `_maybe_repair_hooks()` — 委托当前 adapter 的 `adapter_check_integrity` / `ADAPTER_INSTALLER`

### 数据流

```
AI CLI 事件（Claude Code / Codex）
    ↓
tmux-ai-status <TOOL_ID> <EVENT> 脚本
    ├─ source lib-tmux-ai-status.sh
    ├─ resolve_tmux_pane()（进程树遍历）
    ├─ case "$EVENT" → 维护 pending 集合 + 派生 STATUS 符号
    │   PreToolUse:        pending-pre += id
    │   PermissionRequest: 早写 !/? + pending-perm += "id !/?" (优先级最高)
    │   PostToolUse/Failure: pending-pre/perm -= id
    │   UserPromptSubmit/Stop/Session*: _clear_pending
    ├─ _derive_status_from_pending → STATUS
    ├─ 写入 per-pane 状态（@ai_pane_status）
    ├─ build_all_status() → @ai_all_status
    └─ tmux refresh-client

派生规则（per pane）:
    pending-perm 含 ! → STATUS=!
    含 ?              → STATUS=?
    pending-pre 非空  → STATUS=>
    都空              → 事件自决（>/✓/-/空）

tmux session/client 生命周期 hook
    (session-closed, client-detached, client-attached)
    ↓ _refresh → rebuild @ai_all_status

Esc 键拒绝检测（tmux bind-key -n Escape）:
    ├─ 全局拦截 Esc，读取 active pane 的 @ai_pane_status
    ├─ 状态为 ! / ? → 设为 -，rebuild，透传 Esc
    └─ 其余状态 → 直接透传 Esc（~15ms 开销）
```

### Pending 集合机制

per-pane 持久化两个集合（文件落在 `${_STATUS_DIR}/${PANE_SANITIZED}/`）：

- `pending-pre`：已 PreToolUse 未 PostToolUse 的 `tool_use_id`
- `pending-perm`：已 PermissionRequest 未配对的 `tool_use_id`（含 `!`/`?` 标记）
- `.lock/`：mkdir mutex（5s stale 强夺）保护并发写

**铁律**：只要 `pending-perm` 非空，STATUS 必为 `!`/`?`，不受 PreToolUse/PostToolUse 乱序到达影响。

**Stop 拒绝推断**：Stop 时检查 `pending-perm` 文件是否非空 → `-`；否则按 `$PREV_STATUS` 推断 → `✓`。

### Claude Code 特有

- **Hooks 完整性校验**：SessionStart 时 `_check_hooks_integrity()` 检测 10 个事件是否都注册了本插件的 hook，缺失则自动修复
- **Hooks 合并式安装**：`install-claude-hooks.sh` 仅清理 stale tmux-ai-status 条目并追加本插件命令，保留其他工具（masko-desktop 等）注册的 hook
- **Notification 事件细分**：idle_prompt / waiting for input → `-`；denied/cancelled → `-`
- **竞态最终保护**：PreToolUse/PostToolUse 写入前 re-derive，若 `pending-perm` 已落盘则改写为 `!`/`?`，永不覆盖审批态
- **Fallback 清理**：TMUX_PANE 未解析时，Stop/SessionEnd 遍历所有 pane 清理残留活跃状态

### ⚠️ 已知限制 / 备忘

**PermissionRequest hook JSON 不携带 `tool_use_id`**（截至 2026-05）。
当前实现 `_add_pending_perm` 因 id 为空直接 return，**`pending-perm` 文件实际从未写入数据**。
状态机仍能正确显示 `!`/`?` 是因为：
1. PermissionRequest 早写 tmux option 立刻生效
2. Claude Code 当前 serial 执行工具调用，单次循环内不存在 PermReq 之间的真并发
3. PostToolUse 配对清空 pending-pre → 派生 `>` 覆盖早写的 `!`

**未来若 Claude Code 改为 parallel 工具调用**，pending-perm 守门机制失效 → 乱序时 `!` 会被 `>` 覆盖。
届时需重新设计：等 Claude Code 在 PermReq input 中补 `tool_use_id` 字段（最可能），或用 `tool_name + tool_input` 哈希作 surrogate id。
**触发条件**：日志中观察到 `[PermissionRequest] '>' → '!'` 与 `[PostToolUse] '!' → '>'` 之间夹有其他工具的 `[PreToolUse]` 事件即说明并发已开始。

---

**点 No 拒绝时状态卡 `!`（不会自动转 `-`）**

用户在 Claude Code TUI 中选择 No 拒绝权限时，Claude Code 完全静默：
- 不发 Notification（无 `denied`/`rejected` 消息）
- 不发 PostToolUseFailure
- 不发 Stop
- 后续 batch 中尚未发起的工具也不再发 PreToolUse

本插件因此无任何 signal 可监听，状态保持 `!` 直到下次 `UserPromptSubmit`（用户输入新提示）。

ESC 拒绝能转 `-` 是因为 tmux 端 `bind-key -n Escape` 拦截了键流；No 是 TUI 选项选择，不经过 tmux 键事件，无法捕获。

**已知此行为，不实现自动恢复**。`!` 语义仍准确（等待人类下一步动作），下次输入自然清。若 Claude Code 未来为 No 操作补 hook 事件（如 PostToolUseFailure），届时再启用 Notification/PTUF handler 兜底。

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
prefix + M-h    # 安装 Codex hooks（需 codex ≥ v0.144，首次启动 TUI 需 Trust all）
prefix + r      # 重载（自动触发初始化）
```

（注：TPM 按 repo 目录名加载并 source 目录下所有 `*.tmux`，入口文件已改名 `tmux-ai-hooks-status.tmux`，无需改软链目标。）

### 测试命令

```bash
# 手动触发事件（<TOOL_ID> <EVENT>）
echo '{}' | bash scripts/tmux-ai-status claude SessionStart
echo '{}' | bash scripts/tmux-ai-status codex SessionStart
tmux show-option -g @ai_all_status

# 查看 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@ai_pane_status}"

# 查看 Claude hooks 注册
jq '.hooks | keys' ~/.claude/settings.json
# 查看 Codex hooks 注册
cat ~/.codex/hooks.json

# 查看日志（每次 hook 事件 = 一个多行块：头行含状态转移，缩进行含 tool/input 摘要）
tail -f /tmp/tmux-ai-status.log
# 块头格式: [时间] [TOOL_ID] [EVENT] [pane]  'prev' → 'curr'
# 示例:
#   [2026-04-30T12:00:00] [codex] [PermissionRequest] [session:1.3]  '>' → '!'
#     tool: shell  id=
#     input: {"command":"ls -la"}

# 模拟权限请求流程
echo '{"tool_use_id":"t1"}' | bash scripts/tmux-ai-status codex PreToolUse
echo '{"tool_use_id":"t1","tool_name":"shell"}' | bash scripts/tmux-ai-status codex PermissionRequest

# 模拟拒绝流程
echo '{}' | bash scripts/tmux-ai-status codex Stop

# 查看 poll 进程
ls /tmp/ai-status/*/*-poll-pid
```

### 快捷键

| 快捷键 | 操作 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + M-h` | 安装 Codex hooks |
| `prefix + M-u` | 卸载 Codex hooks |
| `prefix + I` | 打开交互式 TUI 安装器（环境检查/侦测CLI/装卸修hooks/软链校验） |
| `prefix + r` | 重载 tmux 配置（含插件初始化） |

### Node TUI 安装器（installer/）

交互式安装器（@clack/prompts + execa），承接所有安装前置环节：环境侦测（tmux/jq/bash/node）、依赖 brew 代装、AI CLI 侦测（版本+minVersion+hooks状态）、hooks 装/卸/修、TPM 软链校验/创建。

不重实现 bash 逻辑——hooks 装/卸经 execa 调薄 wrapper `install-<tool>-hooks.sh`。工具元数据在 `installer/src/adapters-meta.js`，与 bash adapter 一一对应。运行：`cd installer && npm install && node bin/cli.js`，或 `prefix + I`。详见 `installer/README.md`。

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

全部 async=true，PermissionRequest 例外（async=false 用于立即阻塞）。命令格式：`<abs>/scripts/tmux-ai-status claude <Event>`。

**Codex CLI**（6 个事件，注册到 `~/.codex/hooks.json`，需 codex ≥ v0.144）：
SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop

命令格式：`<abs>/scripts/tmux-ai-status codex <Event>`。**全部同步**（0.144 静默跳过 `async=true` 的 hook，故不能用 async）。

### Codex 与 Claude 的差异（备忘）

- Codex **无** `SessionEnd / Notification / PostToolUseFailure / StopFailure` 事件。Codex 的 `Stop` 是「turn 完成」而非 session 结束；session 真正退出时无任何 hook。→ pane 状态清理只能靠 `_cleanup_stale_panes` 的进程树检测（codex 进程消失即清）。
- **Codex 0.144 hook 系统重写（相对旧 0.117 的三处 breaking change）**：
  1. **不再读取独立 `hooks.toml`** —— 仅认 `config.toml` 的 `[hooks]` 表，或 config 文件夹里的 `hooks.json`。本插件改用 `~/.codex/hooks.json`。
  2. **`async=true` 的 hook 被静默跳过**（源码 `if r#async { skip "async hooks are not supported yet" }`）—— 故本插件所有 codex hook 均同步（无 async 字段，默认 false）。
  3. **Hook trust 门禁** —— user 来源的 hook 需 `hooks.state.<key>.trusted_hash` 匹配 codex 计算的归一化 TOML 指纹才运行。该 hash 无法在 bash 里可靠复现，故 `install-codex-hooks.sh` **不预写 trusted_hash**；用户下次启动 codex TUI 会弹「Hooks need review → Trust all and continue」授信一次即永久生效（或以 `codex --dangerously-bypass-hook-trust` 启动跳过）。
- Codex hooks 配置在 `~/.codex/hooks.json`（JSON），结构 `{"hooks":{"<Event>":[{"hooks":[{"type":"command","command":...,"timeout":5}]}]}}`。`install-codex-hooks.sh` 用 jq 读改写：仅剔除/替换 command 含 `tmux-ai-status` 的 group，保留用户/其他工具自有 hook（依赖 jq）。
- Codex 与 Claude 的 stdin JSON 字段同构（`session_id`/`tool_name`/`tool_use_id`/`tool_input`/`hook_event_name`）；`PermissionRequest` 均不带 `tool_use_id`，现有兜底逻辑通用。
- Codex hooks 同步执行，脚本正常退出 0 且 stdout 为空即视为 no-op 透传——本插件只读状态、不写 stdout，天然安全。
