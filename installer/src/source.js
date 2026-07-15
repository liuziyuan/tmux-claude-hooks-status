// source.js — 解析当前生效的「代码来源」（scripts/ + tmux 入口所在目录）
//
// npm 全局安装后，installer/scripts 与 installer/tmux-ai-hooks-status.tmux 由
// prepack 从仓库根复制打包进来，作为生产默认（"bundled"）。开发者也可以通过
// 环境变量或持久化配置指向本地仓库副本进行调试，改代码立即生效，无需重新发布。
//
// 解析优先级（从高到低）：
//   1. 环境变量 TMUXCLIHOOK_SOURCE=<绝对路径>        一次性 / CI 场景
//   2. 持久化配置 ~/.config/tmuxclihook/config.json  TUI「source 管理」菜单写入
//   3. 包内自带 installer/（prepack 复制产物）        生产默认，自包含
//   4. 开发回落 仓库根（installer/ 的上一级）          cd installer && npm start
//
// "source" 指向的是一个目录（repo root），要求其下存在 scripts/ 子目录；
// tmux-ai-hooks-status.tmux 若存在则一并使用，不存在也不影响 hooks 相关功能。

import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { homedir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));

// installer/src/source.js 的上一级即 installer/ 本身
const INSTALLER_DIR = resolve(__dirname, '..');
// installer/ 的上一级：开发布局下的仓库根
const DEV_REPO_ROOT = resolve(INSTALLER_DIR, '..');

export const CONFIG_DIR = join(homedir(), '.config', 'tmuxclihook');
export const CONFIG_FILE = join(CONFIG_DIR, 'config.json');

// 合法 repo root 的判定标准：其下存在 scripts/ 目录
function isValidRepoRoot(dir) {
  return !!dir && existsSync(join(dir, 'scripts'));
}

// 读取持久化配置中的 source 路径。文件不存在/损坏返回 null。
function readConfigSource(configFile) {
  try {
    const raw = readFileSync(configFile, 'utf8');
    const json = JSON.parse(raw);
    return typeof json.source === 'string' && json.source ? json.source : null;
  } catch {
    return null;
  }
}

// 三级解析当前生效 source。返回 { repoRoot, scriptsDir, tmuxEntry, origin, warnings }
// origin: 'env' | 'config' | 'bundled' | 'repo'
//
// bundledDir / devRepoRoot 可注入以便测试（默认分别为 installer/ 本身与仓库根），
// 生产调用方不传，走真实路径。
export function resolveSource({
  env = process.env,
  configFile = CONFIG_FILE,
  bundledDir = INSTALLER_DIR,
  devRepoRoot = DEV_REPO_ROOT,
} = {}) {
  const warnings = [];

  const envSource = env.TMUXCLIHOOK_SOURCE;
  if (envSource) {
    const abs = resolve(envSource);
    if (isValidRepoRoot(abs)) {
      return buildResult(abs, 'env', warnings);
    }
    warnings.push(`环境变量 TMUXCLIHOOK_SOURCE=${envSource} 下未找到 scripts/ 目录，已忽略`);
  }

  const configSource = readConfigSource(configFile);
  if (configSource) {
    const abs = resolve(configSource);
    if (isValidRepoRoot(abs)) {
      return buildResult(abs, 'config', warnings);
    }
    warnings.push(`已保存的 source（${configSource}）下未找到 scripts/ 目录，已忽略`);
  }

  if (isValidRepoRoot(bundledDir)) {
    return buildResult(bundledDir, 'bundled', warnings);
  }

  // 开发回落：即使仓库根 scripts/ 也不存在（理论不应发生），仍返回该路径供上游报错提示
  return buildResult(devRepoRoot, 'repo', warnings);
}

function buildResult(repoRoot, origin, warnings) {
  return {
    repoRoot,
    scriptsDir: join(repoRoot, 'scripts'),
    tmuxEntry: join(repoRoot, 'tmux-ai-hooks-status.tmux'),
    origin,
    warnings,
  };
}

// 持久化设置本地 source（写 ~/.config/tmuxclihook/config.json）。
// 会校验目标目录下是否存在 scripts/，无效路径直接拒绝，不写入。
export function setSource(dir, { configFile = CONFIG_FILE, configDir = CONFIG_DIR } = {}) {
  const abs = resolve(dir);
  if (!isValidRepoRoot(abs)) {
    return { ok: false, output: `${abs} 下未找到 scripts/ 目录，不是合法的仓库路径` };
  }
  try {
    mkdirSync(configDir, { recursive: true });
    writeFileSync(configFile, `${JSON.stringify({ source: abs }, null, 2)}\n`);
    return { ok: true, source: abs };
  } catch (err) {
    return { ok: false, output: String(err) };
  }
}

// 清除持久化 source，恢复默认（env 优先，其次包内自带/仓库回落）。
export function clearSource({ configFile = CONFIG_FILE } = {}) {
  try {
    if (existsSync(configFile)) rmSync(configFile, { force: true });
    return { ok: true };
  } catch (err) {
    return { ok: false, output: String(err) };
  }
}

// 供 TUI 展示：当前持久化配置里保存的 source（不做校验，仅原样返回）
export function getPersistedSource({ configFile = CONFIG_FILE } = {}) {
  return readConfigSource(configFile);
}

export function isValidSourcePath(dir) {
  return isValidRepoRoot(dir);
}

const ORIGIN_LABELS = {
  env: '环境变量 TMUXCLIHOOK_SOURCE',
  config: '已保存的本地路径',
  bundled: '包内自带（生产默认）',
  repo: '仓库根（开发回落）',
};

export function originLabel(origin) {
  return ORIGIN_LABELS[origin] || origin;
}
