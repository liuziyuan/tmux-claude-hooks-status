import test from 'node:test';
import assert from 'node:assert/strict';

import {
  brewInstall,
  brewManages,
  brewUpgrade,
  hasBrew,
  planBrewRemediation,
  runBrewAction,
} from '../src/env.js';

function result(name, status, min = '任意版本') {
  return {
    name,
    status,
    ok: status === 'ready',
    detail: status,
    min,
    pkg: name,
    fixCmd: `brew install ${name}`,
  };
}

test('hasBrew requires brew --version to exit successfully', async () => {
  const calls = [];
  const yes = await hasBrew({
    runner: async (...args) => {
      calls.push(args);
      return { exitCode: 0 };
    },
  });
  const no = await hasBrew({ runner: async () => ({ exitCode: 1 }) });

  assert.equal(yes, true);
  assert.equal(no, false);
  assert.deepEqual(calls[0].slice(0, 2), ['brew', ['--version']]);
});

test('brewManages checks formula ownership by exit status', async () => {
  const calls = [];
  const managed = await brewManages('tmux', {
    runner: async (...args) => {
      calls.push(args);
      return { exitCode: 0 };
    },
  });
  const unmanaged = await brewManages('node', { runner: async () => ({ exitCode: 1 }) });

  assert.equal(managed, true);
  assert.equal(unmanaged, false);
  assert.deepEqual(calls[0].slice(0, 2), ['brew', ['list', '--versions', 'tmux']]);
});

test('planBrewRemediation installs missing and upgrades only managed outdated formulas', async () => {
  const ownershipChecks = [];
  const plan = await planBrewRemediation([
    result('jq', 'missing'),
    result('tmux', 'outdated', '≥ 3.1'),
    result('node', 'outdated', '≥ 18'),
    result('bash', 'ready'),
  ], {
    brewAvailable: true,
    manages: async (pkg) => {
      ownershipChecks.push(pkg);
      return pkg === 'tmux';
    },
  });

  assert.deepEqual(plan.map(({ name, action, command }) => ({ name, action, command })), [
    { name: 'jq', action: 'install', command: 'brew install jq' },
    { name: 'tmux', action: 'upgrade', command: 'brew upgrade tmux' },
    { name: 'node', action: 'manual', command: null },
  ]);
  assert.deepEqual(ownershipChecks, ['tmux', 'node']);
});

test('planBrewRemediation makes every failed dependency manual when Homebrew is unavailable', async () => {
  let ownershipCalls = 0;
  const plan = await planBrewRemediation([
    result('jq', 'missing'),
    result('tmux', 'outdated', '≥ 3.1'),
    result('bash', 'ready'),
  ], {
    brewAvailable: false,
    manages: async () => {
      ownershipCalls += 1;
      return true;
    },
  });

  assert.deepEqual(plan.map(({ name, action }) => ({ name, action })), [
    { name: 'jq', action: 'manual' },
    { name: 'tmux', action: 'manual' },
  ]);
  assert.equal(ownershipCalls, 0);
});

test('runBrewAction executes allow-listed install and upgrade commands', async () => {
  const calls = [];
  const runner = async (...args) => {
    calls.push(args);
    return { exitCode: 0 };
  };

  assert.deepEqual(await runBrewAction('install', 'jq', { runner }), { ok: true });
  assert.deepEqual(await runBrewAction('upgrade', 'tmux', { runner }), { ok: true });
  assert.deepEqual(calls.map((call) => call.slice(0, 2)), [
    ['brew', ['install', 'jq']],
    ['brew', ['upgrade', 'tmux']],
  ]);
});

test('runBrewAction rejects unsupported actions before spawning', async () => {
  let called = false;
  await assert.rejects(
    runBrewAction('uninstall', 'jq', {
      runner: async () => {
        called = true;
        return { exitCode: 0 };
      },
    }),
    /Unsupported brew action/,
  );
  assert.equal(called, false);
});

test('runBrewAction reports command failures and compatibility wrappers select their action', async () => {
  const failure = await runBrewAction('upgrade', 'tmux', {
    runner: async () => {
      throw Object.assign(new Error('failed'), { shortMessage: 'brew failed' });
    },
  });
  const calls = [];
  const runner = async (...args) => {
    calls.push(args);
    return { exitCode: 0 };
  };

  assert.deepEqual(failure, { ok: false, output: 'brew failed' });
  await brewInstall('jq', null, { runner });
  await brewUpgrade('tmux', null, { runner });
  assert.deepEqual(calls.map((call) => call[1]), [
    ['install', 'jq'],
    ['upgrade', 'tmux'],
  ]);
});
