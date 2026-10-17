import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, chmodSync, symlinkSync } from 'node:fs';
import { delimiter, join } from 'node:path';
import { tmpdir } from 'node:os';

import { CURRENT_VERSION, updatePackage, verifyEffectiveVersion, repairWithVolta, detectInstallSource } from '../src/update.js';

function captureLog() {
  const messages = [];
  return {
    messages,
    log: {
      log(message) { messages.push(message); },
      error(message) { messages.push(message); },
    },
  };
}

test('CURRENT_VERSION comes from package.json', () => {
  assert.match(CURRENT_VERSION, /^\d+\.\d+\.\d+$/u);
});

test('updatePackage stops when the installed version is current', async () => {
  const calls = [];
  const { log, messages } = captureLog();
  const run = async (command, args) => {
    calls.push([command, args]);
    return { stdout: '0.2.0\n' };
  };
  let detectCalls = 0;
  const detectSource = () => {
    detectCalls += 1;
    return 'volta';
  };

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0', detectSource });

  assert.equal(ok, true);
  assert.equal(detectCalls, 0, '版本已最新时不应探测安装来源');
  assert.deepEqual(calls, [['npm', ['view', 'tmuxclihook', 'version']]]);
  assert.deepEqual(messages, ['Current version: v0.2.0', 'Already up to date.']);
});

test('updatePackage installs the latest global package when versions differ', async () => {
  const calls = [];
  const { log, messages } = captureLog();
  const run = async (command, args, options) => {
    calls.push([command, args, options]);
    return { stdout: '0.3.0\n' };
  };

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0', verify: null, repairVolta: null, detectSource: () => 'npm' });

  assert.equal(ok, true);
  assert.deepEqual(calls, [
    ['npm', ['view', 'tmuxclihook', 'version'], undefined],
    ['npm', ['install', '-g', 'tmuxclihook@latest'], { stdio: 'inherit' }],
  ]);
  assert.deepEqual(messages, [
    'Current version: v0.2.0',
    'Updating to v0.3.0...',
    'Done. Updated to v0.3.0',
  ]);
});

test('updatePackage reports registry lookup failure without installing', async () => {
  const { log, messages } = captureLog();
  const run = async () => { throw new Error('offline'); };

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0' });

  assert.equal(ok, false);
  assert.deepEqual(messages, [
    'Current version: v0.2.0',
    'Failed to check latest version. Please check your network connection.',
  ]);
});

test('updatePackage returns failure when global installation fails', async () => {
  let callCount = 0;
  const { log, messages } = captureLog();
  const run = async () => {
    callCount += 1;
    if (callCount === 1) return { stdout: '0.3.0' };
    throw new Error('permission denied');
  };

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0', detectSource: () => 'npm' });

  assert.equal(ok, false);
  assert.deepEqual(messages, [
    'Current version: v0.2.0',
    'Updating to v0.3.0...',
  ]);
});

// —— verifyEffectiveVersion / install 后自检 ————————————————————————

// 模拟 npm 全局布局：包体在 lib/node_modules/tmuxclihook/，PATH 入口是
// bin/tmuxclihook → 包内 cli.js 的 symlink（realpath 落在包内，向上可找到 package.json）
function makeFakeInstall(root, version) {
  const pkgDir = join(root, 'lib', 'node_modules', 'tmuxclihook');
  const entryBin = join(root, 'bin');
  mkdirSync(join(pkgDir, 'bin'), { recursive: true });
  mkdirSync(entryBin, { recursive: true });
  const cli = join(pkgDir, 'bin', 'cli.js');
  writeFileSync(cli, '#!/usr/bin/env node\n');
  chmodSync(cli, 0o755);
  writeFileSync(join(pkgDir, 'package.json'), JSON.stringify({ name: 'tmuxclihook', version }));
  const entry = join(entryBin, 'tmuxclihook');
  symlinkSync(cli, entry);
  return entry;
}

