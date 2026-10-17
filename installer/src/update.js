import { readFileSync, accessSync, existsSync, constants as fsConstants, realpathSync } from 'node:fs';
import { basename, delimiter, dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
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

// —— 非生效副本检测与可选收敛 ——————————————————————————————————————
//
// update 只升级生效入口，不主动动另一套安装。历史遗留的双份副本会让后续
// 手动交叉升级「升级到不生效的那份」，因此提供可选收敛：只删同时满足以下
// 条件的副本——不是生效入口、未被 hooks 引用、未被 ~/.tmux.conf 引用、
// 位于已知标准位置。TTY 下交互确认（默认 No）；--prune 跳过确认；
// 非交互环境只警告，绝不静默删除。

const TOOL_IDS = ['claude', 'codex', 'opencode'];

function voltaPackagesRoot(env) {
  const voltaHome = env.VOLTA_HOME || (env.HOME ? join(env.HOME, '.volta') : null);
  return voltaHome ? join(voltaHome, 'tools', 'image', 'packages', PACKAGE_NAME) : null;
}

async function readNpmGlobalPrefix(run) {
  try {
    const r = await run('npm', ['prefix', '-g']);
    return (r.stdout || '').trim() || null;
  } catch {
    return null;
  }
}

// 返回「非生效 + 位于标准位置」的副本。source 为 unknown 时不做任何
// 检测——找不到生效入口时删除任何一份都可能让用户彻底没有命令。
export async function detectStaleInstalls(source, env = process.env, run = execa) {
  if (source === 'unknown') return [];

  const stale = [];
  if (source === 'npm') {
    const voltaRoot = voltaPackagesRoot(env);
    if (voltaRoot && existsSync(voltaRoot)) stale.push({ kind: 'volta', root: voltaRoot });
  }
  if (source === 'volta') {
    const prefix = await readNpmGlobalPrefix(run);
    const npmRoot = prefix ? join(prefix, 'lib', 'node_modules', PACKAGE_NAME) : null;
    if (npmRoot && existsSync(npmRoot)) stale.push({ kind: 'npm', root: npmRoot });
  }
  return stale;
}

// hooks 是否引用该副本。走三个 wrapper 的 check --json（与 TUI 同源），
// 输出里出现目标路径即视为引用。任何异常都按「有引用」处理，宁可不动。
async function hooksReference(root, env, run) {
  const scriptsDir = fileURLToPath(new URL('../scripts/', import.meta.url));
  for (const tool of TOOL_IDS) {
    const script = join(scriptsDir, `install-${tool}-hooks.sh`);
    if (!existsSync(script)) continue;
    try {
      const r = await run('bash', [script, 'check', '--json'], { env });
      if ((r.stdout || '').includes(root)) return tool;
    } catch (err) {
      if ((err.stdout || '').includes(root)) return tool;
      return tool;
    }
  }
  return null;
}

function tmuxConfReferences(root, env) {
  if (!env.HOME) return true;
  try {
    return readFileSync(join(env.HOME, '.tmux.conf'), 'utf8').includes(root);
  } catch {
    return false;
  }
}

async function uninstallStale(item, run) {
  try {
    if (item.kind === 'volta') {
      await run('volta', ['uninstall', PACKAGE_NAME], { stdio: 'inherit' });
    } else {
      await run('npm', ['uninstall', '-g', PACKAGE_NAME], { stdio: 'inherit' });
    }
    return true;
  } catch {
    return false;
  }
}

// 交互确认的默认实现：读一行，默认 No。测试通过 options.confirm 注入。
async function defaultConfirm(question) {
  const { createInterface } = await import('node:readline/promises');
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    const answer = await rl.question(`${question} [y/N] `);
    return /^y(es)?$/i.test(answer.trim());
  } finally {
    rl.close();
  }
}

// 清理非生效副本。返回是否实际删除过任何副本。
export async function cleanupStale(options) {
  const {
    source, env, run, log, prune, isTTY, confirm, checkHooks, checkTmuxConf,
  } = options;

  const stale = await options.detectStale(source, env, run);
  if (stale.length === 0) return false;

  let removed = false;
  for (const item of stale) {
    const label = `${item.kind} install at ${item.root}`;

    const hookTool = await checkHooks(item.root, env, run);
    if (hookTool) {
      log.error(`Not removing ${label}: still referenced by ${hookTool} hooks. Reinstall hooks from the effective entry first.`);
      continue;
    }
    if (checkTmuxConf(item.root, env)) {
      log.error(`Not removing ${label}: still referenced by ~/.tmux.conf.`);
      continue;
    }

    if (!prune) {
      if (!isTTY) {
        log.error(`Another install found: ${label}. Run "tmuxclihook update --prune" in a terminal to remove it.`);
        continue;
      }
      const yes = await confirm(`Remove the non-effective ${label}?`);
      if (!yes) {
        log.log(`Keeping ${label}.`);
        continue;
      }
    }

    if (await uninstallStale(item, run)) {
      log.log(`Removed ${label}.`);
      removed = true;
    } else {
      log.error(`Failed to remove ${label}.`);
    }
  }
  return removed;
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

// 清理非生效副本，并在实际删除过副本后复检生效入口。升级成功路径与
// 「已是最新 + --prune」路径共用，避免两处逻辑漂移。清理失败只记录日志，
// 不影响 update 的返回值。
async function reconcileStaleCopies({
  source, env, run, log, prune, isTTY, confirm,
  checkHooks, checkTmuxConf, detectStale, verify, expectedVersion,
}) {
  try {
    const removed = await cleanupStale({
      source, env, run, log, prune, isTTY, confirm, checkHooks, checkTmuxConf, detectStale,
    });
    if (removed && verify) {
      const after = await verify(expectedVersion, env);
      if (after.status !== 'ok') warnNotEffective(log, after);
    }
  } catch (err) {
    log.error(`Cleanup skipped: ${err}`);
  }
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
  // 非生效副本收敛：默认开启，TTY 下交互确认；--prune 跳过确认。
  const cleanup = options.cleanup !== false;
  const prune = options.prune === true;
  const isTTY = options.isTTY === undefined
    ? Boolean(process.stdin.isTTY && process.stdout.isTTY)
    : options.isTTY;
  const confirm = options.confirm || defaultConfirm;
  const detectStale = options.detectStale || detectStaleInstalls;
  const checkHooks = options.checkHooks || hooksReference;
  const checkTmuxConf = options.checkTmuxConf || tmuxConfReferences;

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

    // 版本已最新：绝不安装；仅显式 --prune 时收敛非生效副本。
    // 未传 --prune 时保持历史行为：不探测来源、不清理、直接返回。
    if (cleanup && prune) {
      const effectiveSource = typeof detectSource === 'function'
        ? detectSource(env)
        : 'unknown';
      await reconcileStaleCopies({
        source: effectiveSource, env, run, log, prune, isTTY, confirm,
        checkHooks, checkTmuxConf, detectStale, verify,
        expectedVersion: latestVersion,
      });
    }

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

  // 升级已确认成功后再收敛历史副本；清理失败不影响升级结果，也不改变退出码。
  if (cleanup && result.status === 'ok') {
    await reconcileStaleCopies({
      source, env, run, log, prune, isTTY, confirm,
      checkHooks, checkTmuxConf, detectStale, verify,
      expectedVersion: latestVersion,
    });
  }

  return true;
}
