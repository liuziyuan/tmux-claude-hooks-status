# tmux-claude-hooks-status

一个 tmux 插件，在 tmux 状态栏中显示 Claude Code 的实时状态。通过 Claude Code 的 hook 系统实现，支持按 pane 显示状态（空闲、处理中、等待授权、等待用户输入）。

[English](README.md)

## 快速安装（自动）

使用 Claude Code 自动安装，运行：

```
ai https://raw.githubusercontent.com/liuziyuan/tmux-claude-hooks-status/main/AI_INSTALL.md
```

Claude Code 将逐步引导你完成安装。

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
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-hooks.sh
```

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
- bash >= 4.0

## 验证

```bash
# 1. 手动触发一次 hook
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/tmux-claude-status SessionStart
tmux show-option -g @claude_all_status

# 2. 检查 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

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
| `prefix + I` | TPM 安装所有插件 |
| `prefix + r` | 重载配置 |
