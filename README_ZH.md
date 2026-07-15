# tmux-claude-hooks-status

一个 tmux 插件，在 tmux 状态栏中显示 AI CLI（Claude Code / Codex）的实时状态。通过各工具的 hook 系统实现，支持按 pane 显示状态（空闲、处理中、等待授权、等待用户输入）。Claude Code 与 Codex 的 hook 语义同构（事件名、stdin JSON 字段一致），共用一套核心脚本，以 `TOOL_ID`（`claude`/`codex`）区分。

[English](README.md)

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

### 2. 安装 TPM（插件管理器）

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

### 3. 配置 .tmux.conf

在 `~/.tmux.conf` 中添加：

```tmux
# --- 插件 ---
set -g @plugin 'tmux-claude-hooks-status'

# TPM 初始化（必须放在最后）
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

插件会自动完成以下配置：
- 在多行状态栏中添加独立的 Claude 状态行
- 配置 pane 边框显示（pane 编号 + 标题）
- 不会修改你现有的 `status-right` 设置

### 4. 安装插件

启动（或重启）tmux，然后执行：

```
prefix + I
```

（默认 prefix 是 `Ctrl+a`，按下后松开，再按大写 `I`）

TPM 会自动安装所有声明的插件。安装完成后重载：

```
prefix + r
```

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

## 状态符号与事件

| 事件 | 状态 | 颜色 | 含义 |
|------|------|------|------|
| `SessionStart` | `-` | 黄色 | 会话空闲 |
| `PreToolUse` / `PostToolUse` | `>` | 黄色 | 处理中 |
| `PreToolUse` (AskUserQuestion) | `?` | 黄色 | 等待用户输入 |
| `PermissionRequest` | `!` | 红色 | 等待授权 |
| `Stop` / `StopFailure` | `✓` 或 `-` | 黄色 | 完成或回到空闲 |
| `SessionEnd` | （清空） | — | 会话结束 |

Notification 事件在内部处理——特定消息（权限相关、已取消等）会被分发到对应状态，而非直接显示。

## 自定义选项

| 选项 | 默认值 | 用途 |
|------|--------|------|
| `@claude_hooks_status_color` | `#F1FA8C` | 状态文字颜色 |
| `@claude_hooks_idle_icon` | `✓` | 空闲图标 |
| `@claude_hooks_busy_icon` | `⠿` | 处理中图标 |
| `@claude_hooks_auth_icon` | `🔒` | 等待授权图标 |

## 依赖

- tmux >= 3.1（user options、pane-border-status、set-hook、多行 status-format）
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

Prefix 为 `Ctrl+a`（按下后松开，再按对应键）。

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
