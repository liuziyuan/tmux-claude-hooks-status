// symlink.js — TPM 软链校验/创建 + .tmux.conf 引用检查
import { existsSync, lstatSync, readlinkSync, symlinkSync, mkdirSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { PLUGIN_LINK, REPO_ROOT } from './adapters-meta.js';

const PLUGINS_DIR = dirname(PLUGIN_LINK);

// 扫 ~/.tmux/plugins/ 找任何指向本仓库的软链（含旧名 tmux-claude-hooks-status）。
// 返回匹配的软链绝对路径，无则 null。
function findRepoLink() {
  try {
    for (const name of readdirSync(PLUGINS_DIR)) {
      const full = join(PLUGINS_DIR, name);
      try {
        const st = lstatSync(full);
        if (st.isSymbolicLink() && readlinkSync(full) === REPO_ROOT) return full;
        // 真实目录且含入口文件也算（非软链安装）
        if (st.isDirectory() && full === REPO_ROOT) return full;
      } catch { /* skip */ }
    }
  } catch { /* plugins dir 不存在 */ }
  return null;
}

// 检查软链状态：missing | wrong | ok
export function checkSymlink() {
  // 先看是否已有任意指向本仓库的软链（含旧名）
  const existing = findRepoLink();
  if (existing) {
    const note = existing === PLUGIN_LINK ? '指向本仓库' : `指向本仓库（软链名 ${existing.split('/').pop()}）`;
    return { status: 'ok', target: REPO_ROOT, link: existing, note };
  }

  // 无匹配软链：检查 canonical 路径是否被占（悬空/指向他处）
  try {
    const st = lstatSync(PLUGIN_LINK);
    if (st.isSymbolicLink()) {
      let target = null;
      try { target = readlinkSync(PLUGIN_LINK); } catch { /* dangling */ }
      return { status: 'wrong', target, reason: target ? '指向其他位置' : '悬空软链' };
    }
    return { status: 'wrong', target: PLUGIN_LINK, reason: '同名目录（非软链）' };
  } catch {
    return { status: 'missing', target: null };
  }
}

// 创建软链 PLUGIN_LINK → REPO_ROOT
export function createSymlink() {
  try {
    mkdirSync(dirname(PLUGIN_LINK), { recursive: true });
    // 已存在悬空软链先删
    try { lstatSync(PLUGIN_LINK); } catch { /* not exist, ok */ }
    symlinkSync(REPO_ROOT, PLUGIN_LINK, 'dir');
    return { ok: true, from: PLUGIN_LINK, to: REPO_ROOT };
  } catch (err) {
    return { ok: false, output: err.code === 'EEXIST' ? '软链已存在' : String(err) };
  }
}

// 检查 ~/.tmux.conf 是否引用本插件
export function checkTmuxConf() {
  const conf = join(homedir(), '.tmux.conf');
  if (!existsSync(conf)) return { exists: false, referenced: false };
  try {
    const raw = readFileSync(conf, 'utf8');
    const referenced = /tmux-ai-hooks-status|tmux-claude-hooks-status/.test(raw);
    return { exists: true, referenced };
  } catch {
    return { exists: true, referenced: false };
  }
}
