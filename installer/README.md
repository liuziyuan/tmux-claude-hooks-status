# tmux-ai-status 安装器

交互式 TUI，承接 tmux-ai-hooks-status 插件的安装前置环节：环境侦测、AI CLI 侦测、hooks 装/卸/修、TPM 软链校验。

## 运行

```bash
# 仓库内
cd installer && npm install && node bin/cli.js

# 或 tmux 内快捷键
prefix + I
```

## 功能

| 菜单项 | 说明 |
|--------|------|
| 环境检查 | 侦测 tmux(≥3.1) / jq / bash(≥4.0) / node(≥18)，逐项 ✓/✗；缺失可 brew 代装（需确认） |
| 侦测 AI CLI | 扫 claude / codex，显示版本 + 是否满足最低要求（codex ≥ 0.144）+ hooks 状态 |
| 安装 hooks | 选工具（claude/codex/全部）→ 调 `scripts/install-<tool>-hooks.sh` |
| 卸载 hooks | 对称卸载，保留他人注册的 hook |
| 修复 hooks | 完整性检查 → 缺失则重装 |
| tmux 软链 | 校验 `~/.tmux/plugins/` 是否有指向本仓库的软链（含旧名），缺失可创建 |

## 架构

TUI 不重实现 bash 逻辑——hooks 装/卸经 `execa` 调薄 wrapper `scripts/install-<tool>-hooks.sh`（内部走 `scripts/adapters/<tool>.sh`）。工具元数据（bin/minVersion/hooksFile）在 `src/adapters-meta.js`，与 bash adapter 一一对应。

新增 CLI：`src/adapters-meta.js` 加一条 + 加对应 bash adapter/wrapper。

```
installer/
  bin/cli.js            @clack/prompts 主菜单
  src/
    adapters-meta.js    工具元数据表 + 仓库路径定位
    detect.js           环境 + CLI 侦测
    env.js              brew 代装
    hooks.js            调 bash wrapper 装/卸/修
    symlink.js          TPM 软链校验/创建
```
