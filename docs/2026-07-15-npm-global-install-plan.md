# npm 全局安装完整可用 + 本地调试隔离 — 实施计划

## 背景 / 目的

`tmuxclihook` 已发布到 npm（当前 0.1.1）。但发布的包里只有 `installer/bin` + `installer/src`，
不含仓库根的 `scripts/`（hooks 安装逻辑、adapters）与 `tmux-ai-hooks-status.tmux`（tmux 入口）。
结果：`npm i -g tmuxclihook` 或 `npx tmuxclihook` 运行后，只有「环境检查」「侦测 AI CLI」两项能用，
hooks 安装/卸载/修复、tmux 集成全部因为找不到 `scripts/` 而失败。

**目标**：`npm i -g tmuxclihook` 装完即完整可用（含 hooks 安装、tmux 状态栏集成），
同时保留「指定本地仓库路径进行开发调试，不影响全局生产版本」的能力。

## 采用的架构

### 1. 打包：scripts 随 npm 包分发

`installer/package.json` 保持原位不挪動（避免大范围目录重构）。新增 prepack 构建步骤，
在 `npm publish` / `npm pack` 时把仓库根的 `scripts/` 目录与 `tmux-ai-hooks-status.tmux`
**复制**进 `installer/` 一起打包（保留可执行位），`postpack` 再清理，保持仓库工作区干净。

```
installer/
  scripts/                    ← prepack 时从 ../scripts 复制进来，postpack 清理
  tmux-ai-hooks-status.tmux   ← prepack 时从 ../tmux-ai-hooks-status.tmux 复制进来
  bin/cli.js
  src/
  tools/
    prepack-bundle.js         ← 新增：复制
    prepack-clean.js          ← 新增：清理
```

### 2. 无软链加载：直接 run-shell 全局包路径

不再依赖 TPM 风格的 `~/.tmux/plugins/` 软链。tmux 插件本质就是 `source`/`run-shell`
一个脚本，全局安装后包路径固定，`.tmux.conf` 直接一行：

```tmux
run-shell '<REPO_ROOT>/tmux-ai-hooks-status.tmux'
```

TUI 负责检测 `.tmux.conf` 是否已包含该行，缺失则追加并 `tmux source-file` 重载。
`prefix + I` 改为直接拉起全局命令 `tmuxclihook`（而非 `new-window -c installer/ node bin/cli.js`）。

### 3. Source 三级解析：全局默认 + 本地调试覆盖（关键机制）

新增 `installer/src/source.js`，统一解析「当前生效的 scripts/tmux 入口来自哪里」：

```
优先级（从高到低）：
1. 环境变量  TMUXCLIHOOK_SOURCE=<绝对路径>          ← 一次性/CI 场景
2. 配置文件  ~/.config/tmuxclihook/config.json       ← 持久化选择，TUI「source 管理」菜单写入
   { "source": "<绝对路径>" }
3. 包内自带  installer/scripts（prepack 复制产物）    ← 生产默认，自包含
4. 开发回落  仓库根 scripts（cd installer && npm start 时探测到 ../scripts 存在）
```

`adapters-meta.js` 的 `REPO_ROOT` / `SCRIPTS_DIR` 改由 `resolveSource()` 提供，
不再是写死的相对路径计算。所有下游（hooks installer 路径、`.tmux.conf` run-shell 路径、
tmux 软链兼容清理）自动跟随当前 source。

**使用场景**：
- 生产：什么都不设 → 用包内自带 scripts，全局装完就能用。
- 调试新功能：`tmuxclihook source set ~/work/home/tmux-claude-hooks-status`
  （或环境变量 `TMUXCLIHOOK_SOURCE=...`）→ 之后装 hooks / 写 `.tmux.conf` 都指向本地仓库，
  改代码即时生效，不用重新 `npm publish`。
- 切回生产：`tmuxclihook source clear`。

TUI 启动时（`main()`）打印当前生效 source，避免用户忘记自己切换过。

### 4. 为什么软链不能提供隔离（背景说明，写入文档供后续维护者理解）

软链只决定 tmux 从哪个路径加载脚本，不解决「本地调试版与 npm 生产版冲突」问题。
真正的冲突源是三个全局单例，和有没有软链无关：

| 单例资源 | 位置 | 冲突表现 |
|---|---|---|
| tmux server 状态 | `@ai_*` options、status-format 行、session hooks、monitor | 同一 server 只有一份，本地/全局都写 → 互相覆盖 |
| hooks 配置 | `~/.claude/settings.json` 等（单文件，合并式安装） | 谁后装谁的 command 路径生效 |
| 临时状态/日志 | `/tmp/ai-status`、`/tmp/tmux-ai-status.log` | 共享，互相干扰 |

`source` 机制解决的是「hooks 配置指向谁 / tmux 加载谁」，即表格第 2 行；
如果需要在**同一个 tmux server 里同时跑生产与调试两份**（而非切换），
仍需独立 tmux socket（`tmux -L dev`）+ 环境变量隔离，这已超出本次改动范围，
不在当前 plan 内实现，仅记录以备后续需要时参考：

```bash
# 高阶备忘：真正并行隔离需独立 socket + 已内置的环境变量覆盖
TMUX_AI_STATUS_DIR=/tmp/ai-status-dev CLAUDE_CONFIG_DIR=~/.claude-dev tmux -L dev
```

（`TMUX_AI_STATUS_DIR` / `CLAUDE_CONFIG_DIR` / `CODEX_HOME` 已在现有 `lib-tmux-ai-status.sh`
与各 adapter 中支持；日志路径 `/tmp/tmux-ai-status.log` 硬编码不做覆盖——已确认共享可接受。）

