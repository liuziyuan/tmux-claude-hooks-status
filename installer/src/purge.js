// purge.js — 完整卸载编排：monitor stop + 清聚合状态 + 删软链（不删仓库/不动 conf/不 kill-server）
import { execa } from 'execa';
import { rmSync, lstatSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { PLUGIN_LINK, SCRIPTS_DIR } from './adapters-meta.js';

// 旧名软链（历史安装）
const PLUGIN_LINK_LEGACY = join(dirname(PLUGIN_LINK), 'tmux-claude-hooks-status');

// 停止 Codex lifecycle monitor
export async function stopMonitor() {
  try {
    await execa('bash', [join(SCRIPTS_DIR, 'tmux-ai-monitor'), 'stop'], { timeout: 10000 });
    return { ok: true };
  } catch (err) {
    return { ok: false, output: err.stderr || err.shortMessage || String(err) };
  }
}

// 清除聚合状态选项 @ai_all_status
export async function clearAggregateStatus() {
  try {
    await execa('tmux', ['set-option', '-gu', '@ai_all_status'], { timeout: 10000 });
    return { ok: true };
  } catch (err) {
    return { ok: false, output: err.stderr || err.shortMessage || String(err) };
  }
}

// 删除插件软链（canonical + 旧名）；不删真实仓库
export function removeSymlinks() {
  const removed = [];
  for (const link of [PLUGIN_LINK, PLUGIN_LINK_LEGACY]) {
    let present = false;
    try { lstatSync(link); present = true; } catch { /* 不存在 */ }
    if (!present) continue;
    try {
      rmSync(link, { force: true });
      removed.push(link);
    } catch { /* 忽略：权限等 */ }
  }
  return { ok: true, removed };
}
