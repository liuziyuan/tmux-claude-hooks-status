# tmux-ai-hooks-status 安装兼容入口

> 本文件保留是为了兼容已有 raw GitHub URL 和 AI agent 工作流。新的主安装入口是仓库内的交互式命令行工具，而不是让 AI 逐段执行一份大型安装脚本。

## 推荐：交互式 TUI

如果仓库尚未下载：

```bash
git clone https://github.com/liuziyuan/tmux-claude-hooks-status.git ~/.local/share/tmux-ai-hooks-status
cd ~/.local/share/tmux-ai-hooks-status/installer
npm install
npm start
```

在 TUI 中依次使用：

1. **环境检查**：检测并按需修复 tmux、jq、bash、Node.js；
2. **tmux 软链校验**：创建指向本仓库的插件软链；
3. **侦测 AI CLI**：查看 Claude Code / Codex 版本与 hooks 状态；
4. **安装 hooks**：安装 Claude Code、Codex 或全部 hooks。

插件载入 tmux 后，可以直接按：

```text
prefix + I
```

环境 Doctor 仅安装缺失的 Homebrew formula，或升级确认由 Homebrew 管理的过旧 formula。它不会安装 Homebrew、不会修改非 Homebrew 管理的软件，也不会自动安装或升级 Claude Code / Codex CLI；修复后会自动复检。

`npx tmuxclihook` 可独立运行环境与 AI CLI 检查。完整 hooks/软链操作需要包含根目录 `scripts/` 的仓库副本。

## 无 TTY / 故障恢复

无法启动 TUI 时，可在仓库根目录执行最小安装流程：

```bash
# 必需环境（macOS/Homebrew 示例）
brew install tmux jq

# 创建 TPM 可发现的插件软链
mkdir -p ~/.tmux/plugins
ln -sfn "$PWD" ~/.tmux/plugins/tmux-ai-hooks-status

# 安装 hooks（只运行已安装的 AI CLI 对应项）
bash scripts/install-claude-hooks.sh
bash scripts/install-codex-hooks.sh
```

然后确保 `~/.tmux.conf` 包含：

```tmux
set -g @plugin 'tmux-ai-hooks-status'
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

重新加载 tmux 配置：

```bash
tmux source-file ~/.tmux.conf
```

完整配置说明和验证步骤见 `README.md` / `README_ZH.md`。
