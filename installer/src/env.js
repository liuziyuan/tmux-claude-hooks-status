// env.js — 环境依赖修复（仅限 Homebrew 安全安装/升级）
import { execa } from 'execa';

const BREW_ACTIONS = new Set(['install', 'upgrade']);

// brew 是否可用。命令存在但退出非 0 也视为不可用。
export async function hasBrew({ runner = execa } = {}) {
  try {
    const result = await runner('brew', ['--version'], { reject: false, timeout: 5000 });
    return result.exitCode === 0;
  } catch {
    return false;
  }
}

// formula 是否由当前 Homebrew 安装并管理。
export async function brewManages(pkg, { runner = execa } = {}) {
  try {
    const result = await runner('brew', ['list', '--versions', pkg], {
      reject: false,
      timeout: 8000,
    });
    return result.exitCode === 0;
  } catch {
    return false;
  }
}

// 将 Doctor 结果转换成 install / upgrade / manual 计划。
export async function planBrewRemediation(
  results,
  { brewAvailable, manages = (pkg) => brewManages(pkg) } = {},
) {
  const available = brewAvailable ?? await hasBrew();
  const plan = [];

  for (const result of results) {
    if (result.status === 'ready') continue;

    if (!available) {
      plan.push({
        ...result,
        action: 'manual',
        command: null,
        reason: '未检测到 Homebrew，请使用原安装方式手动处理',
      });
      continue;
    }

    if (result.status === 'missing') {
      plan.push({
        ...result,
        action: 'install',
        command: `brew install ${result.pkg}`,
      });
      continue;
    }

    if (result.status === 'outdated' && await manages(result.pkg)) {
      plan.push({
        ...result,
        action: 'upgrade',
        command: `brew upgrade ${result.pkg}`,
      });
      continue;
    }

    plan.push({
      ...result,
      action: 'manual',
      command: null,
      reason: `不是由 Homebrew 管理，请按原安装方式升级至 ${result.min}`,
    });
  }

  return plan;
}

// 执行经过白名单校验的 brew install/upgrade。返回 {ok, output?}。
export async function runBrewAction(
  action,
  pkg,
  { onLine, runner = execa } = {},
) {
  if (!BREW_ACTIONS.has(action)) {
    throw new Error(`Unsupported brew action: ${action}`);
  }

  try {
    const subprocess = runner('brew', [action, pkg]);
    if (onLine) {
      subprocess.stdout?.on('data', (data) => onLine(String(data)));
      subprocess.stderr?.on('data', (data) => onLine(String(data)));
    }
    const result = await subprocess;
    if (result.exitCode != null && result.exitCode !== 0) {
      return { ok: false, output: result.stderr || result.stdout || `brew ${action} exited ${result.exitCode}` };
    }
    return { ok: true };
  } catch (err) {
    return { ok: false, output: err.shortMessage || String(err) };
  }
}

// 兼容旧调用方。
export async function brewInstall(pkg, onLine, options = {}) {
  return runBrewAction('install', pkg, { ...options, onLine });
}

export async function brewUpgrade(pkg, onLine, options = {}) {
  return runBrewAction('upgrade', pkg, { ...options, onLine });
}