function withTempRoot(name, fn) {
  const root = mkdtempSync(join(tmpdir(), `tmuxclihook-${name}-`));
  try {
    return fn(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

// 异步版：withTempRoot 直接 return fn(root)，若 fn 返回 Promise，finally
// 会在 Promise 完成前删目录。异步测试（repairWithVolta 等）必须用这个。
async function withTempRootAsync(name, fn) {
  const root = mkdtempSync(join(tmpdir(), `tmuxclihook-${name}-`));
  try {
    return await fn(root);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function makeExecutable(path, content = '#!/bin/sh\n') {
  writeFileSync(path, content);
  chmodSync(path, 0o755);
  return path;
}

test('verifyEffectiveVersion reads version from npm-style PATH entry', () => {
  withTempRoot('ok', (root) => {
    const entry = makeFakeInstall(root, '1.2.3');
    const result = verifyEffectiveVersion('1.2.3', { PATH: join(root, 'bin') });
    assert.equal(result.status, 'ok');
    assert.equal(result.version, '1.2.3');
    assert.equal(result.path, entry);
  });
});

test('verifyEffectiveVersion reports mismatch when PATH entry is outdated', () => {
  withTempRoot('mismatch', (root) => {
    makeFakeInstall(root, '1.0.0');
    const result = verifyEffectiveVersion('1.2.3', { PATH: join(root, 'bin') });
    assert.equal(result.status, 'mismatch');
    assert.equal(result.version, '1.0.0');
  });
});

test('verifyEffectiveVersion falls back to volta image for shim entries', () => {
  withTempRoot('volta', (root) => {
    // PATH 命中的是不可判读的 shim 二进制（上层无 package.json）
    const shimDir = join(root, 'shim');
    mkdirSync(shimDir, { recursive: true });
    const shim = join(shimDir, 'tmuxclihook');
    writeFileSync(shim, 'fake-binary');
    chmodSync(shim, 0o755);
    // volta 镜像里是新版
    const pkgDir = join(root, 'volta', 'tools', 'image', 'packages', 'tmuxclihook', 'lib', 'node_modules', 'tmuxclihook');
    mkdirSync(pkgDir, { recursive: true });
    writeFileSync(join(pkgDir, 'package.json'), JSON.stringify({ name: 'tmuxclihook', version: '1.2.3' }));

    const result = verifyEffectiveVersion('1.2.3', { PATH: shimDir, VOLTA_HOME: join(root, 'volta'), HOME: root });
    assert.equal(result.status, 'ok');
    assert.equal(result.version, '1.2.3');
  });
});

test('verifyEffectiveVersion reports mismatch when volta image is behind', () => {
  withTempRoot('volta-old', (root) => {
    const shimDir = join(root, 'shim');
    mkdirSync(shimDir, { recursive: true });
    const shim = join(shimDir, 'tmuxclihook');
    writeFileSync(shim, 'fake-binary');
    chmodSync(shim, 0o755);
    const pkgDir = join(root, 'volta', 'tools', 'image', 'packages', 'tmuxclihook', 'lib', 'node_modules', 'tmuxclihook');
    mkdirSync(pkgDir, { recursive: true });
    writeFileSync(join(pkgDir, 'package.json'), JSON.stringify({ name: 'tmuxclihook', version: '1.0.0' }));

    const result = verifyEffectiveVersion('1.2.3', { PATH: shimDir, VOLTA_HOME: join(root, 'volta'), HOME: root });
    assert.equal(result.status, 'mismatch');
    assert.equal(result.version, '1.0.0');
  });
});

test('verifyEffectiveVersion reports unknown when shim has no volta image', () => {
  withTempRoot('unknown', (root) => {
    const shimDir = join(root, 'shim');
    mkdirSync(shimDir, { recursive: true });
    const shim = join(shimDir, 'tmuxclihook');
    writeFileSync(shim, 'fake-binary');
    chmodSync(shim, 0o755);

    const result = verifyEffectiveVersion('1.2.3', { PATH: shimDir, VOLTA_HOME: join(root, 'volta'), HOME: root });
    assert.equal(result.status, 'unknown');
    assert.equal(result.version, null);
    assert.equal(result.path, shim);
  });
});

test('verifyEffectiveVersion reports unknown when nothing on PATH', () => {
  const result = verifyEffectiveVersion('1.2.3', { PATH: '' });
  assert.equal(result.status, 'unknown');
  assert.equal(result.path, null);
});

test('updatePackage warns when post-install verification fails without volta', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  const verify = async () => ({ status: 'mismatch', path: '/fake/tmuxclihook', version: '1.0.0' });

  const ok = await updatePackage({ run, log, currentVersion: '1.0.0', verify, repairVolta: null, detectSource: () => 'npm' });

  assert.equal(ok, true);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Warning: the tmuxclihook command on your PATH (/fake/tmuxclihook) did not reflect the new version (still v1.0.0).',
    'If you use volta, run: volta install tmuxclihook@latest',
  ]);
});

test('updatePackage upgrades via volta only when the effective entry is volta', async () => {
  const { log, messages } = captureLog();
  const calls = [];
  const run = async (command, args) => {
    calls.push([command, args]);
    return { stdout: '1.2.3\n' };
  };
  const timeline = [];
  const env = { PATH: '/fake/volta/bin', VOLTA_HOME: '/fake/volta' };
  const detectSource = (receivedEnv) => {
    timeline.push('detect');
    assert.equal(receivedEnv, env);
    return 'volta';
  };
  const verify = async (latest, receivedEnv) => {
    timeline.push('verify');
    assert.equal(receivedEnv, env);
    return { status: 'ok', path: '/fake/volta-shim', version: '1.2.3' };
  };
  const repairVolta = async (runFn, logFn, receivedEnv) => {
    timeline.push('repair');
    assert.equal(receivedEnv, env);
    return true;
  };

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', env, detectSource, verify, repairVolta,
  });

  assert.equal(ok, true);
  // 关键回归断言：volta 分支绝不执行 npm install -g（否则又产生第二份副本）
  assert.deepEqual(calls, [['npm', ['view', 'tmuxclihook', 'version']]]);
  assert.deepEqual(timeline, ['detect', 'repair', 'verify']);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Verified: tmuxclihook on your PATH now resolves to v1.2.3.',
  ]);
});

