// tmuxconf.js — 写入 .tmux.conf 的 run-shell 集成声明 + reload tmux
//
// 加载机制不再依赖 TPM 风格的 `@plugin` 声明与软链，而是直接一行
// `run-shell '<当前 source 的 tmux 入口绝对路径>'`。TMUX_ENTRY 随 source.js
// 的三级解析（env / 持久化配置 / 包内自带 / 开发回落）而变化，切换 source 后
// 需要重新调用 ensureTmuxIntegration() 才会把 .tmux.conf 里的路径更新到位
// （见 docs/2026-07-15-npm-global-install-plan.md 的残留风险第 4 条）。
import { execa } from 'execa';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { checkTmuxConf, runShellDeclarationLine } from './symlink.js';
import { TMUX_ENTRY } from './adapters-meta.js';

function confPath() {
  return join(homedir(), '.tmux.conf');
}

// 匹配「本工具此前写入的」run-shell 声明行（任意路径），用于识别指向旧 source
// 的陈旧行以便原地替换，避免同时存在两条 run-shell 造成 hooks/按键绑定重复注册。
// 只识别本工具自己的 run-shell 格式，不触碰用户可能保留的旧式 TPM @plugin 行。
const OWN_RUN_SHELL_RE = /^\s*run-shell\s+['"].*tmux-ai-hooks-status\.tmux['"]\s*$/;

// 确保 .tmux.conf 存在一行指向"当前 source"tmux 入口的 run-shell 声明：
//   - 完全没有集成 → 追加新行（只追加，不改动既有内容）
//   - 已存在本工具写入的 run-shell 行但指向其他路径（例如切换 source 之前的安装）
//     → 原地替换为当前正确路径
//   - 已指向当前路径 → no-op
// 不会删除或改动用户可能保留的旧式 TPM `@plugin` 声明行。
export function ensureTmuxIntegration({ tmuxEntry = TMUX_ENTRY, path = confPath() } = {}) {
  const targetLine = runShellDeclarationLine(tmuxEntry);

  if (!existsSync(path)) {
    try {
      writeFileSync(path, `${targetLine}\n`);
      return { ok: true, changed: true, action: 'created', path };
    } catch (err) {
      return { ok: false, changed: false, path, output: String(err) };
    }
  }

  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch (err) {
    return { ok: false, changed: false, path, output: String(err) };
  }

  if (raw.includes(targetLine)) {
    return { ok: true, changed: false, action: 'noop', path };
  }

  const hadTrailingNewline = raw.endsWith('\n');
  const lines = raw.split('\n');
  const hasStaleOwnLine = lines.some((line) => OWN_RUN_SHELL_RE.test(line));

  let nextLines;
  if (hasStaleOwnLine) {
    // 原地替换本工具此前写入、指向旧路径的 run-shell 行
    nextLines = lines.map((line) => (OWN_RUN_SHELL_RE.test(line) ? targetLine : line));
  } else {
    // 无本工具的旧声明（可能完全未集成，或只有旧式 @plugin 行）→ 纯追加
    nextLines = hadTrailingNewline ? [...lines.slice(0, -1), targetLine, ''] : [...lines, targetLine];
  }

  let content = nextLines.join('\n');
  if (!content.endsWith('\n')) content += '\n';

  try {
    writeFileSync(path, content);
    return { ok: true, changed: true, action: hasStaleOwnLine ? 'replaced' : 'appended', path };
  } catch (err) {
    return { ok: false, changed: false, path, output: String(err) };
  }
}

// 重载 tmux 配置（source-file 重跑插件加载；refresh-client 仅重绘不够）。
// tmux 未运行时捕获错误返回提示，不抛。
export async function reloadTmux({ path = confPath() } = {}) {
  try {
    await execa('tmux', ['source-file', path], { timeout: 10000 });
    return { ok: true };
  } catch (err) {
    return { ok: false, output: err.stderr || err.shortMessage || String(err) };
  }
}

export { checkTmuxConf };
