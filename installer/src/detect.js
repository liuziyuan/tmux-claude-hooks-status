// detect.js — 环境依赖侦测 + AI CLI 侦测
import { execa } from 'execa';
import { existsSync, readFileSync } from 'node:fs';
import { TOOLS, versionGte } from './adapters-meta.js';

// 探测某命令是否存在 + 版本
async function probe(bin, args, re) {
  try {
    const { stdout } = await execa(bin, args, { reject: false, timeout: 8000 });
    const m = re ? String(stdout).match(re) : null;
    return { found: true, version: m ? m[1] : null, raw: String(stdout).trim() };
  } catch {
    return { found: false, version: null, raw: null };
  }
}

// 环境依赖检查（Doctor）。返回逐项结果。
export async function checkEnv() {
  const results = [];

  // tmux ≥ 3.1
  const tmux = await probe('tmux', ['-V'], /(\d+\.\d+)/);
  results.push({
    name: 'tmux',
    ok: tmux.found && versionGte((tmux.version || '0') + '.0', '3.1.0'),
    detail: tmux.found ? `v${tmux.version}` : '未安装',
    min: '≥ 3.1',
    fixCmd: 'brew install tmux',
    pkg: 'tmux',
  });

  // jq（唯一硬依赖）
  const jq = await probe('jq', ['--version'], /(\d+\.\d+)/);
  results.push({
    name: 'jq',
    ok: jq.found,
    detail: jq.found ? (jq.raw || '已安装') : '未安装',
    min: '任意版本',
    fixCmd: 'brew install jq',
    pkg: 'jq',
  });

  // bash ≥ 4.0（macOS 自带 3.2，脚本用到 bash4 特性）
  const bash = await probe('bash', ['--version'], /version (\d+\.\d+)/);
  results.push({
    name: 'bash',
    ok: bash.found && versionGte((bash.version || '0') + '.0', '4.0.0'),
    detail: bash.found ? `v${bash.version}` : '未安装',
    min: '≥ 4.0',
    fixCmd: 'brew install bash',
    pkg: 'bash',
  });

  // node（TUI 自身运行环境，必在）
  const node = await probe('node', ['-v'], /v?(\d+\.\d+\.\d+)/);
  results.push({
    name: 'node',
    ok: node.found && versionGte(node.version || '0.0.0', '18.0.0'),
    detail: node.found ? `v${node.version}` : '未安装',
    min: '≥ 18',
    fixCmd: 'brew install node',
    pkg: 'node',
  });

  return results;
}

// 侦测某工具是否已装本插件 hooks
function hooksInstalled(tool) {
  try {
    if (!existsSync(tool.hooksFile)) return false;
    const raw = readFileSync(tool.hooksFile, 'utf8');
    const count = (raw.match(new RegExp(tool.hookMarker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length;
    return count >= tool.minHookCount;
  } catch {
    return false;
  }
}

// 侦测所有已装 AI CLI
export async function detectClis() {
  const rows = [];
  for (const tool of TOOLS) {
    const p = await probe(tool.bin, tool.versionArgs, tool.versionRe);
    const meetsMin = p.found ? versionGte(p.version || '0.0.0', tool.minVersion || '0.0.0') : false;
    rows.push({
      id: tool.id,
      label: tool.label,
      installed: p.found,
      version: p.version,
      meetsMin,
      minVersion: tool.minVersion,
      hooksInstalled: p.found ? hooksInstalled(tool) : false,
    });
  }
  return rows;
}

export { hooksInstalled };
