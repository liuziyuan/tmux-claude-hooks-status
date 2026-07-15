#!/usr/bin/env node
// prepack-bundle.js — npm publish/pack 前，把仓库根的 scripts/ 与 tmux 入口复制进 installer/
//
// 由 package.json 的 "prepack" 钩子触发。复制产物随包发布，使 `npm i -g tmuxclihook`
// 全局安装后自包含（无需依赖仓库 checkout）。产物在 "postpack" 阶段由
// prepack-clean.js 删除，保持仓库工作区（installer/ 本身）干净、不入 git
// （见根 .gitignore）。
//
// 幂等：每次运行都先删除旧的复制产物再重新复制，不会因中途失败留下半份文件。

import { existsSync, rmSync, cpSync, statSync } from 'node:fs';
import { dirname, join, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const INSTALLER_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(INSTALLER_DIR, '..');

const SRC_SCRIPTS = join(REPO_ROOT, 'scripts');
const DEST_SCRIPTS = join(INSTALLER_DIR, 'scripts');
const SRC_TMUX_ENTRY = join(REPO_ROOT, 'tmux-ai-hooks-status.tmux');
const DEST_TMUX_ENTRY = join(INSTALLER_DIR, 'tmux-ai-hooks-status.tmux');

function fail(msg) {
  console.error(`[prepack-bundle] ERROR: ${msg}`);
  process.exit(1);
}

if (!existsSync(SRC_SCRIPTS)) {
  fail(
    `未找到 ${SRC_SCRIPTS}。prepack 必须从完整仓库 checkout 内运行` +
    '（例如 CI 的 actions/checkout，或本地 git clone），不能从已发布的 npm 包内重新打包。'
  );
}
if (!existsSync(SRC_TMUX_ENTRY)) {
  fail(`未找到 ${SRC_TMUX_ENTRY}。`);
}

// 幂等：先清理可能残留的旧复制产物
rmSync(DEST_SCRIPTS, { recursive: true, force: true });
rmSync(DEST_TMUX_ENTRY, { force: true });

// fs.cpSync 默认保留文件 mode（可执行位随内容一起拷贝）。
// filter 排除隐藏文件/目录（如本地未纳入 git 的 scripts/.claude/settings.local.json），
// 避免开发者本机的编辑器/工具局部配置意外随发布包泄漏。
cpSync(SRC_SCRIPTS, DEST_SCRIPTS, {
  recursive: true,
  filter: (src) => !basename(src).startsWith('.'),
});
cpSync(SRC_TMUX_ENTRY, DEST_TMUX_ENTRY);

// 抽查关键可执行脚本的权限位，确保 cpSync 确实保留了 mode
const sample = join(DEST_SCRIPTS, 'tmux-ai-status');
if (existsSync(sample)) {
  const mode = statSync(sample).mode & 0o111;
  if (mode === 0) {
    fail(`${sample} 复制后丢失可执行位，请检查 fs.cpSync 行为或手动 chmod`);
  }
}

console.log(`[prepack-bundle] 已复制 scripts/ → ${DEST_SCRIPTS}`);
console.log(`[prepack-bundle] 已复制 tmux-ai-hooks-status.tmux → ${DEST_TMUX_ENTRY}`);
