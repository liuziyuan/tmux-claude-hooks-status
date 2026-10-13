import { readFileSync, accessSync, constants as fsConstants, realpathSync } from 'node:fs';
import { delimiter, dirname, join } from 'node:path';
import { execa } from 'execa';

const PACKAGE_NAME = 'tmuxclihook';
const packageJson = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

export const CURRENT_VERSION = packageJson.version;

// —— 生效版本自检 ————————————————————————————————————————————————
//
// `npm install -g` 在版本管理器（volta 等）环境下不会更新其管理的 shim：
// volta 的 `~/.volta/bin` shim 指向 packages/ 镜像，而 npm -g 只写 node
// 工具链目录，两者互不感知（实测 0.3.0 → 0.3.2 升级时用户命令仍解析到
// 旧版）。install 成功后按 PATH 解析「用户实际会运行的那份」，尽力读取
// 真实版本并与 registry latest 比对，无法确认或版本不符时打警告。
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

// volta 生效修正：`npm install -g` 只写 node 工具链目录，不更新 volta 的
// shim 镜像（实测 volta 2.0.2：shim npm 的全局 prefix 就是工具链目录），
// 用户的命令经 ~/.volta/bin shim 解析时仍是旧版。检测到 volta 可用时自动
// 补一次 volta install 使更新生效。npm install -g 始终是安装语义本身，
// volta 只在自检发现未生效时被自动调用，用户无需改变安装习惯。
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
  // 显式传 null 跳过自检/修正（测试用）；默认真实现
  const verify = options.verify === undefined ? verifyEffectiveVersion : options.verify;
  const repairVolta = options.repairVolta === undefined ? repairWithVolta : options.repairVolta;

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
  try {
    await run('npm', ['install', '-g', `${PACKAGE_NAME}@latest`], { stdio: 'inherit' });
  } catch {
    return false;
  }

  log.log(`Done. Updated to v${latestVersion}`);

  if (verify) {
    let result = await verify(latestVersion);
    if (result.status !== 'ok') {
      // PATH 命中的副本未反映新版本（典型：volta shim 镜像未更新）——
      // 自动走 volta 完成生效步骤，然后复检。
      if (repairVolta && await repairVolta(run, log)) {
        result = await verify(latestVersion);
      }
      if (result.status === 'ok') {
        log.log(`Verified: tmuxclihook on your PATH now resolves to v${latestVersion}.`);
      } else {
        warnNotEffective(log, result);
      }
    }
  }

  return true;
}
