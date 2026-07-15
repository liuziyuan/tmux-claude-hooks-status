# tmux-ai-hooks-status 卸载兼容入口

> 本文件保留是为了兼容已有 raw GitHub URL、无 TTY 环境和故障恢复。日常 hooks 卸载请优先使用交互式 TUI。

## 推荐：通过 TUI 卸载 Hooks

在已加载插件的 tmux 中按：

```text
prefix + I
```

或者从仓库运行：

```bash
cd installer
npm start
```

选择 **卸载 hooks**，再选择 Claude Code、Codex 或全部。该操作只移除本插件注册的 hooks，保留其他工具的 hooks。

## 无 TTY：卸载 Hooks

在仓库根目录执行：

```bash
bash scripts/install-claude-hooks.sh uninstall
bash scripts/install-codex-hooks.sh uninstall
```

## 完整移除插件

TUI 当前管理 hooks，不会擅自删除用户的 tmux 配置或仓库。完成 hooks 卸载后：

1. 从 `~/.tmux.conf` 删除本插件声明：

   ```tmux
   set -g @plugin 'tmux-ai-hooks-status'
   ```

   旧配置中如果使用 `tmux-claude-hooks-status`，也一并删除对应声明。

2. 停止 Codex lifecycle monitor，并清除聚合状态：

   ```bash
   scripts/tmux-ai-monitor stop 2>/dev/null || true
   tmux set-option -gu @ai_all_status 2>/dev/null || true
   ```

3. 删除插件软链（不会删除实际仓库）：

   ```bash
   rm -f ~/.tmux/plugins/tmux-ai-hooks-status
   rm -f ~/.tmux/plugins/tmux-claude-hooks-status
   ```

4. 重新启动 tmux server，使插件注册的状态行、hooks 和按键完全卸载：

   ```bash
   tmux kill-server
   ```

   `tmux kill-server` 会关闭当前 tmux 中的所有 session；请先保存工作。如果不希望立即关闭，删除配置后可等到下次自然重启 tmux 时生效。

实际仓库目录由用户自行决定是否删除。本卸载流程不会自动删除仓库或其他工具配置。
