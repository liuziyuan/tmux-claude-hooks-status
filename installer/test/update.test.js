import test from 'node:test';
import assert from 'node:assert/strict';

import { CURRENT_VERSION, updatePackage } from '../src/update.js';

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

  const ok = await updatePackage({ run, log, currentVersion: '0.2.0' });

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
