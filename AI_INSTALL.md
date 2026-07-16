# tmux-ai-hooks-status 安装兼容入口

> 本文件保留是为了兼容已有 raw GitHub URL 和 AI agent 工作流。新的主安装入口是仓库内的交互式命令行工具，而不是让 AI 逐段执行一份大型安装脚本。

## 前置条件

交互式 TUI 无法给自己装运行时，运行它*之前*需先具备：

- **Node.js ≥ 18** —— 运行 TUI（`npm start` / `npm install -g tmuxclihook`）的前提；缺失请先自行安装（如 `brew install node`，或 nvm/nodenv）。
- **Homebrew**（macOS，推荐）—— TUI 的环境 Doctor 只经 Homebrew 修复依赖；无 Homebrew 时只给手动建议。
- 运行依赖 **tmux ≥ 3.1** 与 **jq** 可由 Doctor 代装（需勾选），或 `brew install tmux jq`。

Doctor 从不静默安装：只对勾选项动作、只走 Homebrew，不自动装 Homebrew，也不自动安装/升级 AI CLI。

## 推荐：交互式 TUI

如果仓库尚未下载（clone 到任意目录即可，安装器自行从自身位置推导仓库根）：

```bash
git clone https://github.com/liuziyuan/tmux-claude-hooks-status.git
cd tmux-claude-hooks-status/installer
npm install
npm start
```

在 TUI 中依次使用：

1. **环境检查**：检测并按需修复 tmux、jq、bash、Node.js；
2. **tmux 软链校验**：创建指向本仓库的插件软链，并可按需向 `~/.tmux.conf` 追加 `@plugin` 声明并重载；
3. **侦测 AI CLI**：查看 Claude Code / Codex / opencode 版本与 hooks 状态；
4. **安装 hooks**：安装 Claude Code、Codex、opencode 或全部 hooks。

插件载入 tmux 后，可以直接按：

```text
prefix + I
```

环境 Doctor 仅安装缺失的 Homebrew formula，或升级确认由 Homebrew 管理的过旧 formula。它不会安装 Homebrew、不会修改非 Homebrew 管理的软件，也不会自动安装或升级 Claude Code / Codex CLI；修复后会自动复检。

`npx tmuxclihook` 可独立运行环境与 AI CLI 检查。完整 hooks/软链操作需要包含根目录 `scripts/` 的仓库副本。

## 无 TTY / 故障恢复

以下步骤仅在无法启动 TUI 时使用；正常安装请用 `prefix + I` 或 `npm start`。在仓库根目录执行最小安装流程：

```bash
# 必需环境（macOS/Homebrew 示例）
brew install tmux jq

# 安装 hooks（对每个已安装的 AI CLI 运行对应 install-<tool>-hooks.sh）
bash scripts/install-claude-hooks.sh
bash scripts/install-codex-hooks.sh
bash scripts/install-opencode-hooks.sh
```

然后在 `~/.tmux.conf` 中集成插件（与 `README.md` 一致，任选其一）：

**推荐：`run-shell` 直连（无需 TPM 软链）**，把下面的绝对路径换成本仓库根目录：

```tmux
run-shell '<仓库绝对路径>/tmux-ai-hooks-status.tmux'
```

**备选：TPM**，先把仓库 clone 到 `~/.tmux/plugins/tmux-claude-hooks-status`，再声明：

```tmux
set -g @plugin 'liuziyuan/tmux-claude-hooks-status'
set -g @plugin 'tmux-plugins/tpm'
run '~/.tmux/plugins/tpm/tpm'
```

重新加载 tmux 配置：

```bash
tmux source-file ~/.tmux.conf
```

完整配置说明和验证步骤见 `README.md` / `README_ZH.md`。
