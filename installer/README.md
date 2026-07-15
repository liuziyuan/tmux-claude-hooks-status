# tmux-ai-status 安装器

`tmuxclihook` 是 tmux-ai-hooks-status 的交互式 TUI，负责环境侦测/修复、AI CLI 侦测、hooks 装卸修、tmux 集成（`.tmux.conf` 的 `run-shell` 声明校验/修复）、source 管理（生产默认 / 本地开发路径切换），以及完整卸载编排。启动 TUI 本身需要 Node.js 18+；它不能在 Node.js 缺失时自举运行。

## 运行

```bash
# 生产：npm 全局安装，装完即完整可用（scripts/ 与 tmux 入口已打包进包内）
npm install -g tmuxclihook
tmuxclihook

# 插件已经载入 tmux 后
prefix + I

# npm 入口（仅环境与 AI CLI 检查，临时缓存目录不适合持久化的 hooks/tmux 写入）
npx tmuxclihook

# 本地开发：从仓库副本运行
cd installer
npm install
npm start
```

hooks 安装、tmux 集成写入的路径由「source」决定：环境变量 `TMUXCLIHOOK_SOURCE` > 持久化配置 `~/.config/tmuxclihook/config.json`（TUI「source 管理」菜单写入）> 包内自带 scripts/（生产默认）> 仓库根 scripts/（`cd installer && npm start` 时的开发回落）。见下方「source 管理」一节。

## 功能

| 菜单项 | 说明 |
|--------|------|
| 环境检查 | 侦测 tmux(≥3.1) / jq / bash(任意版本) / node(≥18)，显示 `✓ ready`、`✗ missing`、`⚠ outdated`，并在确认后安全修复 |
| 侦测 AI CLI | 扫描 Claude Code / Codex / opencode，显示版本、最低版本和 hooks 状态；不自动安装或升级 AI CLI |
| 安装 hooks | 选工具（claude/codex/opencode/全部）→ 调 `scripts/install-<tool>-hooks.sh`（路径随当前 source 解析） |
| 卸载 hooks | 对称卸载本插件 hooks，保留其他工具注册的 hook |
| 修复 hooks | 完整性检查 → 缺失则重装 |
| tmux 集成 | 校验 `~/.tmux.conf` 是否已有指向当前 source 的 `run-shell` 声明；缺失则追加，路径过期（例如切换过 source）则原地替换，随后 `tmux source-file` 重载；不依赖 TPM 软链（历史遗留软链仅作提示，清理走「完整卸载插件」） |
| source 管理 | 查看当前生效 source（来源 + 失效警告）；设置本地仓库路径用于开发调试；清除持久化配置恢复默认 |
| 完整卸载插件 | 停止 Codex monitor、清除聚合状态 `@ai_all_status`、清理历史遗留软链（不删仓库）；`.tmux.conf` 删声明与 `tmux kill-server` 因破坏性仅打印手动指引 |

## Source 管理（生产默认 / 本地调试切换）

`npm i -g` 装完后，hooks 安装与 tmux 集成默认使用包内自带的 `scripts/`（由 `npm publish` 前的 `prepack` 步骤从仓库根复制打包进来，见「架构」一节），开箱即用，无需仓库 checkout。

调试本仓库的新功能时，无需重新 `npm publish`，把 source 指向本地 checkout 即可让改动立即生效：

```bash
# 一次性：环境变量优先级最高
TMUXCLIHOOK_SOURCE=~/work/home/tmux-claude-hooks-status tmuxclihook

# 持久化：写入 ~/.config/tmuxclihook/config.json，之后每次运行 tmuxclihook 都生效
# （TUI 内「source 管理 → 设置本地开发路径」，或直接编辑该文件）
```

指向的路径必须包含 `scripts/` 子目录才会被采纳，否则该级解析会被跳过并给出警告，回落到下一级（配置文件 → 包内自带 → 仓库根）。

**切换 source 不会自动重写已经写入的 hooks 配置或 `.tmux.conf`**——两者记录的是绝对路径快照，切换后需要重新执行一次「安装 hooks」与「tmux 集成」，新路径才会生效。在 TUI「source 管理」菜单选择"清除并恢复默认"可删除持久化配置，回到包内自带/仓库回落，同样需要重新执行安装动作才会生效。

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

`src/adapters-meta.js` 的 `REPO_ROOT`/`SCRIPTS_DIR`/`TMUX_ENTRY` 不再是写死的相对路径，而是委托 `src/source.js` 的三级解析（`resolveSource()`）。这些导出是 ES module 的 live binding：`refreshSource()` 重新赋值后，所有下游 `import { REPO_ROOT } ...` 的调用方自动看到新值，无需重启进程——这是 TUI 内「source 管理」切换路径后立即生效的机制。

npm 打包时（`npm publish` / `npm pack`），`package.json` 的 `prepack` 钩子（`tools/prepack-bundle.js`）把仓库根的 `scripts/` 与 `tmux-ai-hooks-status.tmux` 复制进 `installer/`（保留可执行位，排除隐藏文件），使发布的包自包含；`postpack` 钩子（`tools/prepack-clean.js`）随后清理这些复制产物，保持仓库工作区干净（复制产物已在根 `.gitignore` 中忽略，不会误入 git）。

tmux 集成不再依赖 TPM 软链创建：`src/tmuxconf.js` 的 `ensureTmuxIntegration()` 直接在 `~/.tmux.conf` 写入/替换一行 `run-shell '<TMUX_ENTRY>'`；`src/symlink.js` 仅保留软链**检测**（`checkSymlink()`，用于提示历史遗留安装可清理）与 `.tmux.conf` 集成状态检测（`checkTmuxConf()`）。

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

测试通过依赖注入模拟 Homebrew、文件系统路径（`source.js`/`tmuxconf.js` 均支持注入 `configFile`/`path` 等参数），不会真的执行安装、升级或网络操作，也不会触碰真实的 `~/.tmux.conf` / `~/.config/tmuxclihook/`。

## 发布（npm）

由 GitHub Actions 自动发布：push 到 `main` 且 `installer/package.json` 的 `version` 比 npm 上已发布版本新时（改动涉及 `installer/**`、`scripts/**` 或根 `tmux-ai-hooks-status.tmux` 均会触发工作流），`.github/workflows/publish-installer.yml` 自动执行 `npm publish --provenance --access public`（`prepack`/`postpack` 自动打包/清理仓库根脚本）、打 `installer-v<version>` tag 并创建 Release。

发布前置：仓库 Settings → Secrets 配置 `NPM_TOKEN`（npm automation token）。手动发布版本：修改 `package.json` 的 `version` 后提交并 push 到 main。