test('updatePackage does not repeat volta install when verification still fails', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  let repairs = 0;
  const verify = async () => ({ status: 'unknown', path: '/fake/tmuxclihook', version: null });
  const repairVolta = async () => { repairs += 1; return true; };

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', detectSource: () => 'volta', verify, repairVolta,
  });

  assert.equal(ok, true);
  assert.equal(repairs, 1, 'volta 分支不应在 verify 失败后再次 repair');
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Warning: the tmuxclihook command on your PATH (/fake/tmuxclihook) did not reflect the new version.',
    'If you use volta, run: volta install tmuxclihook@latest',
  ]);
});

test('repairWithVolta detects volta stub and runs volta install', async () => {
  await withTempRootAsync('repair', async (root) => {
    const bin = join(root, 'bin');
    mkdirSync(bin, { recursive: true });
    const voltaStub = join(bin, 'volta');
    writeFileSync(voltaStub, '#!/bin/sh\n');
    chmodSync(voltaStub, 0o755);

    const calls = [];
    const run = async (command, args) => { calls.push([command, args]); return { stdout: '' }; };
    const messages = [];
    const log = { log: (m) => messages.push(m), error: (m) => messages.push(m) };

    const ok = await repairWithVolta(run, log, { PATH: bin, HOME: root });
    assert.equal(ok, true);
    assert.deepEqual(calls, [['volta', ['install', 'tmuxclihook@latest']]]);
    assert.deepEqual(messages, ['Detected volta on this machine; applying the update via volta install...']);
  });
});

test('repairWithVolta returns false when volta is absent', async () => {
  await withTempRootAsync('no-volta', async (root) => {
    const calls = [];
    const run = async (...args) => { calls.push(args); return { stdout: '' }; };
    const messages = [];
    const log = { log: (m) => messages.push(m), error: (m) => messages.push(m) };

    const ok = await repairWithVolta(run, log, { PATH: '', HOME: root });
    assert.equal(ok, false);
    assert.deepEqual(calls, []);
    assert.deepEqual(messages, []);
  });
});

