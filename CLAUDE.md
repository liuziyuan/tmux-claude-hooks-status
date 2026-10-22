# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 工作流铁律

**所有改动(代码与文档一律)必须走 PR,禁止直接 push main。** 流程:从最新 `origin/main` 开分支 → 提交 → push → `gh pr create` → 合并。直接 push main 等同流程违规(2026-10-17 教训:两个提交直接落了 main,已 revert 后补走 PR)。

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
  tmux-ai-monitor                      # tmux server 级 Codex 生命周期监控（启动补 -、/exit 清空）
  tmux-ai-esc                          # Esc 键拒绝检测（!/? → -）
  lib-install-hooks.sh                 # 安装公共骨架（依赖检查 + 原子写 + 卸载意图标记 helper）
  adapters/
    claude.sh                          # Claude Code 差异声明 + 完整性检查 + install/uninstall
    codex.sh                           # Codex 差异声明 + install/uninstall（无SessionEnd/延迟SessionStart/trust）
    opencode.sh                        # opencode 差异声明 + plugin 文件生成/删除（整文件写、无 jq）
  install-claude-hooks.sh              # 薄 wrapper → adapters/claude.sh（[install|uninstall|check [--json]|auto]）
  install-codex-hooks.sh               # 薄 wrapper → adapters/codex.sh（[install|uninstall|check]）
  install-opencode-hooks.sh            # 薄 wrapper → adapters/opencode.sh（[install|uninstall|check]）
