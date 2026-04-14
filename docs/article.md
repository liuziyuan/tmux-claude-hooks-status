# 还在盲等 Claude Code？一个 tmux 插件让你实时掌控所有会话状态

> 如果你同时开多个 tmux pane 跑 Claude Code，你一定遇到过这样的场景：切到某个 pane 发现它在等授权，而你已经等了好几分钟；或者不确定哪个 pane 还在跑、哪个已经结束。tmux-claude-hooks-status 就是为了解决这个问题而生的。

## 先看效果

[截图/GIF：展示 tmux 状态栏中多 pane 的 Claude Code 实时状态，包括不同 session、不同 pane 的 ->/-/! 状态]

插件会在 tmux 状态栏独立一行显示所有 pane 的 Claude Code 状态：

```
┌──────────────────────────────────────────────────────────┐
│  project  0.0 ✓   0.1 >   0.2 !                          │  ← 状态栏独立行
├──────────────────┬──────────────────┬────────────────────┤
│ 0:vim            │ 1:claude        │ 2:claude           │
│                  │ (处理中)         │ (等待授权)          │
│                  │                  │                    │
└──────────────────┴──────────────────┴────────────────────┘
```

每个 pane 的状态实时更新，你一眼就能看出：
- **0.0** — 会话空闲（✓）
- **0.1** — 正在处理中（>）
- **0.2** — 正在等待你授权操作（! 红色高亮）

## 解决什么问题

用 tmux + Claude Code 的工作流里，有几个很常见的痛点：

1. **不知道哪个 pane 在忙**：开了 3 个 pane 跑 Claude Code，切来切去才找到正在处理的那个
2. **错过授权时机**：Claude Code 等你授权某个操作，但你没注意到，白白等了好几分钟
3. **多 session 状态混乱**：不同 tmux session 里各有 Claude Code 在跑，全局状态不可见
4. **状态栏被覆盖**：有些方案直接改 `status-right`，把你原来的状态栏配置搞乱

tmux-claude-hooks-status 通过 Claude Code 的 hook 系统，把每个 pane 的状态实时映射到 tmux 状态栏，而且**用独立行显示，不影响你原有的状态栏配置**。

## 状态符号一览

| 状态符号 | 颜色 | 含义 | 触发事件 |
|---------|------|------|---------|
| `-` | 黄色 | 会话空闲 | SessionStart |
| `>` | 黄色 | 处理中 | PreToolUse / PostToolUse / UserPromptSubmit |
| `?` | 黄色 | 等待用户输入 | PreToolUse (AskUserQuestion) |
| `!` | **红色** | 等待授权 | PermissionRequest |
| `✓` | 黄色 | 任务完成 | Stop / StopFailure |
| （清空） | — | 会话结束 | SessionEnd |

> Notification 事件在内部自动分发：权限相关消息映射到 `!`，取消/拒绝回到 `-`，不会直接显示原始通知内容。

### 多 Pane 聚合显示

状态栏会自动聚合当前所有 attached session 的 pane 状态，格式为：

```
session名 窗口.面板 状态  窗口.面板 状态
```

示例：

```
myproject 0.0 ✓  0.1 >    dev 1.0 !
```

其中 `!`（等待授权）会以红色高亮显示，一眼就能看到哪个 pane 在等你操作。

只有 attached（已连接）的 session 才会显示，detached 的 session 不会出现在状态栏中。

## 3 分钟安装

安装非常简单，只需 4 步：

### 前置依赖

```bash
# macOS
brew install tmux jq

# 确认版本（tmux 需要 >= 3.1，bash 需要 >= 4.0）
tmux -V
jq --version
```

### 第 1 步：安装 TPM

如果你已经装了 TPM，跳过这步。

```bash
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
```

### 第 2 步：配置 .tmux.conf

在 `~/.tmux.conf` 中添加：

```tmux
# --- 插件 ---
set -g @plugin 'liuziyuan/tmux-claude-hooks-status'

# TPM 初始化（必须放在最后）
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

就这样。插件会自动完成以下配置：
- 在多行状态栏中添加独立的 Claude 状态行
- 配置 pane 边框显示（pane 编号 + 标题）
- **不会修改你现有的 `status-right` 设置**

### 第 3 步：安装插件

启动或重启 tmux，然后按：

```
prefix + I    # 即 Ctrl+a 松开，再按大写 I
```

TPM 会自动下载并安装所有插件。完成后重载配置：

```
prefix + r
```

### 第 4 步：注册 Claude Code Hooks

```
prefix + C-h
```

这一步会把 hooks 注册到 `~/.claude/settings.json`，让 Claude Code 在状态变化时通知插件。

完成！现在打开 Claude Code 试试，状态栏应该会实时显示状态了。

> 卸载 hooks 很简单：`prefix + C-u`

## 自定义配置

所有配置都在 `.tmux.conf` 中设置：

```bash
# 状态文字颜色
set -g @claude_hooks_status_color "#F1FA8C"

# 各状态图标（可换成你喜欢的）
set -g @claude_hooks_idle_icon "✔"     # 空闲
set -g @claude_hooks_busy_icon "◄▶"    # 处理中
set -g @claude_hooks_auth_icon "⚠"     # 等待授权
```

修改后 `prefix + r` 重载即可生效。

## 技术亮点

如果你关心实现细节，这里有几个有趣的设计：

### 1. 进程树反查 TMUX_PANE

Claude Code 的 hook 子进程不继承 `$TMUX_PANE` 环境变量。插件通过 `ps -o ppid` 向上遍历进程树，找到对应 tmux pane 的 PID，从而将状态绑定到正确的 pane。

### 2. 竞态保护机制

Claude Code 的 hook 是异步的，多个事件可能同时触发。比如 `PermissionRequest` 刚设置了 `!` 状态，紧接着一个延迟的 `PostToolUse` 就把它覆盖成 `>` 了。

插件用**时间戳保护窗口**解决这个问题：设置 `!` 或 `?` 时记录时间戳，保护窗口内的异步 `PostToolUse` 会被直接忽略。同时 watcher 进程会持续监控，如果 `!` 被意外覆盖，会自动恢复。

### 3. 独立状态行，不碰你的配置

插件利用 tmux 的多行 `status-format` 特性，追加一行独立的状态显示行，**完全不动 `status-right`**。你的 powerline、时钟、系统监控等配置都保持原样。

### 4. 幂等设计

无论重载多少次，插件不会重复添加状态行或重复注册 hooks。`prefix + r` 随便按。

## 快捷键速查

| 快捷键 | 功能 |
|--------|------|
| `prefix + C-h` | 安装 Claude Code hooks |
| `prefix + C-u` | 卸载 Claude Code hooks |
| `prefix + I` | TPM 安装所有插件 |
| `prefix + r` | 重载配置 |

> prefix 默认是 `Ctrl+a`（按下松开，再按下一个键）

## 验证安装

```bash
# 手动触发一次 hook 测试
echo '{}' | bash ~/.tmux/plugins/tmux-claude-hooks-status/scripts/tmux-claude-status SessionStart
tmux show-option -g @claude_all_status

# 查看所有 pane 状态
tmux list-panes -a -F "#{window_index}.#{pane_index} #{pane_id} #{@claude_pane_status}"

# 确认 hooks 已注册
jq '.hooks | keys' ~/.claude/settings.json
```

---

**GitHub**: [liuziyuan/tmux-claude-hooks-status](https://github.com/liuziyuan/tmux-claude-hooks-status)

如果你也在用 tmux + Claude Code 的工作流，欢迎试试这个插件。有问题或建议可以直接提 Issue，也欢迎 PR。