test('updatePackage confirms when post-install verification passes', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  const verify = async () => ({ status: 'ok', path: '/fake/tmuxclihook', version: '1.2.3' });

  const ok = await updatePackage({ run, log, currentVersion: '1.0.0', verify, repairVolta: null, detectSource: () => 'npm' });

  assert.equal(ok, true);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Verified: tmuxclihook on your PATH now resolves to v1.2.3.',
  ]);
});

// —— detectInstallSource：跟随 PATH 上第一个可执行入口 ————————————

test('detectInstallSource recognizes a volta bin shim', () => {
  withTempRoot('detect-volta-bin', (root) => {
    const voltaHome = join(root, 'volta');
    const bin = join(voltaHome, 'bin');
    mkdirSync(bin, { recursive: true });
    makeExecutable(join(bin, 'tmuxclihook'));
    assert.equal(detectInstallSource({ PATH: bin, VOLTA_HOME: voltaHome, HOME: root }), 'volta');
  });
});

test('detectInstallSource recognizes a direct packages image entry', () => {
  withTempRoot('detect-volta-pkg', (root) => {
    const voltaHome = join(root, 'volta');
    const bin = join(voltaHome, 'tools', 'image', 'packages', 'tmuxclihook', 'bin');
    mkdirSync(bin, { recursive: true });
    makeExecutable(join(bin, 'tmuxclihook'));
    assert.equal(detectInstallSource({ PATH: bin, VOLTA_HOME: voltaHome, HOME: root }), 'volta');
  });
});

test('detectInstallSource recognizes a symlink that resolves to volta-shim', () => {
  withTempRoot('detect-shim-realpath', (root) => {
    const shimDir = join(root, 'cellar', 'volta', 'bin');
    mkdirSync(shimDir, { recursive: true });
    const shim = makeExecutable(join(shimDir, 'volta-shim'), 'fake-binary');
    const bin = join(root, 'bin');
    mkdirSync(bin, { recursive: true });
    symlinkSync(shim, join(bin, 'tmuxclihook'));
    // 没有 VOLTA_HOME 也无妨：realpath basename 命中 volta-shim
    assert.equal(detectInstallSource({ PATH: bin, HOME: root }), 'volta');
  });
});

test('detectInstallSource treats npm-style layouts as npm', () => {
  withTempRoot('detect-npm', (root) => {
    makeFakeInstall(root, '1.2.3');
    assert.equal(detectInstallSource({ PATH: join(root, 'bin'), HOME: root }), 'npm');
  });
});

test('detectInstallSource treats nvm-style toolchain dirs as npm', () => {
  withTempRoot('detect-nvm', (root) => {
    const bin = join(root, '.nvm', 'versions', 'node', 'v22.0.0', 'bin');
    mkdirSync(bin, { recursive: true });
    makeExecutable(join(bin, 'tmuxclihook'));
    assert.equal(detectInstallSource({ PATH: bin, HOME: root }), 'npm');
  });
});

test('detectInstallSource returns unknown when nothing is on PATH', () => {
  assert.equal(detectInstallSource({ PATH: '' }), 'unknown');
  assert.equal(detectInstallSource({}), 'unknown');
  assert.equal(detectInstallSource({ PATH: undefined }), 'unknown');
});

test('detectInstallSource follows the first executable entry in PATH', () => {
  withTempRoot('detect-order', (root) => {
    const voltaHome = join(root, 'volta');
    const voltaBin = join(voltaHome, 'bin');
    const npmBin = join(root, 'npm-bin');
    mkdirSync(voltaBin, { recursive: true });
    mkdirSync(npmBin, { recursive: true });
    makeExecutable(join(voltaBin, 'tmuxclihook'));
    makeExecutable(join(npmBin, 'tmuxclihook'));

    const env = { HOME: root, VOLTA_HOME: voltaHome };
    assert.equal(detectInstallSource({ ...env, PATH: [voltaBin, npmBin].join(delimiter) }), 'volta');
    assert.equal(detectInstallSource({ ...env, PATH: [npmBin, voltaBin].join(delimiter) }), 'npm');
  });
});