## 改动清单

### A. 打包
- **A0** 新增 `installer/src/source.js`：`resolveSource()` 三级解析 + `setSource()` / `clearSource()` / `showSource()`，配置文件 `~/.config/tmuxclihook/config.json`。
- **A1** `installer/src/adapters-meta.js`：`REPO_ROOT` / `SCRIPTS_DIR` 改由 `source.js` 提供。
- **A2** 新增 `installer/tools/prepack-bundle.js`（`fs.cpSync` 复制 `../scripts`、`../tmux-ai-hooks-status.tmux`，保留 mode）与 `prepack-clean.js`（发布后清理）。
- **A3** `installer/package.json`：version `0.1.1` → `0.2.0`；`files` 加 `"scripts"`、`"tmux-ai-hooks-status.tmux"`；`scripts` 加 `"prepack"` / `"postpack"`。
- **A4** 根 `.gitignore` 追加 `installer/scripts/`、`installer/tmux-ai-hooks-status.tmux`。

### B. 无软链加载
- **B5** `installer/src/tmuxconf.js`：写入声明从 `set -g @plugin '...'` 改为 `run-shell '<当前 source 的 tmux 入口绝对路径>'`。
- **B6** `installer/bin/cli.js`：
  - 「tmux 软链校验」菜单改为「tmux 集成」（校验/追加 run-shell 声明）；
  - 新增「source 管理」菜单项（查看当前 source / 设置本地路径 / 清除恢复默认）；
  - 启动时打印当前生效 source。
- **B7** `installer/src/symlink.js`：移除软链**创建**主路径（仅保留 `checkTmuxConf` 供 B5/B6 复用；软链检测/清理逻辑降级为兼容旧安装）。

### C. tmux 入口
- **C8** `tmux-ai-hooks-status.tmux`：`prefix + I` 绑定从 `new-window -c installer node bin/cli.js` 改为优先调用全局命令 `tmuxclihook`，找不到则回落当前布局的 `node bin/cli.js`。

### D. 卸载
- **D9** `installer/src/purge.js`：完整卸载增加移除 `.tmux.conf` 中 run-shell 声明的指引/操作；`removeSymlinks` 保留作为清理历史遗留软链的兼容路径。

### E. CI / 文档
- **E10** `.github/workflows/publish-installer.yml`：`paths` 增加 `scripts/**`、`tmux-ai-hooks-status.tmux`（这些改动也应触发重新发布）。
- **E11** 根 `README.md` / `README_ZH.md` / `installer/README.md`：主推 `npm i -g tmuxclihook`；说明 `source` 用法（生产默认 / 本地调试切换）；标注 `npx` 局限（临时缓存路径不适合持久 hooks）。

### F. 验证
- `cd installer && npm pack --dry-run` → 确认 `scripts/**`（含 `adapters/`、`lib-*`、`tmux-ai-*`）与 tmux 入口入包、可执行位保留。
- `npm i -g ./tmuxclihook-0.2.0.tgz` → 运行 `tmuxclihook` 安装 claude hooks → 检查 `~/.claude/settings.json` 的 command 指向全局包内 `scripts/tmux-ai-status` 且可执行。
- `TMUXCLIHOOK_SOURCE=<仓库路径>` 或 `tmuxclihook source set <仓库路径>` → 再次安装 hooks / 写 `.tmux.conf` → 确认路径切换到本地仓库。
- `.tmux.conf` 写入 run-shell 声明 → `tmux source-file` → 状态栏出现，`prefix + I` 能拉起 `tmuxclihook`。
- 开发回归：`cd installer && npm start`（不设 source）→ 自动回落仓库根 `scripts`，行为与改动前一致。

## 已知残留风险（无法靠代码消除，需文档标注）

1. **绝对路径绑定安装位置**：hooks 的 command 与 `.tmux.conf` 的 run-shell 都写死当前 source 的绝对路径。
   `nvm` 切换 node 版本、更改 npm prefix、`npm uninstall -g` 都会让已写入的路径悬空
   （hooks 调不存在的脚本、状态栏加载失败）。缓解：TUI 提供「修复」入口，检测路径失效后按当前 source 重写。
2. **`npx tmuxclihook` 不适用于持久化操作**：临时缓存目录用完即清，hooks/软链一旦写入必然悬空。
   CLI 检测运行路径含 `/_npx/` 时给出明确警告，文档标注仅支持全局安装做完整操作。
3. **Source 是整机切换，非并行共存**：同一时刻只有一个生效 source。若要在同一 tmux server
   内同时运行生产与调试两份，需要独立 tmux socket + 环境变量隔离（见上文「高阶备忘」），
   不在本次实现范围内。
4. **切换 source 后需要手动重新执行安装动作**：改 source 本身不会自动重写已经写入的
   hooks 配置或 `.tmux.conf`，需要用户在切换后主动跑一遍「安装 hooks」/「tmux 集成」使路径生效。

## 已确认的决策

- Scripts 采用「包内自带 + source 环境变量/配置文件覆盖」，不采用 clone 到 `~/.tmux/plugins` 的 bootstrapper 方案。
- 软链创建功能整体降级，仅保留卸载时清理历史遗留软链的兼容路径。
- `prefix + I` 绑定改为优先调用全局 `tmuxclihook` 命令。
- 日志路径 `/tmp/tmux-ai-status.log` 不加环境变量覆盖，生产/调试共享可接受。
