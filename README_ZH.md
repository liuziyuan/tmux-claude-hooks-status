# tmux-claude-hooks-status

一个 tmux 插件，在 tmux 状态栏中显示 AI CLI（Claude Code / Codex）的实时状态。通过各工具的 hook 系统实现，支持按 pane 显示状态（空闲、处理中、等待授权、等待用户输入）。Claude Code 与 Codex 的 hook 语义同构（事件名、stdin JSON 字段一致），共用一套核心脚本，以 `TOOL_ID`（`claude`/`codex`）区分。

[English](README.md)

## 前置条件

交互式 TUI 是一个 Node 程序，**无法给自己装运行时**，因此在运行它*之前*必须先具备：

- **Node.js ≥ 18** —— `npm install -g` 安装 TUI 和运行 TUI 都需要它。若缺失请先自行安装（如 `brew install node`，或用 nvm/nodenv）。TUI 无法替你装 Node。
- **Homebrew**（macOS，推荐）—— TUI 的环境「Doctor」*只*通过 Homebrew 修复依赖。没有 Homebrew 时，Doctor 只打印手动建议，不安装任何东西。

真正的运行依赖 —— **tmux ≥ 3.1** 和 **jq** —— 既可由 Doctor 代为安装（经 Homebrew，需你显式勾选），也可自行安装：

```bash
# macOS：一次性装齐
brew install node tmux jq
```

Doctor 从不静默安装：它只对你勾选的项动作，只走 Homebrew，绝不自动装 Homebrew，不碰非 Homebrew 管理的软件，也从不自动安装或升级 AI CLI（Claude Code / Codex / opencode）。

## 快速安装（交互式命令行）

用 npm 全局安装已发布的 TUI（需要 Node.js 18+；插件的 `scripts/` 与 tmux 入口已打包进 npm 包内，这条路径无需仓库 checkout）：

```bash
npm install -g tmuxclihook
tmuxclihook
```

在 TUI 中可完成环境检查/修复、Claude Code / Codex / opencode hooks 的安装/卸载/修复，以及把插件集成进 `~/.tmux.conf`（写入一行指向全局安装路径的 `run-shell` 声明，不再需要 TPM 软链）。插件载入 tmux 后，也可以随时使用：

```text
prefix + I
```

`npx tmuxclihook` 只适合运行环境和 AI CLI 检查：它的临时缓存目录每次运行后都会被清理，若在这条路径上写入 hooks 或 tmux 集成，写入的路径运行完就会失效。需要持久生效的操作请用 `npm install -g`。

**本地开发调试？** 用"source 管理"菜单或环境变量把 TUI 指向仓库副本，而非包内自带的代码：

```bash
TMUXCLIHOOK_SOURCE=/path/to/your/checkout tmuxclihook
```

之后安装 hooks / 集成 tmux 都会写入该仓库副本的路径，改代码立即生效，无需重新发布。切换 source 不会自动重写已经安装好的 hooks 或 `.tmux.conf`——切换后需重新执行一次"安装 hooks"/"tmux 集成"。

环境 Doctor 会安装缺失的 Homebrew formula，并且只升级已经由 Homebrew 管理的过旧 formula。它不会自动安装 Homebrew，不会修改非 Homebrew 管理的软件，也不会自动安装或升级 Claude Code / Codex CLI。所有修复均需用户选择，执行后会自动完整复检。

## 快速卸载 Hooks

通过 `prefix + I`（或 `tmuxclihook` / 在 `installer/` 中运行 `npm start`）进入 TUI，选择“卸载 hooks”。如需连同 tmux 配置和插件软链一起完整移除，请查看 [`AI_UNINSTALL.md`](AI_UNINSTALL.md)；该兼容文档继续用于无 TTY 和故障恢复场景。

## 手动安装

### 1. 安装依赖

```bash
# macOS
brew install tmux jq

# 验证版本（需要 tmux >= 3.1）
tmux -V
jq --version
```

Claude Code / Codex 的 hooks 是纯 shell，只需 `bash` + `jq`。opencode 集成是一个由 opencode 自身运行的 TypeScript plugin，无需额外运行时。

### 2. 获取插件

将仓库 clone 到 TPM 的插件目录（下面两种集成方式都假设这个固定位置，以便本文档中的示例路径始终有效）：

```bash
git clone https://github.com/liuziyuan/tmux-claude-hooks-status.git \
  ~/.tmux/plugins/tmux-claude-hooks-status
```

### 3. 集成进 tmux

在以下两种方式中**任选其一**。

**推荐：`run-shell` 直连（无需 TPM）：**

在 `~/.tmux.conf` 中加一行：

```tmux
run-shell '~/.tmux/plugins/tmux-claude-hooks-status/tmux-ai-hooks-status.tmux'
```

这与交互式 TUI 写入的方式完全一致，不依赖 TPM 软链。

**备选：TPM（tmux 插件管理器）：**

若你已用 TPM 管理插件，先安装 TPM（如未安装），并用 `owner/repo` 形式声明插件，TPM 才能拉取：

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

