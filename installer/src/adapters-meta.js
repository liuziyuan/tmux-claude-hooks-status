// adapters-meta.js — AI CLI 工具元数据 + 仓库路径定位
//
// TUI 侧的工具清单（对应 scripts/adapters/*.sh）。新增 CLI 时在此加一条 + 加 bash adapter。
// bin/minVersion/hooksFile 用于侦测；installer 指向瘦 wrapper（真实逻辑在 bash adapter）。
//
// REPO_ROOT/SCRIPTS_DIR 不再是写死的相对路径，而是委托 source.js 的三级解析
// （env TMUXCLIHOOK_SOURCE > 持久化配置 > 包内自带 > 开发回落）。这些导出是
// ES module 的 live binding：resolveSource()/refreshSource() 重新赋值后，
// 所有 `import { REPO_ROOT } from './adapters-meta.js'` 的调用方会自动看到新值，
// 无需重启进程或改动各自的 import 语句。

import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolveSource } from './source.js';

const HOME = homedir();

function buildTools(scriptsDir) {
  return [
    {
      id: 'claude',
      label: 'Claude Code',
      bin: 'claude',
      versionArgs: ['--version'],
      versionRe: /(\d+\.\d+\.\d+)/,          // "2.1.210 (Claude Code)"
      minVersion: null,                        // 无硬性最低要求
      hooksFile: join(process.env.CLAUDE_CONFIG_DIR || join(HOME, '.claude'), 'settings.json'),
      installer: join(scriptsDir, 'install-claude-hooks.sh'),
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
      installer: join(scriptsDir, 'install-codex-hooks.sh'),
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
      installer: join(scriptsDir, 'install-opencode-hooks.sh'),
      hookMarker: 'tmux-ai-status (managed by tmux-ai-hooks-status)',
      minHookCount: 1,
    },
  ];
}

function computeSource() {
  const s = resolveSource();
  return {
    repoRoot: s.repoRoot,
    scriptsDir: s.scriptsDir,
    tmuxEntry: s.tmuxEntry,
    origin: s.origin,
    warnings: s.warnings,
  };
}

let _current = computeSource();

export let REPO_ROOT = _current.repoRoot;
export let SCRIPTS_DIR = _current.scriptsDir;
export let TMUX_ENTRY = _current.tmuxEntry;
export let SOURCE_ORIGIN = _current.origin;
export let SOURCE_WARNINGS = _current.warnings;
export let TOOLS = buildTools(SCRIPTS_DIR);
export let repoExists = existsSync(SCRIPTS_DIR);

// 重新解析 source 并刷新以上所有导出（live binding，下游 import 自动看到新值）。
// 在 TUI 内「source 管理」菜单执行 set/clear 之后调用，使同一进程内立即生效，
// 不需要重启 TUI。
export function refreshSource() {
  _current = computeSource();
  REPO_ROOT = _current.repoRoot;
  SCRIPTS_DIR = _current.scriptsDir;
  TMUX_ENTRY = _current.tmuxEntry;
  SOURCE_ORIGIN = _current.origin;
  SOURCE_WARNINGS = _current.warnings;
  TOOLS = buildTools(SCRIPTS_DIR);
  repoExists = existsSync(SCRIPTS_DIR);
  return _current;
}

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

// TPM 软链路径（仓库目录名）。已不是主加载路径（改用 .tmux.conf 直接 run-shell
// 当前 source 的 tmux 入口），仅供「tmux 集成」检测/清理历史遗留软链时复用。
export const PLUGIN_LINK = join(HOME, '.tmux', 'plugins', 'tmux-ai-hooks-status');
