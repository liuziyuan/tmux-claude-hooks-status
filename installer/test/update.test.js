import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync, chmodSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

import { CURRENT_VERSION, updatePackage, verifyEffectiveVersion, repairWithVolta } from '../src/update.js';

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

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0' });

  assert.equal(ok, true);
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

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0', verify: null, repairVolta: null });

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

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0' });

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

  const ok = await updatePackage({ run, log, currentVersion: '1.0.0', verify, repairVolta: null });

  assert.equal(ok, true);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Warning: the tmuxclihook command on your PATH (/fake/tmuxclihook) did not reflect the new version (still v1.0.0).',
    'If you use volta, run: volta install tmuxclihook@latest',
  ]);
});

test('updatePackage applies volta repair unconditionally, then verifies once', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  const timeline = [];
  // 自检判 ok 正是真实 bug 场景（0.3.3 → 0.3.4：PATH 第一份是 npm -g 刚写
  // 的那份，verify 必然误判 ok）——volta 生效步骤仍必须执行，修复不能由
  // 自检结果决定
  const verify = async () => {
    timeline.push('verify');
    return { status: 'ok', path: '/fake/volta-shim', version: '1.2.3' };
  };
  const repairVolta = async (runFn, logFn) => {
    timeline.push('repair');
    return true;
  };

  const ok = await updatePackage({ run, log, currentVersion: '1.0.0', verify, repairVolta });

  assert.equal(ok, true);
  assert.deepEqual(timeline, ['repair', 'verify']);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Verified: tmuxclihook on your PATH now resolves to v1.2.3.',
  ]);
});

test('updatePackage warns when volta repair runs but verification still fails', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  const verify = async () => ({ status: 'unknown', path: '/fake/tmuxclihook', version: null });
  const repairVolta = async () => true;

  const ok = await updatePackage({ run, log, currentVersion: '1.0.0', verify, repairVolta });

  assert.equal(ok, true);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Warning: the tmuxclihook command on your PATH (/fake/tmuxclihook) did not reflect the new version.',
    'If you use volta, run: volta install tmuxclihook@latest',
  ]);
});

test('repairWithVolta detects volta stub and runs volta install', () => {
  withTempRoot('repair', (root) => {
    const bin = join(root, 'bin');
    mkdirSync(bin, { recursive: true });
    const voltaStub = join(bin, 'volta');
    writeFileSync(voltaStub, '#!/bin/sh\n');
    chmodSync(voltaStub, 0o755);

    const calls = [];
    const run = async (command, args) => { calls.push([command, args]); return { stdout: '' }; };
    const messages = [];
    const log = { log: (m) => messages.push(m), error: (m) => messages.push(m) };

    return repairWithVolta(run, log, { PATH: bin, HOME: root }).then((ok) => {
      assert.equal(ok, true);
      assert.deepEqual(calls, [['volta', ['install', 'tmuxclihook@latest']]]);
      assert.deepEqual(messages, ['Detected volta on this machine; applying the update via volta install...']);
    });
  });
});

test('repairWithVolta returns false when volta is absent', () => {
  withTempRoot('no-volta', (root) => {
    const calls = [];
    const run = async (...args) => { calls.push(args); return { stdout: '' }; };
    const messages = [];
    const log = { log: (m) => messages.push(m), error: (m) => messages.push(m) };

    return repairWithVolta(run, log, { PATH: '', HOME: root }).then((ok) => {
      assert.equal(ok, false);
      assert.deepEqual(calls, []);
      assert.deepEqual(messages, []);
    });
  });
});

test('updatePackage confirms when post-install verification passes', async () => {
  const { log, messages } = captureLog();
  const run = async () => ({ stdout: '1.2.3\n' });
  const verify = async () => ({ status: 'ok', path: '/fake/tmuxclihook', version: '1.2.3' });

  const ok = await updatePackage({ run, log, currentVersion: '1.0.0', verify, repairVolta: null });

  assert.equal(ok, true);
  assert.deepEqual(messages, [
    'Current version: v1.0.0',
    'Updating to v1.2.3...',
    'Done. Updated to v1.2.3',
    'Verified: tmuxclihook on your PATH now resolves to v1.2.3.',
  ]);
});
