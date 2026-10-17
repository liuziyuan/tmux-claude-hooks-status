import { readFileSync, accessSync, constants as fsConstants, realpathSync } from 'node:fs';
import { basename, delimiter, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { execa } from 'execa';

const PACKAGE_NAME = 'tmuxclihook';
const packageJson = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

export const CURRENT_VERSION = packageJson.version;

// —— 生效版本自检 ————————————————————————————————————————————————
//
// `npm install -g` 在版本管理器（volta 等）环境下只写 node 工具链目录，
// 不更新 volta 的 shim 镜像（shim 指向 packages/）。因此升级前先按 PATH
// 上第一个可执行 tmuxclihook 判断「当前生效入口」属于哪套安装机制，只走
// 对应那一套（见 detectInstallSource / updatePackage），避免同一版本被写
// 成两份、hooks 指向其中一份而 PATH 命中另一份造成漂移。
// 本节自检只是事后确认：按 update 进程的 PATH 解析一份，尽力读取真实版本
// 并与 registry latest 比对，无法确认或版本不符时打警告。
// 验证是尽力而为的提示，不改变 update 的返回值（install 本身已成功）。

function findOnPath(name, env) {
  for (const dir of (env.PATH || '').split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, name);
    try {
      accessSync(candidate, fsConstants.X_OK);
      return candidate;
    } catch {
      // 无此文件或不可执行，继续找下一个目录
    }
  }
  return null;
}

// realpath 失败时退回字面绝对路径，保证包含判断仍可进行（不抛）。
function realOrResolved(p) {
  if (!p) return null;
  try {
    return realpathSync(p);
  } catch {
    return resolve(p);
  }
}

// child 是否位于 parent 目录内（含相等）。用 relative 而非 startsWith，
// 避免 `$VOLTA_HOME/bin-other` 被误判为 `$VOLTA_HOME/bin` 的子路径。
function isPathInside(child, parent) {
  const rel = relative(parent, child);
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
}

const VOLTA_SHIM_NAMES = new Set(['volta-shim', 'volta-shim.exe']);

// 判断 PATH 上第一个可执行的 tmuxclihook 来自哪套安装机制：
//   'volta'   — $VOLTA_HOME/bin 下的 shim、或 volta packages 镜像
//   'npm'     — npm 全局 / nvm / fnm 等 node 工具链目录
//   'unknown' — PATH 上找不到可执行入口
// 跟随「当前生效入口」是 update 的核心语义：只升级用户实际会执行的那一份。
export function detectInstallSource(env = process.env) {
  try {
    const entry = findOnPath(PACKAGE_NAME, env);
    if (!entry) return 'unknown';

    const voltaHome = env.VOLTA_HOME || (env.HOME ? join(env.HOME, '.volta') : null);
    const realEntry = realOrResolved(entry);

    if (voltaHome) {
      // macOS 的 /var → /private/var 等：原始路径与 canonical 路径都要比对
      const homes = [voltaHome];
      const realHome = realOrResolved(voltaHome);
      if (realHome && realHome !== voltaHome) homes.push(realHome);

      for (const home of homes) {
        const binDir = join(home, 'bin');
        const pkgDir = join(home, 'tools', 'image', 'packages', PACKAGE_NAME);
        for (const candidate of [entry, realEntry]) {
          if (!candidate) continue;
          if (isPathInside(candidate, binDir) || isPathInside(candidate, pkgDir)) return 'volta';
        }
      }
    }

    if (realEntry && VOLTA_SHIM_NAMES.has(basename(realEntry))) return 'volta';
    return 'npm';
  } catch {
    return 'unknown';
  }
}

// npm 布局下入口是 .../lib/node_modules/<pkg>/bin/cli.js（或其 symlink）：
// realpath 后向上最多 3 层找 name 匹配的 package.json 读版本。版本管理器
// shim 是独立二进制，向上找不到包 → 返回 null。
function readOwnPackageVersion(entryPath) {
  let real;
  try {
    real = realpathSync(entryPath);
  } catch {
    return null;
  }
  let dir = dirname(real);
  for (let i = 0; i < 3; i += 1) {
    try {
      const pkg = JSON.parse(readFileSync(join(dir, 'package.json'), 'utf8'));
      if (pkg.name === PACKAGE_NAME && typeof pkg.version === 'string') return pkg.version;
    } catch {
      // 该层无 package.json 或不可解析，继续向上
    }
    dir = dirname(dir);
  }
  return null;
}

// PATH 命中的是 shim 时，尝试 volta 的包镜像路径闭环确认（volta 实现细节，
// 读不到就放弃，不崩）。VOLTA_HOME 未设时用 ~/.volta。
function readVoltaImageVersion(env) {
  const voltaHome = env.VOLTA_HOME || join(env.HOME || '', '.volta');
  const pkgPath = join(
    voltaHome, 'tools', 'image', 'packages', PACKAGE_NAME,
    'lib', 'node_modules', PACKAGE_NAME, 'package.json',
  );
  try {
    return JSON.parse(readFileSync(pkgPath, 'utf8')).version || null;
  } catch {
    return null;
  }
}

