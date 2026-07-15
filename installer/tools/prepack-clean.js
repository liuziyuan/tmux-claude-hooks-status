#!/usr/bin/env node
// prepack-clean.js — npm publish/pack 完成后，删除 prepack-bundle.js 复制进 installer/ 的产物
//
// 由 package.json 的 "postpack" 钩子触发。保持仓库工作区干净：installer/scripts
// 与 installer/tmux-ai-hooks-status.tmux 只在打包过程中临时存在，不进 git
// （见根 .gitignore），也不会在日常 `cd installer && npm start` 开发流程中残留、
// 干扰 source.js 的「开发回落」判定。

import { existsSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const INSTALLER_DIR = resolve(__dirname, '..');

const DEST_SCRIPTS = join(INSTALLER_DIR, 'scripts');
const DEST_TMUX_ENTRY = join(INSTALLER_DIR, 'tmux-ai-hooks-status.tmux');

let removed = false;
if (existsSync(DEST_SCRIPTS)) {
  rmSync(DEST_SCRIPTS, { recursive: true, force: true });
  removed = true;
}
if (existsSync(DEST_TMUX_ENTRY)) {
  rmSync(DEST_TMUX_ENTRY, { force: true });
  removed = true;
}

console.log(removed ? '[prepack-clean] 已清理复制产物' : '[prepack-clean] 无复制产物需要清理');
