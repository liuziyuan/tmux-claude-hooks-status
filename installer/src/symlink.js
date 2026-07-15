// symlink.js — TPM 软链校验（历史遗留兼容） + .tmux.conf 集成状态检查
//
// 主加载路径已改为 tmuxconf.js 的 run-shell（见该文件），不再依赖本文件的软链
// 创建。checkSymlink() 仅用于 TUI「tmux 集成」菜单里检测/清理历史遗留的
// ~/.tmux/plugins/ 软链；checkTmuxConf() 供 tmuxconf.js 判断 .tmux.conf 集成状态
// （含旧式 TPM @plugin 声明的宽松探测，以及是否已指向"当前 source"的精确匹配）。
import { existsSync, lstatSync, readlinkSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { homedir } from 'node:os';
import { PLUGIN_LINK, REPO_ROOT, TMUX_ENTRY } from './adapters-meta.js';

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

// 构造本插件在 .tmux.conf 中的标准 run-shell 声明行
export function runShellDeclarationLine(tmuxEntry = TMUX_ENTRY) {
  return `run-shell '${tmuxEntry}'`;
}

// 检查 ~/.tmux.conf 对本插件的集成状态：
//   referenced      是否存在任何指向本插件的声明（新式 run-shell 或旧式 TPM @plugin，
//                   任意路径/任意来源，宽松子串匹配，兼容历史安装）
//   pointsToCurrent 是否已存在指向"当前 source"tmux 入口绝对路径的精确 run-shell 行
export function checkTmuxConf({ tmuxEntry = TMUX_ENTRY } = {}) {
  const conf = join(homedir(), '.tmux.conf');
  if (!existsSync(conf)) return { exists: false, referenced: false, pointsToCurrent: false };
  try {
    const raw = readFileSync(conf, 'utf8');
    const referenced = /tmux-ai-hooks-status|tmux-claude-hooks-status/.test(raw);
    const pointsToCurrent = raw.includes(runShellDeclarationLine(tmuxEntry));
    return { exists: true, referenced, pointsToCurrent };
  } catch {
    return { exists: true, referenced: false, pointsToCurrent: false };
  }
}
