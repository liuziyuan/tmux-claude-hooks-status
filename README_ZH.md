# tmux-claude-hooks-status

一个 tmux 插件，在 tmux 状态栏中显示 AI CLI（Claude Code / Codex）的实时状态。通过各工具的 hook 系统实现，支持按 pane 显示状态（空闲、处理中、等待授权、等待用户输入）。Claude Code 与 Codex 的 hook 语义同构（事件名、stdin JSON 字段一致），共用一套核心脚本，以 `TOOL_ID`（`claude`/`codex`）区分。

[English](README.md)

## 快速安装（交互式命令行）

完整安装需要 Node.js 18+，以及一个包含根目录 `scripts/` 的仓库副本：

```bash
git clone https://github.com/liuziyuan/tmux-claude-hooks-status.git ~/.local/share/tmux-ai-hooks-status
cd ~/.local/share/tmux-ai-hooks-status/installer
npm install
npm start
```

在 TUI 中可完成环境检查/修复、tmux 插件软链创建，以及 Claude Code / Codex hooks 的安装、卸载和修复。插件载入 tmux 后，也可以随时使用：

```text
prefix + I
```

已发布的 `npx tmuxclihook` 入口可用于环境和 AI CLI 检查；hooks 与软链操作需要仓库根目录中的脚本，因此完整操作应从仓库副本或 `prefix + I` 启动。

环境 Doctor 会安装缺失的 Homebrew formula，并且只升级已经由 Homebrew 管理的过旧 formula。它不会自动安装 Homebrew，不会修改非 Homebrew 管理的软件，也不会自动安装或升级 Claude Code / Codex CLI。所有修复均需用户选择，执行后会自动完整复检。

## 快速卸载 Hooks

通过 `prefix + I`（或在 `installer/` 中运行 `npm start`）进入 TUI，选择“卸载 hooks”。如需连同 tmux 配置和插件软链一起完整移除，请查看 [`AI_UNINSTALL.md`](AI_UNINSTALL.md)；该兼容文档继续用于无 TTY 和故障恢复场景。

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
| `prefix + I` | TPM 安装所有插件 |
| `prefix + r` | 重载配置 |
