import { readFileSync } from 'node:fs';
import { execa } from 'execa';

const PACKAGE_NAME = 'tmuxclihook';
const packageJson = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

export const CURRENT_VERSION = packageJson.version;

export async function updatePackage(options = {}) {
  const run = options.run || execa;
  const log = options.log || console;
  const currentVersion = options.currentVersion || CURRENT_VERSION;

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
  return true;
}