test('detectInstallSource honors the VOLTA_HOME override', () => {
  withTempRoot('detect-volta-home', (root) => {
    const customHome = join(root, 'custom-volta');
    const bin = join(customHome, 'bin');
    mkdirSync(bin, { recursive: true });
    makeExecutable(join(bin, 'tmuxclihook'));
    assert.equal(
      detectInstallSource({ PATH: bin, VOLTA_HOME: customHome, HOME: join(root, 'home') }),
      'volta',
    );
  });
});

// —— updatePackage：按来源分派升级 ————————————————————————————————

test('updatePackage falls back to npm when the source is unknown', async () => {
  const calls = [];
  const { log } = captureLog();
  const run = async (command, args, options) => {
    calls.push([command, args, options]);
    return { stdout: '1.2.3\n' };
  };

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', detectSource: () => 'unknown', verify: null, repairVolta: null,
  });

  assert.equal(ok, true);
  assert.deepEqual(calls, [
    ['npm', ['view', 'tmuxclihook', 'version'], undefined],
    ['npm', ['install', '-g', 'tmuxclihook@latest'], { stdio: 'inherit' }],
  ]);
});

test('updatePackage returns failure when the volta upgrade fails', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  let verifyCalled = false;
  const verify = async () => {
    verifyCalled = true;
    return { status: 'ok', path: null, version: '1.2.3' };
  };
  const repairVolta = async () => false;

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', detectSource: () => 'volta', verify, repairVolta,
  });

  assert.equal(ok, false);
  assert.equal(verifyCalled, false, 'volta 升级失败后不应继续自检');
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Failed to update via volta. Please check your volta installation.',
  ]);
});

test('updatePackage does not invoke volta when npm verification passes', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  let repairs = 0;
  const verify = async () => ({ status: 'ok', path: '/fake/tmuxclihook', version: '1.2.3' });
  const repairVolta = async () => { repairs += 1; return true; };

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', detectSource: () => 'npm', verify, repairVolta,
  });

  assert.equal(ok, true);
  assert.equal(repairs, 0, 'npm 来源且自检通过时不应写入 volta 镜像');
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Verified: tmuxclihook on your PATH now resolves to v1.2.3.',
  ]);
});

test('updatePackage retries via volta when npm verification fails', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  const timeline = [];
  let verifyCount = 0;
  const verify = async () => {
    verifyCount += 1;
    timeline.push(`verify${verifyCount}`);
    return verifyCount === 1
      ? { status: 'mismatch', path: '/fake/tmuxclihook', version: '1.0.0' }
      : { status: 'ok', path: '/fake/tmuxclihook', version: '1.2.3' };
  };
  const repairVolta = async () => { timeline.push('repair'); return true; };

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', detectSource: () => 'npm', verify, repairVolta,
  });

  assert.equal(ok, true);
  assert.deepEqual(timeline, ['verify1', 'repair', 'verify2']);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Verified: tmuxclihook on your PATH now resolves to v1.2.3.',
  ]);
});

test('updatePackage warns when the volta fallback is unavailable', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  let repairs = 0;
  const verify = async () => ({ status: 'mismatch', path: '/fake/tmuxclihook', version: '1.0.0' });
  const repairVolta = async () => { repairs += 1; return false; };

  const ok = await updatePackage({
    run, log, currentVersion: '1.0.0', detectSource: () => 'npm', verify, repairVolta,
  });

  assert.equal(ok, true);
  assert.equal(repairs, 1);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Warning: the tmuxclihook command on your PATH (/fake/tmuxclihook) did not reflect the new version (still v1.0.0).',
    'If you use volta, run: volta install tmuxclihook@latest',
  ]);
});
