# tmux-ai-status 安装器

`tmuxclihook` 是 tmux-ai-hooks-status 的交互式 TUI，负责环境侦测/修复、AI CLI 侦测、hooks 装卸修、TPM 软链校验/创建，以及完整卸载编排。启动 TUI 本身需要 Node.js 18+；它不能在 Node.js 缺失时自举运行。

## 运行

```bash
# 完整功能：从仓库副本运行
cd installer
npm install
npm start

# 插件已经载入 tmux 后
prefix + I

# npm 入口（环境与 AI CLI 检查）
npx tmuxclihook
```

hooks 和 tmux 软链操作依赖仓库根目录中的 `scripts/` 与插件入口文件。npm 包当前适合独立运行环境/CLI 检查；完整安装操作应从仓库副本或 `prefix + I` 启动。

## 功能

| 菜单项 | 说明 |
|--------|------|
| 环境检查 | 侦测 tmux(≥3.1) / jq / bash(任意版本) / node(≥18)，显示 `✓ ready`、`✗ missing`、`⚠ outdated`，并在确认后安全修复 |
| 侦测 AI CLI | 扫描 Claude Code / Codex / opencode，显示版本、最低版本和 hooks 状态；不自动安装或升级 AI CLI |
| 安装 hooks | 选工具（claude/codex/opencode/全部）→ 调 `scripts/install-<tool>-hooks.sh` |
| 卸载 hooks | 对称卸载本插件 hooks，保留其他工具注册的 hook |
| 修复 hooks | 完整性检查 → 缺失则重装 |
| tmux 软链 | 校验 `~/.tmux/plugins/` 是否有指向本仓库的软链（含旧名），缺失可创建；创建后若 `~/.tmux.conf` 未声明插件，可选追加 `@plugin` 并 `tmux source-file` 重载 |
| 完整卸载插件 | 停止 Codex monitor、清除聚合状态 `@ai_all_status`、删除插件软链（含旧名，不删仓库）；`.tmux.conf` 删声明与 `tmux kill-server` 因破坏性仅打印手动指引 |

## 环境自动修复规则

Doctor 只通过 Homebrew 执行明确且可验证的操作：

- 缺失依赖：可选择 `brew install <formula>`；
- 版本过旧且 formula 已由 Homebrew 管理：可选择 `brew upgrade <formula>`；
- 版本过旧但不是 Homebrew 管理：只显示手动升级建议；
- 未检测到 Homebrew：只显示手动建议，不自动安装 Homebrew；
- bash 已存在即视为满足要求，不主动升级 macOS 自带 bash；
- Claude Code / Codex CLI 始终只检测，不自动安装或升级；
- 单项修复失败不会阻止后续项目，执行后自动重新检查全部环境依赖。

## 架构

TUI 不重实现 bash hooks 逻辑——hooks 装/卸经 `execa` 调用薄 wrapper `scripts/install-<tool>-hooks.sh`（内部走 `scripts/adapters/<tool>.sh`）。工具元数据（bin/minVersion/hooksFile）在 `src/adapters-meta.js`，与 bash adapter 一一对应。

环境职责分离：

- `src/detect.js`：只探测并分类 `ready` / `missing` / `outdated`；
- `src/env.js`：检查 Homebrew 所有权、生成 install/upgrade/manual 计划并执行白名单动作；
- `bin/cli.js`：确认选择、逐项执行、报告失败并复检。

新增 AI CLI：在 `src/adapters-meta.js` 加一条元数据，并增加对应 bash adapter/wrapper。

## 开发与测试

```bash
npm run check
npm test
```

测试通过依赖注入模拟 Homebrew，不会真的执行安装、升级或网络操作。

## 发布（npm）

由 GitHub Actions 自动发布：push 到 `main` 且 `installer/package.json` 的 `version` 比 npm 上已发布版本新时，`.github/workflows/publish-installer.yml` 自动执行 `npm publish --provenance --access public`、打 `installer-v<version>` tag 并创建 Release。

发布前置：仓库 Settings → Secrets 配置 `NPM_TOKEN`（npm automation token）。手动发布版本：修改 `package.json` 的 `version` 后提交并 push 到 main。
