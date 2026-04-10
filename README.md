# tmux 环境搭建指南

在新系统上完整安装 tmux、插件及 Claude Code hooks 的标准流程。

---

## 目录

1. [依赖安装](#1-依赖安装)
2. [安装 TPM（插件管理器）](#2-安装-tpm插件管理器)
3. [应用 tmux 配置](#3-应用-tmux-配置)
4. [安装插件](#4-安装插件)
5. [安装 Claude Code hooks](#5-安装-claude-code-hooks)
6. [验证](#6-验证)

---

## 1. 依赖安装

```bash
# macOS
brew install tmux jq

# 验证版本（需要 tmux >= 3.1，jq 用于解析 hook 的 JSON 输入）
tmux -V
jq --version
```

---

## 2. 安装 TPM（插件管理器）

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

---

## 3. 应用 tmux 配置

将本仓库的 `.tmux.conf` 复制到 `~`：

```bash
cp .tmux.conf ~/.tmux.conf
```

创建 Claude Code hooks 插件的 symlink：

```bash
# 将插件链接到 TPM 目录（替换为实际仓库路径）
ln -sf "$(pwd)/tmux-claude-hooks-status" ~/.tmux/plugins/tmux-claude-hooks-status
```

---

## 4. 安装插件

启动（或重启）tmux，然后在 tmux 内执行：

```
prefix + I
```

（默认 prefix 是 `Ctrl+a`，按下后松开，再按大写 `I`）

TPM 会自动下载并安装 `.tmux.conf` 中声明的所有插件。
Claude Code hooks 插件通过 symlink 安装，TPM 会自动识别。

安装完成后重载配置：

```
prefix + r
```

---

## 5. 安装 Claude Code hooks

在 tmux 内按快捷键一键安装：

```
prefix + C-h
```

插件会自动将 hooks 注册到 `~/.claude/settings.json`。

如需卸载：

```
prefix + C-u
```

### 手动安装（可选）

如果快捷键不可用，也可以手动运行：

```bash
bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/install-hooks.sh
```

### 插件功能

| 事件 | pane 边框显示 |
|------|-------------|
| `SessionStart` / `Stop` / `StopFailure` | `✓ 空闲` |
| `UserPromptSubmit` / `PostToolUse` | `⠿ 处理中` |
| `PermissionRequest` | `🔒 等待授权` |
| `Notification` | `💬 <消息前40字>` |
| `SessionEnd` | （清空） |

### 双模式支持

插件自动检测运行模式：

- **Powerline 模式**：检测到 tmux-powerline 时，在 status-right 前插入 Claude 状态
- **Native 模式**：无 powerline 时，独立渲染 status-right（Claude 状态 + 时间）

可强制指定模式：

```bash
# 在 .tmux.conf 中添加
set -g @claude_hooks_mode "native"     # 强制原生模式
set -g @claude_hooks_mode "powerline"  # 强制 powerline 模式
```

---

## 6. 验证

```bash
# 1. 手动触发一次 hook，确认变量写入成功
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/claude-status.sh SessionStart
tmux show-option -g @claude_all_status

# 2. 检查 pane 状态变量
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# 3. 检查 hooks 是否已注册
jq '.hooks | keys' ~/.claude/settings.json

# 4. 重载 tmux 配置
tmux source ~/.tmux.conf
```

---

## 快捷键速查

Prefix 为 `Ctrl+a`（按下后松开，再按对应键）。

### 高频

| 快捷键 | 功能 |
|--------|------|
| `prefix c` | 创建新 window |
| `prefix n` | 下一个 window |
| `prefix p` | 上一个 window |
| `prefix 0-9` | 切换到指定 window |
| `prefix d` | detach 当前 session |
| `prefix \|` | 左右分屏 |
| `prefix -` | 上下分屏 |
| `prefix x` | 关闭当前 pane |
| `prefix h/j/k/l` | 切换 pane（vim 风格） |
| `prefix C-h` | 安装 Claude Code hooks |
| `prefix C-u` | 卸载 Claude Code hooks |

### 中频

| 快捷键 | 功能 |
|--------|------|
| `prefix &` | 关闭当前 window |
| `prefix ,` | 重命名 window |
| `prefix w` | 列出所有 window |
| `prefix s` | 列出所有 session |
| `prefix $` | 重命名 session |
| `prefix z` | pane 全屏切换 |
| `prefix o` | 轮换切换 pane |
| `prefix q` | 显示 pane 编号 |
| `prefix r` | 重载配置 |
| `prefix I` | 安装 TPM 插件 |