```tmux
# --- 插件 ---
set -g @plugin 'liuziyuan/tmux-claude-hooks-status'

# TPM 初始化（必须放在最后）
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

然后按一次 `prefix + I` 让 TPM 拉取。注意：插件加载后会把 `prefix + I` 重绑为打开本项目的 TUI 安装器，因此 TPM 自己的 `prefix + I` 只在插件尚未生效前可用（之后请从 TPM 菜单里直接安装）。

加载后插件会自动完成：
- 在多行 `status-format` 中添加独立的 AI 状态行
- 注册生命周期 hook（session/client/pane）和 tmux server 级 monitor
- 不会修改你现有的 `status-right` 设置

### 4. 重载

启动（或重启）tmux，然后重载：

```
prefix + r
```

（tmux 默认 prefix 是 `Ctrl+b`：按下后松开 prefix，再按对应键。若你已把 prefix 改成 `Ctrl+a`，则用 `Ctrl+a`。）

### 5. 安装 Claude Code Hooks

在 tmux 内按快捷键：

```
prefix + C-h
```

插件会自动将 hooks 注册到 `~/.claude/settings.json`。

卸载 hooks：

```
prefix + C-u
```

### 手动安装 Hooks（可选）

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-claude-hooks.sh
```

### 6. 安装 Codex Hooks（可选）

需 **codex ≥ v0.144**（`hooks.json` lifecycle hooks 与 hook trust）。

在 tmux 内按快捷键：

```
prefix + M-h
```

插件会将 6 个同步 hooks 注册到 `~/.codex/hooks.json`：`SessionStart`、`UserPromptSubmit`、`PreToolUse`、`PermissionRequest`、`PostToolUse`、`Stop`。

卸载：

```
prefix + M-u
```

手动安装：

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-codex-hooks.sh
```

> Codex 没有 `SessionEnd`，且 `SessionStart` 延迟到首个 turn。插件因此启动 tmux server 级 monitor，每秒刷新一次：新打开 Codex 时补显示 `-`，执行 `/exit` 且 Codex 进程消失后清空 pane 状态。`/new` 仍在同一 Codex 进程内，故刻意保留上一轮 `✓`，直到下一次提交 prompt。
>
> 安装器只替换 command 包含 `tmux-ai-status` 的 hook group，保留 `hooks.json` 中其他内容。下次启动 Codex 时可能需要选择 **Hooks need review → Trust all and continue** 完成一次性授信。

### 7. 安装 opencode Plugin（可选）

在 tmux 内按快捷键：

```
prefix + C-p
```

与 Claude Code、Codex 不同，opencode 通过 TypeScript **plugin**（而非 hooks 文件）集成。安装器写入 `~/.config/opencode/plugins/tmux-ai-status.ts`，由 opencode 自身加载并执行。

卸载：

```
prefix + M-p
```

手动安装：

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-opencode-hooks.sh
```

## 状态符号与事件

每个 pane 的状态渲染为一个带背景色的色块。配色采用固定的 Dracula 方案，目前不支持自定义。

| 事件 | 符号 | 颜色 | 含义 |
|------|------|------|------|
| `SessionStart` | `-` | 黄色 | 会话空闲 |
| `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | `>` | 绿色 | 处理中 |
| `PermissionRequest` (AskUserQuestion) | `?` | 红色 | 等待用户输入 |
| `PermissionRequest`（其他工具） | `!` | 红色 | 等待授权 |
| `Stop` / `StopFailure` | `✓` 或 `-` | 黄色 | 完成，或回到空闲 |
| `SessionEnd` | （清空） | — | 会话结束（仅 Claude Code） |

- 多 pane / 多状态聚合时的优先级：`!` > `?` > `>` > 空。
- **没有**超时自动恢复。权限请求设置的 `!`/`?` 会一直保持，直到该请求被处理，或被下一次 `UserPromptSubmit` / `Stop` / `SessionStart` 清除。通过 `Esc`（被 tmux 拦截）拒绝会重置为 `-`；在 TUI 里选择 “No” 拒绝则会保持 `!` 到下一次输入。
- `Notification` 事件（仅 Claude Code）在内部处理：`idle_prompt` 及 `denied` / `cancelled` / `rejected` 消息会重置为 `-`。

## 依赖

- tmux >= 3.1（user options、set-hook、多行 status-format）
- jq（用于 hook 安装）
- bash（任意版本；macOS 自带 3.2 即可，交互 shell 使用 zsh/fish 不影响 hooks）
- Node.js >= 18（仅交互式安装器需要，shell hooks 不依赖 Node.js）

## 验证

```bash
# 1. 手动触发一次 hook
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/tmux-ai-status claude SessionStart
tmux show-option -g @ai_all_status

# 2. 检查 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@ai_pane_status}"

# 3. 检查 hooks 是否已注册
jq '.hooks | keys' ~/.claude/settings.json

# 4. 重载 tmux 配置
tmux source ~/.tmux.conf
```

## 快捷键

tmux 默认 prefix 是 `Ctrl+b`（按下后松开，再按对应键）。若你已把 prefix 改成 `Ctrl+a`，则用 `Ctrl+a`。

| 快捷键 | 功能 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + M-h` | 安装 Codex hooks |
| `prefix + M-u` | 卸载 Codex hooks |
| `prefix + C-p` | 安装 opencode plugin |
| `prefix + M-p` | 卸载 opencode plugin |
| `prefix + I` | 打开交互式 TUI 安装器 |
| `prefix + r` | 重载配置 |
