// adapters-meta.js — AI CLI 工具元数据 + 仓库路径定位
//
// TUI 侧的工具清单（对应 scripts/adapters/*.sh）。新增 CLI 时在此加一条 + 加 bash adapter。
// bin/minVersion/hooksFile 用于侦测；installer 指向瘦 wrapper（真实逻辑在 bash adapter）。

import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));

// installer/ 的上一级即仓库根
export const REPO_ROOT = resolve(__dirname, '..', '..');
export const SCRIPTS_DIR = join(REPO_ROOT, 'scripts');

const HOME = homedir();

// 工具元数据表。version 解析用正则从 `<bin> --version` 输出提取。
export const TOOLS = [
  {
    id: 'claude',
    label: 'Claude Code',
    bin: 'claude',
    versionArgs: ['--version'],
    versionRe: /(\d+\.\d+\.\d+)/,          // "2.1.210 (Claude Code)"
    minVersion: null,                        // 无硬性最低要求
    hooksFile: join(process.env.CLAUDE_CONFIG_DIR || join(HOME, '.claude'), 'settings.json'),
    installer: join(SCRIPTS_DIR, 'install-claude-hooks.sh'),
    hookMarker: 'tmux-ai-status',
    minHookCount: 10,
  },
  {
    id: 'codex',
    label: 'Codex CLI',
    bin: 'codex',
    versionArgs: ['--version'],
    versionRe: /(\d+\.\d+\.\d+)/,          // "codex-cli 0.144.4"
    minVersion: '0.144.0',                   // hooks.json + trust 起于 0.144
    hooksFile: join(process.env.CODEX_HOME || join(HOME, '.codex'), 'hooks.json'),
    installer: join(SCRIPTS_DIR, 'install-codex-hooks.sh'),
    hookMarker: 'tmux-ai-status codex',
    minHookCount: 6,
  },
  {
    id: 'opencode',
    label: 'opencode',
    bin: 'opencode',
    versionArgs: ['--version'],
    versionRe: /(\d+\.\d+\.\d+)/,
    minVersion: null,                        // plugin 系统本地文件跳过版本兼容检查
    // hooksFile 实为 JS/TS plugin 文件（非 JSON hooks 配置），install/uninstall 整文件写入/删除
    hooksFile: join(
      process.env.OPENCODE_CONFIG_DIR || join(process.env.XDG_CONFIG_HOME || join(HOME, '.config'), 'opencode'),
      'plugins',
      'tmux-ai-status.ts'
    ),
    installer: join(SCRIPTS_DIR, 'install-opencode-hooks.sh'),
    hookMarker: 'tmux-ai-status (managed by tmux-ai-hooks-status)',
    minHookCount: 1,
  },
];

export function toolById(id) {
  return TOOLS.find((t) => t.id === id);
}

// 语义版本比较：a >= b ? 返回 true。仅比较 x.y.z 三段。
export function versionGte(a, b) {
  if (!a || !b) return true;
  const pa = a.split('.').map((n) => parseInt(n, 10) || 0);
  const pb = b.split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) > (pb[i] || 0)) return true;
    if ((pa[i] || 0) < (pb[i] || 0)) return false;
  }
  return true;
}

// TPM 软链路径（仓库目录名）
export const PLUGIN_LINK = join(HOME, '.tmux', 'plugins', 'tmux-ai-hooks-status');
export const repoExists = existsSync(SCRIPTS_DIR);