export function verifyEffectiveVersion(latestVersion, env = process.env) {
  const entry = findOnPath(PACKAGE_NAME, env);
  if (!entry) return { status: 'unknown', path: null, version: null };

  const ownVersion = readOwnPackageVersion(entry);
  if (ownVersion) {
    return { status: ownVersion === latestVersion ? 'ok' : 'mismatch', path: entry, version: ownVersion };
  }

  const voltaVersion = readVoltaImageVersion(env);
  if (voltaVersion) {
    return { status: voltaVersion === latestVersion ? 'ok' : 'mismatch', path: entry, version: voltaVersion };
  }
  return { status: 'unknown', path: entry, version: null };
}

function warnNotEffective(log, result) {
  const where = result.path ? ` (${result.path})` : '';
  log.error(
    `Warning: the tmuxclihook command on your PATH${where} did not reflect the new version` +
    (result.version ? ` (still v${result.version})` : '') + '.',
  );
  log.error(`If you use volta, run: volta install ${PACKAGE_NAME}@latest`);
}

// volta 安装路径：当 PATH 上的生效入口来自 volta（shim 或 packages 镜像）
// 时，升级只能走 `volta install`——`npm install -g` 只写 node 工具链目录，
// 不会更新 volta 的 packages 镜像。此函数现在是 volta 分支的唯一升级动作，
// 不再作为 npm 安装后的无条件补丁（双写会制造两份副本并引发漂移）。
// volta 不可执行时返回 false，由调用方决定如何报告。
export async function repairWithVolta(run, log, env = process.env) {
  const voltaHome = env.VOLTA_HOME || join(env.HOME || '', '.volta');
  const voltaBin = findOnPath('volta', env) || join(voltaHome, 'bin', 'volta');
  try {
    accessSync(voltaBin, fsConstants.X_OK);
  } catch {
    return false;
  }
  log.log('Detected volta on this machine; applying the update via volta install...');
  try {
    await run('volta', ['install', `${PACKAGE_NAME}@latest`], { stdio: 'inherit' });
    return true;
  } catch (err) {
    log.error(`volta install failed: ${err}`);
    return false;
  }
}

export async function updatePackage(options = {}) {
  const run = options.run || execa;
  const log = options.log || console;
  const currentVersion = options.currentVersion || CURRENT_VERSION;
  const env = options.env || process.env;
  // 显式传 null 跳过自检/修正（测试用）；默认真实现
  const verify = options.verify === undefined ? verifyEffectiveVersion : options.verify;
  const repairVolta = options.repairVolta === undefined ? repairWithVolta : options.repairVolta;
  const detectSource = options.detectSource === undefined ? detectInstallSource : options.detectSource;

  log.log(`Current version: v${currentVersion}`);

  let latestVersion;
  try {
    const result = await run('npm', ['view', PACKAGE_NAME, 'version']);
    latestVersion = result.stdout.trim();
  } catch {
    log.error('Failed to check latest version. Please check your network connection.');
    return false;
  }

  if (currentVersion === latestVersion) {
    log.log('Already up to date.');
    return true;
  }

  log.log(`Updating to v${latestVersion}...`);

  // 跟随当前生效入口：PATH 上第一个 tmuxclihook 属于哪套机制，就只升级那套。
  // volta 入口走 volta install（npm -g 写不到 packages 镜像）；其余入口走 npm -g。
  // 不再双写——那会留下两份同版本副本，配置指向一份而命令执行另一份即产生漂移。
  const source = typeof detectSource === 'function' ? detectSource(env) : 'unknown';

  if (source === 'volta') {
    if (repairVolta) {
      const ok = await repairVolta(run, log, env);
      if (!ok) {
        log.error('Failed to update via volta. Please check your volta installation.');
        return false;
      }
    }
  } else {
    try {
      await run('npm', ['install', '-g', `${PACKAGE_NAME}@latest`], { stdio: 'inherit' });
    } catch {
      return false;
    }
  }

  log.log(`Done. Updated to v${latestVersion}`);

  if (!verify) return true;

  // 事后确认（尽力而为）：正常情况下生效入口应已是新版。
  let result = await verify(latestVersion, env);

  // 兜底：非 volta 来源、自检未过、且本机确有 volta 时补一次并复检。
  // 仅在异常场景触发（例如 npm 全局 bin 不在 PATH），保持「不双写」语义。
  if (result.status !== 'ok' && source !== 'volta' && repairVolta) {
    const repaired = await repairVolta(run, log, env);
    if (repaired) result = await verify(latestVersion, env);
  }

  if (result.status === 'ok') {
    log.log(`Verified: tmuxclihook on your PATH now resolves to v${latestVersion}.`);
  } else {
    warnNotEffective(log, result);
  }

  return true;
}
