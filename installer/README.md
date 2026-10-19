# tmux-ai-status 安装器

`tmuxclihook` 是 tmux-ai-hooks-status 的交互式 TUI，负责环境侦测/修复、AI CLI 侦测、hooks 装卸修、tmux 集成（`.tmux.conf` 的 `run-shell` 声明校验/修复）、source 管理（生产默认 / 本地开发路径切换），以及完整卸载编排。启动 TUI 本身需要 Node.js 18+；它不能在 Node.js 缺失时自举运行。

## 运行

```bash
# 生产：npm 全局安装，装完即完整可用（scripts/ 与 tmux 入口已打包进包内）
npm install -g tmuxclihook
tmuxclihook

# 按当前安装方式（npm/volta）检查并更新到最新版
tmuxclihook update

# 删除不生效的另一份安装；已是最新时也会执行清理（默认交互确认）
tmuxclihook update --prune

# hooks 健康明细（非交互）：每个 CLI 的完整性、判定真源、注册路径、漂移警告
# 可选参数 claude|codex|opencode 只看一个；exit 1 = 有缺失或漂移
tmuxclihook check

# 查看版本 / 帮助（version、--version、-v 与 help、--help、-h 等价）
tmuxclihook --version
tmuxclihook --help

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

`tmuxclihook update` 会显示当前版本，通过 `npm view tmuxclihook version` 查询最新版；版本相同则不做任何安装（若显式传入 `--prune`，仍会执行一次非生效副本检测与清理）。需要升级时，它按 PATH 上第一个可执行的 `tmuxclihook` 判断当前生效的安装方式：入口位于 `$VOLTA_HOME/bin/`（默认 `~/.volta/bin/`）或 volta 的 packages 镜像内时，只执行 `volta install tmuxclihook@latest`；其余入口（npm 全局、nvm/fnm 等 node 工具链目录）只执行 `npm install -g tmuxclihook@latest`。不会同时写入两套安装。网络查询或安装失败时命令以非零状态退出。

安装完成后会按 PATH 自检实际生效版本。若生效入口不是 volta、自检仍未反映新版，且本机可执行 volta，则补执行一次 `volta install tmuxclihook@latest` 作为兜底并复检；仍不一致时打印警告（不影响退出码）。

升级成功，或版本已是最新且显式传入 `--prune` 时，update 会检查另一套安装（volta packages 镜像或当前 npm 全局 prefix）是否还留有副本。发现副本时：TTY 下询问是否删除（默认不删）；非交互环境只打印警告；`--prune` 跳过询问直接删除。删除前会校验该副本未被任何 hooks 与 `~/.tmux.conf` 引用——任一检查无法确认就保留并提示先重装 hooks。**生效入口永远不删**，清理失败不影响升级结果。也可以手动收敛：卸载不再使用的那份（`npm uninstall -g tmuxclihook` 或 `volta uninstall tmuxclihook`），再从生效入口重新安装 hooks。

升级后无需手动重载 tmux 插件：运行中的 `tmux-ai-monitor` 每 60 tick 对比脚本目录内容指纹，发现文件被替换会自动 `exec` 自身重载新代码（保留同一 PID 与 generation）。`TMUX_AI_MONITOR_RELOAD_DISABLE=1` 可关闭该行为。

## 功能

| 菜单项 | 说明 |
|--------|------|
| 环境检查 | 侦测 tmux(≥3.1) / jq / bash(任意版本) / node(≥18)，显示 `✓ ready`、`✗ missing`、`⚠ outdated`，并在确认后安全修复。检测到 cc-switch（`~/.cc-switch/cc-switch.db`）时追加 sqlite3 项 |
| 侦测 AI CLI | 扫描 Claude Code / Codex / opencode，显示版本、最低版本和 hooks 健康明细（判定真源、缺失原因、注册路径、漂移警告，见下节）；不自动安装或升级 AI CLI。判定全部走 bash 侧 wrapper `check --json`（cc-switch 模式在 bash 内查 sqlite 真源），TUI 只渲染 |
| 安装 hooks | 选工具（claude/codex/opencode/全部）→ 调 `scripts/install-<tool>-hooks.sh`（路径随当前 source 解析） |
| 卸载 hooks | 对称卸载本插件 hooks，保留其他工具注册的 hook |
| 修复 hooks | 完整性检查 → 缺失则重装 |
| tmux 集成 | 校验 `~/.tmux.conf` 是否已有指向当前 source 的 `run-shell` 声明；缺失则追加，路径过期（例如切换过 source）则原地替换，随后 `tmux source-file` 重载；不依赖 TPM 软链（历史遗留软链仅作提示，清理走「完整卸载插件」） |
| source 管理 | 查看当前生效 source（来源 + 失效警告）；设置本地仓库路径用于开发调试；清除持久化配置恢复默认 |
| 完整卸载插件 | 停止 Codex monitor、清除聚合状态 `@ai_all_status`、清理历史遗留软链（不删仓库）；`.tmux.conf` 删声明与 `tmux kill-server` 因破坏性仅打印手动指引 |

### hooks 健康明细与漂移收敛

`tmuxclihook check`（子命令）与 TUI「侦测 AI CLI」共用同一份 bash 侧明细：每个 wrapper 的 `check --json` 模式输出单行 JSON（status / 判定真源 mode / 逐事件 registered+alive / opencode plugin 结构指纹 / suppress 标记 / drift）。默认 `check`（无 `--json`）输出逐字节不变（`ok`/`missing` + exit code），TUI 与 tmux 自修复的既有契约不受影响。

**漂移（drift）**：hooks 指向其他安装源但脚本仍存活（典型场景：本地调试切 source 后、volta 换路径后旧包仍可用）。此时功能未坏、check 仍判 `ok`，但 `tmuxclihook check` 与 TUI 会给出 ⚠ 警告并列出旧路径。漂移参照系是**执行中的 wrapper 自身路径**——`tmuxclihook`/TUI 经当前 source 调 wrapper，警告即「已装 hooks 不是当前 source 写的」。

**发现漂移后的收敛（策略不对称）**：

| 配置 | 收敛代价 | 方式 |
|------|---------|------|
| Claude Code hooks | 无（install 幂等强收敛） | TUI 选择即收敛 |
| Codex hooks | 重写 `hooks.json` 使 `trusted_hash` 失效，需重新 Trust all | TUI 显式确认后收敛（`TMUX_AI_FORCE_INSTALL=1` 旁路 no-op 门禁） |
| opencode plugin | 无信任代价（整文件重写） | TUI 确认后收敛 |
| `.tmux.conf` 声明 | 无 | 复用「tmux 集成」的原地替换 + 重载 |

非交互场景下 `tmuxclihook check` 只报告并 exit 1，收敛动作需回 TUI（或手动跑对应 `install-<tool>-hooks.sh`；codex 记得带 `TMUX_AI_FORCE_INSTALL=1`）。

### Esc 导航

clack 0.7 只把 ctrl+c 映射为取消（Esc 默认无效果），安装器在 TUI 内把 Esc 转译为合成取消：**主菜单 Esc 退出**、子菜单 Esc 返回主菜单、确认/输入框 Esc 取消。spinner 期间 Esc 静默（避免误触硬退出）；ctrl+c 行为不变。

### cc-switch 模式（Claude Code）

检测到 `~/.cc-switch/cc-switch.db` 时，Claude Code hooks 的装/卸/修/状态检查改走 cc-switch 的共享配置。真源位置随 cc-switch 版本自动切换（判定规则与 cc-switch CLI 的 `detectSharedConfigMode` 一致，`CC_SWITCH_SHARED_SOURCE=live|legacy` 可显式覆盖）：

| cc-switch 版本 | 判定 | hooks 真源 / 写入目标 |
|---|---|---|
| 4.0.2+（live） | `PRAGMA user_version >= 20` | `~/.claude/settings.json` |
| 旧版（legacy） | `user_version < 20` 或读不到 | db `settings` 表 `common_config_claude` |

live 模式以 `~/.claude/settings.json` 为共享配置真源（cc-switch 4.0.2 起不再读库里的 `common_config_claude`），写入用与文件模式相同的原子合并，他人 hook 与配置其他字段保留；legacy 模式用与 cc-switch 自身一致的 `json_patch` 更新 db。注意：cc-switch GUI 运行中会把内存缓存写回真源，安装前建议先退出 GUI（脚本会警告）；legacy 模式下不经 `switch` 直接运行的 `claude` 读不到 db 里的 hooks。

**codex / opencode 的 cc-switch 真源**

- **codex**：`switch` 为每个 provider 创建独立 `CODEX_HOME`（`~/.cc-switch/instances/codex/<providerId>`），并把 `~/.codex/hooks.json` 符号链接进实例，因此插件写默认（或 `$CODEX_HOME`）下的 `hooks.json` 即被所有实例共享。但 `[hooks.state]` 信任记录在实例自己的 `config.toml` 里、cc-switch 不复制——**每个新 provider 实例首次启动需在 codex TUI 内 Trust all 一次**，否则 hooks 不执行（trusted_hash 无法在 bash 侧复现，插件不预写）。
- **opencode**：cc-switch 对它是 additive live config（无 per-provider 实例目录），provider 条目直接写进配置目录的 `opencode.json(c)`。插件目录解析为 `OPENCODE_CONFIG_DIR` > cc-switch `settings.json` 的 `opencodeConfigDir` > `${XDG_CONFIG_HOME:-~/.config}/opencode`；旧版 cc-switch 无该键时自动回落默认目录。

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
