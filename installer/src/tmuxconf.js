// tmuxconf.js — 写入 .tmux.conf 的 @plugin 声明 + reload tmux（symlink.js 保持只读职责）
import { execa } from 'execa';
import { existsSync, readFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { checkTmuxConf } from './symlink.js';

const PLUGIN_DECL = "set -g @plugin 'tmux-ai-hooks-status'";

function confPath() {
  return join(homedir(), '.tmux.conf');
}

// 若 .tmux.conf 未引用本插件，追加 @plugin 声明。已引用则 no-op。
export function appendPluginDeclaration() {
  const path = confPath();
  const { referenced } = checkTmuxConf();
  if (referenced) return { ok: true, appended: false, path };
  try {
    // 保证与前文有换行分隔
    let prefix = '';
    if (existsSync(path)) {
      const raw = readFileSync(path, 'utf8');
      if (raw.length > 0 && !raw.endsWith('\n')) prefix = '\n';
    }
    appendFileSync(path, `${prefix}${PLUGIN_DECL}\n`);
    return { ok: true, appended: true, path };
  } catch (err) {
    return { ok: false, appended: false, path, output: String(err) };
  }
}

// 重载 tmux 配置（source-file 重跑插件加载；refresh-client 仅重绘不够）。
// tmux 未运行时捕获错误返回提示，不抛。
export async function reloadTmux() {
  const path = confPath();
  try {
    await execa('tmux', ['source-file', path], { timeout: 10000 });
    return { ok: true };
  } catch (err) {
    return { ok: false, output: err.stderr || err.shortMessage || String(err) };
  }
}