```

### 工具适配器架构（adapters/）

**核心引擎工具无关（一份），工具个性抽成薄 adapter（每工具一个文件）。** 加新 CLI = 加一个 `adapters/<tool>.sh`，核心零改动。

`lib-tmux-ai-status.sh` 被 source 后调 `_load_adapter` 载入 `adapters/${TOOL_ID}.sh`。每个 adapter 声明契约：

- `ADAPTER_EVENTS` — 该工具触发的事件集合（claude 10 个 / codex 6 个）
- `ADAPTER_PROCESS_NAMES` — 进程名（basename），供 `_pane_has_ai_process` 前缀匹配（`codex` 匹配 `codex-aarch64-*`）
- `ADAPTER_HOOKS_FILE` — hooks 配置绝对路径
- `ADAPTER_HAS_SESSION_END` — 是否有 SessionEnd（codex 无 → 退出由 `tmux-ai-monitor` 检测进程消失）
- `ADAPTER_SESSION_START_TIMING` — `immediate`（claude）/`deferred`（codex 延迟到首个 turn）
- `ADAPTER_INSTALLER` — install 脚本路径（自修复/TUI 调用）
- `adapter_check_integrity()` — hooks 是否完整注册本插件（返回 0=完整）
- `adapter_check_detail()` — `check --json` 明细 JSON 片段（可选实现；仅 install wrapper 的 check --json 上下文调用，失败输出降级片段不报错；不得依赖 lib-install-hooks.sh——status/suppress/drift 由 wrapper 层 `_wrapper_check_json` 拼装）。codex 额外输出 `trust` 维度：`{configFile, trusted:true|false|null, missingEvents, instances[]}`，只判各实例 `config.toml` 的 `[hooks.state."<hooks路径>:<下划线事件>:<组>:<hook>"]` 键是否存在（不重算 trusted_hash），汇总 `$HOME/.codex` 与所有 cc-switch 实例；`trusted:null` = config.toml 不存在
- `adapter_pane_hints()` — 可选：`TMUX_PANE` 无法由祖先链确定时，输出可能所属的 pane id（每行一个）。只读、不调用 tmux（复用核心 `_PANE_SNAPSHOT`），结果与进程树候选取交集；codex 用 `session_index.jsonl` 的 `thread_name` 匹配 pane title
- `adapter_install_hooks()` / `adapter_uninstall_hooks()` — 安装/卸载 hooks（合并式，保留他人 hook）

install 逻辑归并：公共骨架（依赖检查 `_install_require_jq` + 原子写 `_install_atomic_write`）在 `lib-install-hooks.sh`；工具特定的 jq 合并在各 adapter 的 install 函数；`install-<tool>-hooks.sh` 瘦成薄 wrapper（source 骨架 + adapter → dispatch，另含 `check` 模式输出 `ok`/`missing` 供 TUI 侦测）。加新 CLI 的 install 只需在其 adapter 加两个函数 + 5 行 wrapper。

核心引擎不再写 `case "$TOOL_ID"`：`_check_hooks_integrity` 委托 `adapter_check_integrity`；`_maybe_repair_hooks` 用 `ADAPTER_INSTALLER`（当前工具），`_maybe_repair_other_tools` 按 installed 标记跨工具调 wrapper；`_pane_has_ai_process`/`build_all_status` 用 `_collect_ai_process_names`（扫所有 `adapters/*.sh` 汇总进程名，聚合/清理路径认全部工具）。

### cc-switch 通用配置真源（claude adapter）

用户经 cc-switch（GUI + `switch` 命令）管理多供应商配置时，claude 的 hooks 持久真源随 cc-switch 版本变化（判定规则与 cc-switch CLI `detectSharedConfigMode` 一致，`CC_SWITCH_SHARED_SOURCE=live|legacy` 可显式覆盖）：

- **live（cc-switch 4.0.2+，db `PRAGMA user_version >= 20`）**：真源是 `~/.claude/settings.json`（cc-switch 把共享配置的「用户键」投影给实例，`hooks` 在投影范围内）。4.0.2 起 cc-switch 不再读库里的 `common_config_claude`，该键仅作迁移快照——**新机器上写库等于写进死信**（2026-10-19 根因：旧版检测只看 db 存在，导致安装报成功但 hooks 从不进入 settings）。
- **legacy（旧版，`user_version < 20` 或读不到）**：真源是 `~/.cc-switch/cc-switch.db`（SQLite）`settings` 表的 `common_config_claude`，`switch` 启动时深合并进实例 `settings.json`（provider `meta.commonConfigEnabled: true`）。

claude adapter 的模式与行为：

- **模式判定 `_ccswitch_mode`**：db 存在 && `sqlite3` 可用 && `settings` 表可查 → 按 `PRAGMA user_version` 返回 `live`/`legacy`；任一门禁不过（含 sqlite3 缺失）→ `none`，整体回退文件模式。不要求 key 存在（legacy 由 upsert 建行）
- **legacy 模式**：install/uninstall/integrity 只操作通用配置——复用与文件模式相同的 jq 合并/剥离/计数核心（`_CLAUDE_JQ_MERGE/_STRIP/_COUNT`），写入用与 cc-launch 同款 `json_patch` upsert（RFC 7396，只动 `hooks` 键，他人 hook 与顶层其他字段保留）
- **live 模式**：写入目标是 `$HOME/.claude/settings.json`（cc-switch 硬编码该路径，**不随 `CLAUDE_CONFIG_DIR` 变**——后者指向 `switch` 实例目录），复用文件模式的原子写与合并逻辑；实例 settings 在下次 `switch`/漂移收敛时从 live 真源重新派生
- **两种 cc-switch 模式**写入前都做 GUI 运行中 stderr 警告（其内存缓存可能在退出时全量回写覆盖真源，实测发生过；tmux 活跃时 60s 自修复会重写）
- **文件模式**：非 cc-switch 用户，行为与历史版本逐字节一致
- TUI 侧 `adapters-meta.js` 声明 `checkViaWrapper` + `ccSwitchDb`，`detect.js` 在 db 存在时改走 wrapper `check`（bash 内按 user_version 选真源），避免 JS 文件计数误报；`check --json` 的 mode 为 `ccswitch-live` / `ccswitch`

### cc-switch 下 codex / opencode 的真源（与 claude 对照）

| 工具 | cc-switch 4.0 的 hooks 真源 | 本插件行为 | 旧版兼容 |
|---|---|---|---|
| claude | live：`~/.claude/settings.json`；legacy：db `common_config_claude` | `_ccswitch_mode` 自动选择（见上节） | legacy 写库逐字节不变 |
| codex | `~/.codex/hooks.json`；`switch` 为每个 provider 建独立 `CODEX_HOME`，并把该文件**符号链接**进实例 | 写 `$CODEX_HOME/hooks.json`（默认 `~/.codex/hooks.json`），所有实例共享同一真源 | 写法不变；**per-instance hook 信任**见「已知限制」 |
| opencode | `<配置目录>/plugins/`；cc-switch 对 opencode 是 additive live config（provider 条目直接写进配置目录的 `opencode.json(c)`，**无 per-provider 实例目录**） | 配置目录 = `OPENCODE_CONFIG_DIR` 环境变量 > cc-switch `settings.json` 的 `opencodeConfigDir` > `${XDG_CONFIG_HOME:-~/.config}/opencode`（`_opencode_config_dir`） | 旧版无 `opencodeConfigDir` 键 → 自动回落默认目录 |

opencode 的 plugin 文件与 cc-switch 写入的 provider 条目同目录但不同文件，互不覆盖；cc-switch 重写 `opencode.json` 时只管理自己的 provider 键与已知 npm plugin 前缀。

### 共享库 `lib-tmux-ai-status.sh`

被 `tmux-ai-status` 通过 `source` 引入。调用方需设置 `TOOL_ID`（`"claude"`/`"codex"`）、`SESSION_ID`。source 后自动 `_load_adapter` 载入对应适配器。提供：

- **日志** `_ai_log()` — 写入 `/tmp/tmux-ai-status.log`，自动轮转（>100KB 截断至 50KB）
- **TMUX_PANE 解析** `resolve_tmux_pane()` — 先看祖先链（hook 进程向上能否命中 pane_pid，权威）；祖先链不通 = daemon/脱离上下文，**继承的 TMUX_PANE 一律丢弃**（它可能指向当前 server 中真实存在但无关的 pane），再按 `pane-${SESSION_ID}` 映射 → 同工具进程树候选 → `adapter_pane_hints` → hook cwd 逐级收敛；唯一才采用，多候选不猜（保留 monitor 的 idle `-`）。失败 5s 负缓存避免高频 BFS
- **状态聚合** `build_all_status()` — 扫描 attached session 的所有 pane，读取 `@ai_pane_status`，写入 `@ai_all_status`。无显式状态时补 idle `-`：前台命令是 AI 进程，或该 pane 的 `@ai_monitor_seen_<tool>` 为 1（monitor 进程树探测，覆盖 `switch`/launcher 启动场景）
- **cc-switch provider 段（仅 codex）** — cc-switch（`switch` 命令）launch 时向 CLI 注入 `CC_SWITCH_PROVIDER`/`CC_SWITCH_PROVIDER_ID` 环境变量，CLI hooks 进程继承；**仅 `TOOL_ID=codex` 的事件捕获**并写入 pane option `@ai_provider`/`@ai_provider_id`——claude 的 provider 标签由 wrapper 在 CLI 内 statusline 显示，tmux 状态栏刻意不重复渲染，claude/opencode 的事件一律走清理分支（`set-option -u` × 2，顺带清同 pane 之前的残留），codex 无 env（非 switch 启动）同样清理。聚合行在状态符号后渲染彩色 `[provider]` 段。颜色真源 `~/.cc-switch/statusline-preferences.json`（claude/codex 桶按 providerId 合并查，显式 SGI 码映射 tmux colourN），缺省 auto = FNV-1a(name) 落在与 cc-switch wrapper 相同的 6 色 bright 调色板（64 位精确积 `& 0xFFFFFFFF` 复刻 JS `Math.imul` 的 32 位截断乘）。**非 switch 场景零存在感契约**：provider 能力本质是 switch 的需求，本插件只是承载方——无 env 时只做幂等清理，不产生任何输出（stdout 恒空满足 codex hook 契约）、不改变退出码（恒 0）、不渲染任何 provider 内容；该场景实测 exit 0 + stdout/stderr 0 字节。
  - **⚠️ 迁移备忘（2026-10-17）**：本段是过渡方案——Codex TUI 内无法显示 provider（原生 status_line 无外部命令渲染，openai/codex#17827）。**当该上游能力落地时，整体移除本段功能**：删掉 `tmux-ai-status` 入口的 env 捕获/清理块、`build_all_status` 的 provider 渲染、`_provider_prefs_lines`/`_provider_tag_colour` 与 list-panes format 中的 `#{@ai_provider}|#{@ai_provider_id}` 字段，由 cc-switch 直接在 Codex TUI 内注入标签（cc-switch-parallel 仓库 CLAUDE.md 有对应迁移条目）。迁移前保持现状。
- **进程树检查** `_pane_has_ai_process()` — BFS 遍历 pane 进程树，匹配所有 adapter 汇总的进程名（前缀匹配）
- **Hooks 完整性** `_check_hooks_integrity()` / `_maybe_repair_hooks()` — 委托当前 adapter 的 `adapter_check_integrity` / `ADAPTER_INSTALLER`；`_maybe_repair_other_tools()` 在 `_run_refresh` 中遍历其余 adapter，仅对 `installed-<tool>` 已登记者 check/install（子进程调 wrapper，不 source adapter 以免 TOOL_ID 污染）

### 数据流

```
AI CLI 事件（Claude Code / Codex）
    ↓
tmux-ai-status <TOOL_ID> <EVENT> 脚本
    ├─ 从 stdin JSON 提取 session_id + cwd（cwd 供 pane 消歧）
    ├─ source lib-tmux-ai-status.sh
    ├─ resolve_tmux_pane()（祖先链 → session 映射 → 同工具进程树 →
    │   adapter 提示 → cwd；只有唯一候选才采用）
    │   _refresh / _session-switched 伪事件跳过解析（只重建聚合）
    │   解析失败：不写任何 per-pane 状态，日志记录 PANE: unresolved
    ├─ case "$EVENT" → 维护 pending 集合 + 派生 STATUS 符号
    │   PreToolUse:        pending-pre += id
    │   PermissionRequest: 早写 !/? + pending-perm += "id !/?" (优先级最高)
    │   PermissionResolved: pending-perm -= request_id（OpenCode）
    │   PostToolUse/Failure: pending-pre/perm -= tool_use_id
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
    session-closed / client-detached / pane-exited / after-kill-pane / pane-focus-in
    ↓ _refresh → rebuild @ai_all_status
    client-session-changed → _session-switched（per-client prev 对比滤自指后
    写 @ai_entered_time 进入时间）+ rebuild

Codex 生命周期 monitor（每秒）
    ├─ 每 60 tick 对比脚本目录内容指纹；变化 → 同 PID exec 自重启（升级自愈）
    ├─ pane_current_command=codex* 且无显式状态 → rebuild 时补 `-`
    ├─ launcher（switch/volta-shim/node…）启动时前台命令不是 codex：
    │   每 tick 批量探测进程树（一次 ps 快照 + 一次 awk），命中则写 @ai_monitor_seen_codex=1；
    │   build_all_status 据此给无显式状态的 pane 补 `-`（cc-switch 场景）
    ├─ `/exit` 后确认进程树无 Codex → 清 @ai_pane_status + marker
    └─ `/new` 进程仍在 → 不改写已有 `✓`

Esc 键拒绝检测（tmux bind-key -n Escape）:
    ├─ 全局拦截 Esc，读取 active pane 的 @ai_pane_status
    ├─ 状态为 ! / ? → 设为 -，rebuild，透传 Esc
    └─ 其余状态 → 直接透传 Esc（~15ms 开销）
```

### Pending 集合机制

per-pane 持久化两个集合 + 一个完成态 tombstone（文件落在 `${_STATUS_DIR}/${PANE_SANITIZED}/`）：

- `pending-pre`：已 PreToolUse 未 PostToolUse 的 `tool_use_id`（行 `id tool ts`）
- `pending-perm`：已 PermissionRequest 未配对的 `tool_use_id`（含 `!`/`?` 标记；行 `id mark tool ts`）
- `recent-post`：PostToolUse/PostToolUseFailure 已处理的 `tool_use_id`（行 `id ts`）。60s 窗口内命中则迟到的 Pre 跳过写入（`_pending_pre_skipped`），状态保持已完成——修复 Post 先于 Pre 到达导致 `pending-pre` 永久残留、状态卡 `>`；300s 修剪，`_clear_pending` 刻意不清（turn/session 边界迟到的 Pre 仍需拦截）
- `.lock/`：mkdir mutex（5s stale 强夺）保护并发写

**铁律**：只要 `pending-perm` 非空，STATUS 必为 `!`/`?`，不受 PreToolUse/PostToolUse 乱序到达影响。

**Stop 拒绝推断**：Stop 时检查 `pending-perm` 文件是否非空 → `-`；否则按 `$PREV_STATUS` 推断 → `✓`。

### Claude Code 特有

- **Hooks 完整性校验**：SessionStart 时 `_check_hooks_integrity()` 检测 10 个事件是否都注册了本插件的 hook，缺失则自动修复
- **SessionStart `source` 五值**（官方，2026-10 核实）：`startup`（新会话）/ `resume`（--resume 等）/ `clear`（/clear）/ `compact`（压缩后）/ `fork`（--fork-session 等）——每次 resume/clear/fork 都会重新触发 SessionStart（含其 integrity 校验路径）
- **Stop 触发语义**：Claude 完成响应即触发（"not only at task completion"）；**用户 interrupt 不触发**
- **Hooks 合并式安装**：`install-claude-hooks.sh` 仅清理 stale tmux-ai-status 条目并追加本插件命令，保留其他工具（masko-desktop 等）注册的 hook
- **Notification 事件细分**：idle_prompt / waiting for input 走「隐式路径」——**不无条件写 `-`**（`_notification_implicit_status`）：pending 派生（工具在跑）> live 审批态 `!`/`?` > `-`；denied/cancelled 是「显式重置」，无条件 `-`
  - `idle_prompt`：Claude 完成响应约 60 秒且用户未输入时触发；`permission_prompt`：权限提示**已等待约 6 秒**后才触发（官方 "the prompt has waited about six seconds"，每次按键会推迟计时器）——它到达时 `!` 已经由 sync PermissionRequest 写好，handler 走 PREV 保持分支（安全）
  - 官方明确指引："To run a hook immediately when Claude asks for permission to use a tool, use PermissionRequest instead."——佐证 PermissionRequest 必须保持 sync 的设计
  - `denied/cancelled` 文案匹配是防御性死分支：2026-10 实测（claude 2.1.304）Notification 只有 `idle_prompt`/`permission_prompt` 两类，匹配从未命中（与「点 No 完全静默」记载一致），保留作上游行为变化的哨兵
- **竞态最终保护**：PreToolUse/PostToolUse/PermissionResolved 写入前 re-derive，若 `pending-perm` 已落盘则改写为 `!`/`?`，永不覆盖审批态。**PreToolUse 的覆写权仅限 `pending-perm` 派生的 `!`/`?`**：pending-pre 派生的 `>` 不得推翻 live 的 `!`/`?`（claude 无 `tool_use_id`，审批态只存在于 live；async 乱序下 AskUserQuestion/普通工具的 PreToolUse 晚于 PermissionRequest 到达时，其 pending-pre 项会长期遮挡审批态——AskUserQuestion 要等用户答完才有 PostToolUse。2026-10-22 修复）
- **Fallback 清理**：TMUX_PANE 未解析时，Stop/SessionEnd 遍历所有 pane 清理残留活跃状态

### ⚠️ 已知限制 / 备忘

**cc-switch GUI 运行中写库会被内存缓存覆盖**

cc-switch GUI 会把内存中的通用配置在其某些操作（含退出）时全量写回 `cc-switch.db`（实测发生过：install 写入的 hooks 被旧缓存冲掉）。缓解：claude adapter 写库前 `pgrep` 检测 GUI 并 stderr 警告；tmux 会话活跃时 `_maybe_repair_hooks`（60s 节流）会自动重写。最稳妥流程：先退出 cc-switch GUI → install → 再启动 GUI。

**GUI 回写可复活已卸载条目（卸载方向无自动对抗）**

用户显式卸载（suppressed 标记写入）后，GUI 旧内存缓存回写 db 会把本插件条目带回真源。标记只挡自动修复路径，不做「负向修复」主动剥条目——与外部应用对拉风险大于收益。表现为 check 又变 ok（「已装」）。缓解：uninstall 前有 `_ccswitch_warn_gui` 警告；用户退出 GUI 后重跑 uninstall 即可。

**非 `switch` 启动的裸 claude 无状态（仅 legacy 模式）**

legacy（cc-switch < 4.0.2）模式下 hooks 真源在 db 通用配置，只有经 `switch` 启动（`CLAUDE_CONFIG_DIR` 指向实例）的 claude 会读到；用户直接跑 `claude`（读 `~/.claude/settings.json`）时本插件 hooks 不生效，该 pane 无状态。接受为此场景的已知限制（主路径是 `switch`）。**live（4.0.2+）模式不存在该限制**：真源本身就是 `~/.claude/settings.json`，裸跑与 `switch` 启动都生效。

**决策（2026-10-13）**：评估过「db + 原生 settings.json 双写」方案，不做——针对 legacy 模式，双写唯一收益是覆盖裸跑场景，用户确认几乎不裸跑；代价是原生写入永久处于「被 cc-switch 覆盖 → 60s 自修复重写」的拉锯（CLAUDE.md 前文实测：原生文件会被 cc-switch 覆盖）。live 模式无需双写：原生文件即真源。若 legacy 使用模式变化再重新评估。

**live 模式 + 自定义 `CLAUDE_CONFIG_DIR` 的错配（2026-10-20，诊断告警）**

live 模式真源固定为 `$HOME/.claude/settings.json`（cc-switch 硬编码，不随 `CLAUDE_CONFIG_DIR` 变）。若 db 残留（仍判 live）而用户以**自定义** `CLAUDE_CONFIG_DIR` 裸跑 claude，该进程读的是自定义目录，插件写入的真源不生效——check 恒「已装」、自修复永不触发。`adapter_install_hooks` 的 live 分支检测到 `CLAUDE_CONFIG_DIR` 非 `~/.cc-switch/instances/claude/` 前缀时 stderr 告警。**不做双写**（理由同 2026-10-13 决策）。

**codex 每个新 provider 实例需重新 Trust all（2026-10-19 实测）**

cc-switch 为每个 codex provider 创建独立 `CODEX_HOME`（`~/.cc-switch/instances/codex/<providerId>`），`hooks.json` 是符号链接（共享我们的安装），但 codex 的 hook 授信记录 `[hooks.state].trusted_hash` 写在**实例自己的 `config.toml`** 里。cc-switch 把 `hooks.state` 视为运行时状态、排除在共享配置之外，也不会复制到新实例 → 新 provider 首次启动时 codex 弹「Hooks need review」，未选 **Trust all** 则 hooks 全部不执行，状态栏收不到任何事件（pane 可能只显示 monitor 补的 `-`）。

`trusted_hash` 是 codex 对归一化 hook 配置的指纹，bash 侧无法可靠复现（与 0.144 的结论一致），因此插件**不预写/不复制信任记录**——需用户在 codex TUI 内对每个新实例授信一次。判定方法：实例 `config.toml` 无 `hooks.state` 键 → 未授信。**可观测性（2026-10-20）**：`check --json` 新增 `trust` 维度，`tmuxclihook check` 与 TUI 明细显示当前实例及其他实例的授信状态；**键缺失 = 一定不执行；键存在 ≠ hash 匹配**（hooks 被改写后旧键仍在，codex 会重新弹 Trust）。

**codex daemon 的 pane 归属是启发式（2026-10-19）**

codex 0.163 managed app-server daemon 常驻（ppid=1），hooks 在 daemon 中执行，继承的 `TMUX_PANE` 不可信（可能是当前 server 中无关的 pane）。插件用「同工具进程树候选 → thread title → cwd」收敛，只有唯一候选才采用；同名 thread 且 cwd 相同的多个 pane 会故意保持 idle `-`，不猜。根治需上游：codex 在 hook 事件中携带 pane/客户端上下文，或 cc-switch 为每个 pane 启动独立 daemon。**升级 monitor 无需手动重载**（内容指纹自检 + exec），但 hook 脚本本身仍随 npm 包路径生效。

**Claude 的 PermissionRequest hook JSON 不携带 `tool_use_id`**（官方设计，非遗漏）。
官方文档原文："PermissionRequest hooks receive `tool_name` and `tool_input` fields like PreToolUse hooks, **but without `tool_use_id`**"——且无任何「计划添加」说明，**等上游补 ID 的路线不存在**。2026-10 实测（claude 2.1.304）仍无 `tool_use_id`，但携带 `prompt_id`（turn 级 UUID）。

因此（仅 claude；codex/opencode 见下段，它们的 pending-perm 会真实写入）`_add_pending_perm` 因 id 为空直接 return，**claude 的 `pending-perm` 文件实际从未写入数据**。
状态机仍能正确显示 `!`/`?` 是因为：
1. PermissionRequest 早写 tmux option 立刻生效
2. 权限对话框流程仍逐个串行，单次循环内不存在 PermReq 之间的真并发
3. PostToolUse 配对清空 pending-pre → 派生 `>` 覆盖早写的 `!`

**Parallel tool calls 已是现实**（官方："PostToolUse fires once per tool, which means it fires concurrently when Claude makes parallel tool calls"；2026-10-20 日志实证：PostToolUse 的 hook 先于同 id 的 PreToolUse 被记录——async hook 到达顺序无保证）。**当前未爆发的真实原因**：权限对话框流程本身仍逐个串行 + PreToolUse 的 LIVE_STATUS 兜底有效。触发条件部分满足（hook 交错已观察到；PermReq 之间真并发未观察到）。届时重新设计的锚点候选：`prompt_id`（turn 级，已在 input 中）、PostToolBatch 事件的 `tool_calls` 数组（批级权威清单，每项含 `tool_use_id`）、或 `tool_name + tool_input` 哈希作 surrogate id。**2026-10-20 补充**：Post 先于 Pre 的残留已由 `recent-post` tombstone 兜底（迟到的 Pre 不再重建 pending）；仍未解决的是 Claude 无 ID 的并行 PermissionRequest 绑定顺序。

Codex 的 `PermissionRequest` 不提供 `tool_use_id`，但 `PreToolUse` / `PostToolUse` 提供且
可配对。核心会把无 ID 的权限请求绑定到最近的同工具 pending PreToolUse ID，批准后的
`PostToolUse` 因而能精确清理并恢复 `>`；无法绑定时才写 sentinel，保守保持 `!` 到
`Stop`、`UserPromptSubmit` 或 `SessionStart` 清理。OpenCode 的 `permission.asked.id` 与
`permission.replied.requestID` 则会精确维护多个 pending 请求。

---

**点 No 拒绝时状态卡 `!`（不会自动转 `-`）**

用户在 Claude Code TUI 中选择 No 拒绝权限时，Claude Code 完全静默：
- 不发 Notification（无 `denied`/`rejected` 消息）
- 不发 PostToolUseFailure
- 不发 Stop（官方文档确认 Stop "Does not run if the stoppage occurred due to a user interrupt"——用户 interrupt/Esc 中断同样无 Stop 兜底，佐证 tmux 端 Esc 检测路径的必要性）
- 后续 batch 中尚未发起的工具也不再发 PreToolUse

本插件因此无任何 signal 可监听，状态保持 `!` 直到下次 `UserPromptSubmit`（用户输入新提示）。

ESC 拒绝能转 `-` 是因为 tmux 端 `bind-key -n Escape` 拦截了键流；No 是 TUI 选项选择，不经过 tmux 键事件，无法捕获。

**已知此行为，不实现自动恢复**。`!` 语义仍准确（等待人类下一步动作），下次输入自然清。上游补充事实（2026-10）：claude 2.1.89 新增了 `PermissionDenied` 事件，但它只在 **auto mode classifier 拒绝**后触发，不覆盖用户点 No 的场景；PostToolBatch 事件（批级 `tool_calls` 数组）是否携带被拒绝的调用**文档未写**——若实测确认携带，它是比盲超时更可靠的拒绝对账信号（历史上 `!` 超时自动重置方案已被 revert，教训是不可用盲超时）。届时再评估接入。

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

# hooks 健康明细（bash 侧，machine-readable；exit code 与默认 check 一致）
bash scripts/install-claude-hooks.sh check --json | jq .
# 非交互子命令（人类可读 + .tmux.conf 指向 + 当前 source；exit 1 = 有缺失或漂移）
TMUXCLIHOOK_SOURCE=$PWD node installer/bin/cli.js check
```

```bash
# bash 集成测试（check --json / cc-switch / suppress / 状态机）
bash tests/check-json.test.sh
bash tests/ccswitch-install.test.sh
bash tests/opencode-config-dir.test.sh
bash tests/pane-resolve.test.sh
bash tests/monitor-selfcheck.test.sh
bash tests/suppress-cross-source.test.sh
bash tests/status-machine.test.sh
bash tests/pid-tree.test.sh
bash tests/install-idempotency.test.sh
bash tests/symlink-write.test.sh
bash tests/cross-tool-repair.test.sh
bash tests/bindings.test.sh
```

### 快捷键

| 快捷键 | 操作 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + M-h` | 安装 Codex hooks |
| `prefix + M-u` | 卸载 Codex hooks |
| `prefix + I` | 打开交互式 TUI 安装器（环境检查/侦测CLI/装卸修hooks/软链校验） |
| `prefix + r` | 重载 tmux 配置（helper 脚本：source 实际存在的配置文件 + 重跑插件初始化；原绑定保存于 `@claude_hooks_saved_bind_r`） |

> 全局 `Escape` 绑定被插件占用（`!`/`?` 状态时拒绝检测）。既有绑定会在覆盖前保存到 `@claude_hooks_saved_bind_escape` 并一次性告警；恢复：`eval "$(tmux show-option -gv @claude_hooks_saved_bind_escape)"`。

### Node TUI 安装器（installer/）

交互式安装器（@clack/prompts + execa），承接安装前置环节：环境侦测/修复（tmux/jq/bash/node）、AI CLI 侦测（版本+minVersion+hooks 健康明细：判定真源/缺失原因/注册路径/漂移警告，经 `src/check-detail.js` 渲染 bash `check --json`）、hooks 装/卸/修/漂移收敛、tmux 集成校验/修复。非交互子命令 `tmuxclihook check [claude|codex|opencode]` 输出同一份明细（exit 1 = 有缺失或漂移）。Esc 导航见「关键设计决策」的 Esc 条目。

环境检测结果分为 `ready` / `missing` / `outdated`。Doctor 对缺失依赖使用 `brew install`；只有过旧 formula 确认由 Homebrew 管理时才使用 `brew upgrade`；未安装 Homebrew 或非 Homebrew 管理的软件只给手动建议。bash 只检查存在性，AI CLI 不自动安装/升级。逐项执行后完整复检，单项失败不阻塞后续项。

不重实现 bash hooks 逻辑——hooks 装/卸经 execa 调薄 wrapper `install-<tool>-hooks.sh`。工具元数据在 `installer/src/adapters-meta.js`，与 bash adapter 一一对应。完整操作从仓库运行 `cd installer && npm install && npm start`，或使用 `prefix + I`。npm 包不包含根目录脚本，`npx tmuxclihook` 主要用于环境/CLI 检查。详见 `installer/README.md`。

## 关键设计决策

- **共享库架构**：通过 `lib-tmux-ai-status.sh` 提供通用功能，`TOOL_ID` 区分状态变量和临时文件
- **Attached-only 显示**：`build_all_status()` 按「进入时间 → 创建时间」两级升序排列（`window_index`/`pane_index` 次之），仅显示 attached session。进入时间 = `client-session-changed` hook（attach 与 switch-client 的共同汇聚点）时 `_session-switched` 写入的 session option `@ai_entered_time`（刚进入的 session 排最后；无记录回退 `session_created`）。该 hook 对自指 switch 也触发（tmux 源码无 `old != s` 守卫），handler 用 per-client 自维护的上次 session（server option `@ai_prev_sess_<client>`）对比过滤：`cur != prev` 才算真进入（已断开 client 的残留键由 `_prune_prev_sess_options` 在 60s 节流清理中剪枝）。不用 `session_last_attached`：tmux 对该时间戳无条件刷新（自指 switch 也算），会污染「刚进入的排最后」的预期。不用 `client-attached`：switch-client 进入（tmuxtui 在已 attach 的 client 里切项目）不触发它。hook 命令传 `#{hook_client}`（3.7c/3.8 均展开为触发 client 名）——**不存在 `#{hook_client_name}` 变量**（tmux 任何版本都没有；误用恒展开为空，handler 的 `[ -n "$3" ]` 守卫静默跳过，entered_time 从不写入、排序退化 created 序，2026-10-16 实测踩坑）
- **set-hook 是 upsert**：改 hook 名或从入口删除 hook 行时，tmux server 里已注册的旧 hook 不会消失（prefix+r 重载不清），需手动 `tmux set-hook -ug <hook>` 清除，否则旧命令继续触发（case 无匹配时静默 no-op，但属脏状态）
- **Pane 解析与 daemon 适配（2026-10-19）**：祖先链（`ps -o ppid` 向上匹配 pane_pid）是权威信号；**祖先链不通说明 hook 跑在脱离 pane 的常驻进程里（如 codex 0.163 managed app-server daemon，ppid=1），此时继承的 `$TMUX_PANE` 一律丢弃**——实测它可能指向当前 server 中真实存在但无关的 pane（不只是「指向不存在的 pane」）。兜底顺序：session 映射（`.pane-meta-*` 校验 tool/server_pid/pane_pid/cwd，防 server 重启后 pane id 复用）→ 当前工具的进程树候选 → `adapter_pane_hints`（codex: `thread_name` ↔ pane title）→ hook cwd 与 `pane_current_path`；只有唯一候选才采用，多候选保持空（monitor 补 idle `-`）。失败结果 5s 负缓存，避免 daemon 高频 hook 反复 BFS。`adapter_pane_hints` 只读、不调用 tmux（复用核心一次性 `_PANE_SNAPSHOT`）
- **Codex server 级 monitor**：`tmux-ai-monitor` 每秒刷新聚合状态并只跟踪实际见过 Codex 的 pane；解决延迟 `SessionStart` 导致启动不显示，以及无 `SessionEnd` 导致 `/exit` 不清空；不改变 `/new` 的 `✓` 行为。**launcher 识别（2026-10-19）**：cc-switch 的 `switch` 启动时 `pane_current_command` 是 `switch`/`volta-shim`/`node` 而非 `codex`，原实现既补不出 idle `-`、`/exit` 后也不会清状态；现对 attached 的 launcher pane 每 tick 做一次进程树探测（每 tick 一次 `ps` 快照 + 一次 awk 批量 BFS），命中即写 `@ai_monitor_seen_<tool>`，`build_all_status` 用该标记补 `-`，退出时沿用既有清理分支。**性能（2026-10-19）**：旧实现逐 pane 调 `_pane_has_tool_process`（每个 pid 各起一次 `ps`/`pgrep`），launcher 多的环境单 tick 达 2.8s，叠加 5 tick 节流后新启动 codex 需 7-8s 才显示；改为一次进程快照 + 内存/awk BFS 后单 tick ~0.23s，探测也改为每 tick（新工具 ≤1 tick 显示）。**升级自重启（2026-10-19）**：monitor 启动时记录脚本目录内容指纹（`cksum`），每 60 tick 对比；npm 升级/重装替换文件后同 PID `exec` 自身重载新代码（保留 generation/server pid，`@ai_monitor_pid` 不变）。用内容指纹而非 mtime——npm 可能保留 tarball 旧 mtime。`TMUX_AI_MONITOR_RELOAD_DISABLE=1` 可关闭
- **终态清理认 monitor seen（2026-10-20）**：`_cleanup_stale_panes` 的 `✓`/`-` 分支此前只做进程树 BFS；launcher（switch/volta-shim）或 daemon 场景工具进程脱离 pane 进程树时，正确的 `✓` 会被 60s 清理抹成 `-`。现在查询动态追加 `@ai_monitor_seen_<tool>` 字段，任一为 1 即保留（与 `build_all_status` 同一信任模型）。活跃态 `!`/`?`/`>` 不受影响——其判据是状态归属（pane 目录/session 映射）而非进程存活，认 seen 会让该清理的孤儿状态永不清理。边界：monitor 停摆而 option 残留时终态会保留更久（monitor 每 tick 主动清理 seen，入口保证其常驻）
- **多行状态栏**：AI 状态占据独立 `status-format[N]` 行，不修改用户的 `status-right`
- **写路径互斥与幂等（2026-10-20）**（PR-B）：
  - **wrapper 层 mkdir mutex**（`_install_acquire_lock`，macOS 无 flock(1)）：临界区覆盖 adapter 装/卸 + suppress 标记读-改-写，串行化 TUI/auto/SessionStart 修复/`_maybe_repair_hooks`/drift 收敛五方。锁目录建不出（ENOTDIR）→ 降级无锁 + 告警；持锁超时（~10s）→ 报错退出。边界：Claude Code 自身写 settings.json 不遵守锁（外部写者）
  - **语义不变跳写**：merge 输出与现值两边 `jq -S` 规范化对比，相同则不写（不触碰 mtime，避免 file watcher 无谓重载）
  - **auto 幂等（`adapter_check_converged`）**：integrity + 全部条目指向当前源（无漂移/死条目）+ 每事件条目 ≤1（无重复）→ tmux reload 不再全量重写真源；强收敛保留（任一异常仍重装收敛）。已知 trade-off：结构漂移（async/matcher 被外部改）auto 跳过，显式 install 仍强收敛。参照系仅限 wrapper 上下文（事件路径 `pwd` 逻辑路径 vs wrapper `pwd -P` 物理路径）
  - **suppress 标记双向告警**：write/clear 失败不再吞错（clear 失败会让残留标记把 auto 永久挡住）
- **符号链接写穿（2026-10-20）**：`_install_atomic_write` 写入前用 `_install_real_target` 解析 symlink 链（相对链接基于链接所在目录、悬空链接同样解析、40 层上限失败回退原路径），临时文件与 `mv` 都作用于真实目标——`mv` 直接作用于链接路径只会替换链接本身（POSIX rename 语义），会让 cc-switch 的 codex 实例与 `~/.codex/hooks.json` 共享真源分叉（实例首次安装、target 尚不存在时即触发）。uninstall 清空改走 `_install_remove_target`（删真实目标、保留链接，下次 install 写穿即恢复共享）。回归测试 `tests/symlink-write.test.sh`
- **幂等初始化**：`prefix+r` 重载无副作用（检测已占行、hook 已存在则跳过）。**reload 自愈（2026-10-20）**：绑定指向 `scripts/tmux-ai-reload`（按 `#{config_files}` 候选列表逐个 `[ -f ]` 过滤后 source，再重跑入口；**多文件重载需 tmux ≥3.2**——3.1 无 `config_files`，回落 `~/.tmux.conf`），且**每次加载都重绑**（旧一次性哨兵会让 source 配置内的用户 `bind r` 重置绑定后不再重装，纯 TPM 模式第二次重载起初始化静默停止）。原 `prefix+r` / 全局 `Escape` 绑定在覆盖前保存到 `@claude_hooks_saved_bind_r` / `@claude_hooks_saved_bind_escape`（供手动恢复；Escape 冲突一次性告警 `@claude_hooks_esc_warned`）。**Escape 检测必须用 `list-keys -T root Escape`**——`list-keys -n` 不是合法旗标（3.8 实测 `unknown flag -n`，会被 `2>/dev/null` 吞掉导致保存/告警永不发生）
- **Stale hook 清理**：安装时清理指向不存在脚本的旧 hook 和重复路径
- **`!` 和 `?` 对等原则**：两者本质相同——都需要人类审批。对 `!`（PermissionRequest）的任何逻辑变更（竞态保护、Stop 推断、清理路径）必须同步应用到 `?`（AskUserQuestion），反之亦然。差异仅限显示优先级（`!` > `?`）和符号本身
- **Pane title 作为 ground truth**：用 Claude Code 的 pane title 变化（`✳` ↔ 盲文）检测用户批准，替代复杂的 toolmap/flag 状态机
- **Esc 键拒绝检测**：`bind-key -n Escape` 全局拦截，仅在 `!`/`?` 状态时设 `-` 并透传 Esc，其余直接透传。Poll 检测到状态变 `-` 后自动退出，无需显式 stop
- **多安装源收敛与卸载意图标记（2026-10-14）**：hooks 条目可由开发 repo 与 npm bundled 包两个「安装源」写入（TUI 走 bundled、自修复走 tmux 加载源），曾因 claude 剥离用 `startswith($hook_script)` 路径敏感匹配导致跨源卸载假成功（剥离零命中 → 报成功但真源未变 → 检测恒「已装」）。修复后的契约：
    - **归属判定路径无关**：所有 strip/merge 清理/check 计数统一 `contains("tmux-ai-status")`（codex 用常量 `_CODEX_MARKER="tmux-ai-status codex"`，count/integrity/detail/strip 同源），legacy 名（tmux-powerline-claude-status/tmux-claude-status）清理保留。跨源 install/卸载/修复在任意源组合下结果一致。**codex 命令级剥离（2026-10-20）**：逐 hook 删除含 marker 的 command（不看 `type`，缺 type 的条目也能清），同组第三方 command 保留；空 group/事件删除；无 `hooks` 键/null/非数组的 group 原样保留
    - **codex 重复条目只提示不自动收敛（2026-10-20）**：同事件注册多条本插件 command 时 integrity 仍过、普通 install no-op（重写即 re-trust），`check-detail.js` 的 `findDuplicateEvents`（`events.registered > 1`）在 CLI/TUI 明细中渲染警告，exit code 不变；TUI 收敛入口把 codex 重复纳入候选，复用 re-trust 确认，force install 走命令级 strip 收敛
    - **check 三要素**：按事件计数（非扁平总数，防重复+缺失假阳性）+ 结构指纹 + **每事件至少一条条目脚本存活**（`test -x` command 首 token；死路径如 npm 卸载/volta 升级换路径 → missing → 重装收敛自愈）
    - **收敛策略不对称**：claude 无 trust 代价 → install 每次强收敛到执行者路径；codex/opencode **no-op if valid**（check 通过时不改写——codex 重写即 `trusted_hash` 失效需重新 Trust all，仅缺失/死路径才 strip+重写收敛）。**drift 收敛旁路（2026-10-17）**：`TMUX_AI_FORCE_INSTALL=1` 旁路 codex/opencode 的 no-op 门禁——hooks 指向其他安装源但脚本存活时 integrity 恒过，普通 install 永远收敛不了；TUI 漂移收敛入口对 codex 显式确认 re-trust 代价后经 execa env 传入
    - **卸载意图标记（suppression marker）**：`${TMUX_AI_SUPPRESS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/tmuxclihook}/suppressed-<tool>`（持久，跨重启有效）。wrapper 显式 uninstall 成功 → 写；显式 install 成功 → 清；三条自动修复路径（`_maybe_repair_hooks`、SessionStart 重装、入口 `auto`）见标记一律跳过。`install-claude-hooks.sh auto` 供 tmux 入口加载时调用（被挡静默 exit 0）；用户恢复需显式安装（prefix+C-h / TUI）
    - **安装意图标记（installed marker）**：同目录 `installed-<tool>`（持久）。显式 install / claude `auto`（含已收敛跳过）→ 写；显式 uninstall → 删（**先删 installed 再写 suppressed**：suppress 写失败时 errexit 退出，此顺序避免标记残留、刚卸载的 hooks 被 `_refresh` 装回）。跨工具修复据此区分「用户装过」与「从未安装」：无标记时只对 check 通过的既存安装补登记，绝不自动安装；0.5.14 之前安装且 hooks 已损坏的老用户需显式重装一次才恢复自动修复能力
    - `_SUPPRESS_DIR` 在 `lib-install-hooks.sh` 与 `lib-tmux-ai-status.sh` 各定义一次（双上下文自包含，改动需两处同步）；adapter check 不得依赖 lib-install-hooks.sh（事件路径未 source 它）

**check --json 健康明细与漂移检测（2026-10-17）**：解决「不知道是否要修 hooks / 不知道当前生效 source」两个可观测性问题。要点：
- **默认 `check` 输出契约不变**（`ok`/`missing` + exit code，被 TUI `hooksInstalledAsync` 与 tmux 自修复依赖）；明细走 wrapper 第二参 `check --json`（单行 JSON：status/mode/events/plugin/suppress/drift），由 `lib-install-hooks.sh` 的 `_wrapper_check_json` 拼装。status 判定复用 `adapter_check_integrity` 本体 → 与 ok/missing 永不发散
- **drift 参照系 = 执行中 wrapper 自身的 `_LIB_DIR`**：Node 经 execa 调的正是其解析出的 `SCRIPTS_DIR` 下的 wrapper，故 `_LIB_DIR` 即当前 source 的 scripts dir；手动用旧 source 的 wrapper 跑 check 得到「相对该 source 无漂移」也是正确语义（它正是那个源的收敛执行者）。Node 侧不二次计算（避免两处真源），只附加 bash 判不了的 `.tmux.conf` 全局信息
- 消费方：`tmuxclihook check [tool]` 子命令与 TUI「侦测 AI CLI」共用 `installer/src/check-detail.js`（解析/渲染），漂移项在 TUI 内给收敛入口（收敛策略见上条）；check 子命令有缺失/漂移/无法判定时 exit 1
- **自修复不再完全静默**：`_maybe_repair_hooks` 实际触发重装后 `tmux display-message` 浮出成功/失败（与 SessionStart 修复路径的既有提示对齐，全链路两个可见点）；自 2026-10-20 起该函数同时被 `_run_refresh`（tmux run-shell）与 SessionStart（AI CLI hook 进程，host 进程 errno 会计入首轮响应延迟，故有 60s 节流与失败退避）调用——SessionStart 原内联修复块已归并至此（顺带修掉「installer 不带 auto 参数绕过 suppress 标记」「失败也显示已修复」两个缺陷）；**跨工具闭环（2026-10-20）**：`_run_refresh` 同时调 `_maybe_repair_other_tools`——`_refresh` 固定以 claude 身份运行，codex/opencode 的 hooks 整体丢失后自身 SessionStart 不会再来，只能靠此兜底（仅 `installed-<tool>` 已登记者，每工具 60s 节流；未登记者只补登记健康既存安装）

**Esc 导航（2026-10-17）**：clack 0.7 的 Prompt 仅把 `\x03`（ctrl+c）映射为 cancel，**Esc 默认无任何效果**——各子菜单「Esc 返回」此前只是文案承诺。`installer/src/esc.js` 挂全局 keypress 监听，看到 escape 就 `process.stdin.emit('keypress', '\x03', {name:'c', ctrl:true})` 合成取消（**必须 emit 而非 stdin.write**：raw mode 下向 fd 0 写入不回环成输入）。主菜单 Esc 退出 / 子菜单 Esc 返回 / confirm Esc 取消全部真实生效；spinner 期间不转译（clack `block()` 给 `\x03` 装了 `process.exit(0)`，转译会让 Esc 在 spinner 期间硬退出且不恢复 raw mode），`cli.js` 的 `spinner()` 包装负责联动。

## 依赖

- tmux >= 3.1
- jq
- bash（任意版本；脚本零 bash4 专属特性，macOS 自带 3.2 即可。交互 shell 用 zsh/fish 均不影响——hook 由 AI CLI 以 `#!/bin/bash` 执行，与交互 shell 无关）
- sqlite3（仅 cc-switch 环境：hooks 真源在 `~/.cc-switch/cc-switch.db`，装/卸/完整性走 sqlite；macOS 自带。缺失时自动回退传统文件模式）

## Hook 事件注册

**Claude Code**（10 个事件，注册到 `~/.claude/settings.json`）：
SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionRequest, Notification, Stop, StopFailure

全部 async=true，PermissionRequest 例外（async=false 用于立即阻塞）。命令格式：`<abs>/scripts/tmux-ai-status claude <Event>`。

**Claude hook timeout（官方默认，2026-10 核实）**：command 类 hook 默认 **600 秒**；SessionEnd 全体 hook 共享 **1.5 秒**预算（per-hook timeout 可抬升至多 60s）；`async: true` 的 hook **完全不受 timeout 保护**（挂起会常驻，直到 `claude -p` 模式 teardown 才被 kill）。含义：本插件脚本内的任何同步等待（如事件锁重试）若失控，最长可阻塞 sync PermissionRequest 路径达 600s——锁等待上限设计必须自限（事件锁重试预算 ~2s），不能依赖上游超时兜底。

**Codex CLI**（6 个事件，注册到 `~/.codex/hooks.json`，需 codex ≥ v0.144）：
SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, PostToolUse, Stop

命令格式：`<abs>/scripts/tmux-ai-status codex <Event>`。**全部同步**（0.144 静默跳过 `async=true` 的 hook，故不能用 async）。

### Codex 与 Claude 的差异（备忘）

- Codex **无** `SessionEnd / Notification / PostToolUseFailure / StopFailure` 事件。Codex 的 `Stop` 是「turn 完成」而非 session 结束；session 真正退出时无任何 hook。→ `tmux-ai-monitor` 记录实际见过 Codex 的 pane，并在 `/exit` 后确认进程树无 Codex 再清空状态。
- **Codex 0.144 hook 系统重写（相对旧 0.117 的三处 breaking change）**：
  1. **不再读取独立 `hooks.toml`** —— 仅认 `config.toml` 的 `[hooks]` 表，或 config 文件夹里的 `hooks.json`。本插件改用 `~/.codex/hooks.json`。
  2. **`async=true` 的 hook 被静默跳过**（源码 `if r#async { skip "async hooks are not supported yet" }`）—— 故本插件所有 codex hook 均同步（无 async 字段，默认 false）。
  3. **Hook trust 门禁** —— user 来源的 hook 需 `hooks.state.<key>.trusted_hash` 匹配 codex 计算的归一化 TOML 指纹才运行。该 hash 无法在 bash 里可靠复现，故 `install-codex-hooks.sh` **不预写 trusted_hash**；用户下次启动 codex TUI 会弹「Hooks need review → Trust all and continue」授信一次即永久生效（或以 `codex --dangerously-bypass-hook-trust` 启动跳过）。
- Codex hooks 配置在 `~/.codex/hooks.json`（JSON），结构 `{"hooks":{"<Event>":[{"hooks":[{"type":"command","command":...,"timeout":5}]}]}}`。`install-codex-hooks.sh` 用 jq 读改写：仅剔除/替换 command 含 `tmux-ai-status` 的 group，保留用户/其他工具自有 hook（依赖 jq）。
- Codex 与 Claude 的 stdin JSON 字段同构（`session_id`/`tool_name`/`tool_use_id`/`tool_input`/`hook_event_name`）；`PermissionRequest` 均不带 `tool_use_id`，现有兜底逻辑通用。
- Codex hooks 同步执行，脚本正常退出 0 且 stdout 为空即视为 no-op 透传——本插件只读状态、不写 stdout，天然安全。

---

**Codex `/new` 后 pane 卡上一轮 `✓`（不自动转 `-`）**

用户在 codex 中 `/new` 已开新 session，但 pane 状态行仍显示上一轮遗留的 `✓`，语义上应为 `-`（空闲）。这是 codex hook 语义的**结构性空窗**，非 bug：

1. **无 `SessionEnd` 事件**（`ADAPTER_HAS_SESSION_END="false"`）。Claude `/new` 时旧 session 发 `SessionEnd` 清空 `@ai_pane_status`；codex 没有，旧 session `Stop` 留下的 `✓` 残留在 pane option 上。
2. **`SessionStart` 是 `deferred`**（上游 `run_pending_session_start_hooks` 延迟到首个 turn 才发）。`/new` 那刻不触发，走不到 `tmux-ai-status` 的 `STATUS="-"`。
3. **`build_all_status` idle 兜底救不了**：仅在 `@ai_pane_status` 为空时补 `-`，此刻值是 `✓`（显式非空），跳过兜底。
4. **`tmux-ai-monitor` 刻意不清**：`/new` 是同一 codex 进程内换会话，monitor 仍能确认 Codex 存活，因此保留 `✓`；它只精确处理“启动补 `-`”和“`/exit` 清空”。

四重条件恰好绕过所有会把状态改回 `-` 的机制。`✓` 卡到用户在新 session 提交首条 prompt（`UserPromptSubmit` → `>`，延迟的 `SessionStart` 一并 flush → `-`）才刷新。

**已知此结构性限制，不实现自动恢复**。`✓` 语义仍近似准确（上一轮确实完成），下次 `UserPromptSubmit` 自然清。若上游 codex 未来补 `SessionEnd` 或将 `SessionStart` 改为 immediate，届时可去除此限制。
