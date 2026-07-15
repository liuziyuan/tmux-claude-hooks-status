import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  clearSource,
  getPersistedSource,
  isValidSourcePath,
  originLabel,
  resolveSource,
  setSource,
} from '../src/source.js';

// 构造一个含 scripts/ 子目录的临时「合法仓库」目录
function makeRepo(name) {
  const dir = mkdtempSync(join(tmpdir(), `tmuxclihook-${name}-`));
  mkdirSync(join(dir, 'scripts'), { recursive: true });
  return dir;
}

// 构造一个不含 scripts/ 的临时「非法仓库」目录
function makeInvalidRepo(name) {
  return mkdtempSync(join(tmpdir(), `tmuxclihook-${name}-invalid-`));
}

function tmpConfigFile(name) {
  const dir = mkdtempSync(join(tmpdir(), `tmuxclihook-${name}-cfg-`));
  return { configDir: dir, configFile: join(dir, 'config.json') };
}

test('resolveSource prefers env var when it points at a valid repo root', () => {
  const bundled = makeRepo('bundled');
  const devRepo = makeRepo('dev');
  const envRepo = makeRepo('env');
  const { configFile } = tmpConfigFile('env-priority');

  const result = resolveSource({
    env: { TMUXCLIHOOK_SOURCE: envRepo },
    configFile,
    bundledDir: bundled,
    devRepoRoot: devRepo,
  });

  assert.equal(result.origin, 'env');
  assert.equal(result.repoRoot, envRepo);
  assert.equal(result.scriptsDir, join(envRepo, 'scripts'));
  assert.deepEqual(result.warnings, []);
});

test('resolveSource falls back and warns when env var is invalid', () => {
  const bundled = makeRepo('bundled2');
  const devRepo = makeRepo('dev2');
  const invalidEnv = makeInvalidRepo('env2');
  const { configFile } = tmpConfigFile('env-invalid');

  const result = resolveSource({
    env: { TMUXCLIHOOK_SOURCE: invalidEnv },
    configFile,
    bundledDir: bundled,
    devRepoRoot: devRepo,
  });

  assert.equal(result.origin, 'bundled');
  assert.equal(result.repoRoot, bundled);
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /TMUXCLIHOOK_SOURCE/);
});

test('resolveSource uses persisted config when no env var is set', () => {
  const bundled = makeRepo('bundled3');
  const devRepo = makeRepo('dev3');
  const configuredRepo = makeRepo('configured');
  const { configFile, configDir } = tmpConfigFile('config-priority');

  const setResult = setSource(configuredRepo, { configFile, configDir });
  assert.equal(setResult.ok, true);

  const result = resolveSource({
    env: {},
    configFile,
    bundledDir: bundled,
    devRepoRoot: devRepo,
  });

  assert.equal(result.origin, 'config');
  assert.equal(result.repoRoot, configuredRepo);
});

test('resolveSource falls back to bundled when persisted config points at a now-invalid path, with warning', () => {
  const bundled = makeRepo('bundled4');
  const devRepo = makeRepo('dev4');
  const { configFile, configDir } = tmpConfigFile('config-invalid');
  mkdirSync(configDir, { recursive: true });

  // setSource 本身会拒绝非法路径，这里模拟「曾经合法、后来被删除/移动」的陈旧配置：
  // 直接写文件绕过校验，复现 resolveSource 自身对已保存 source 的二次校验路径。
  const goneDir = join(mkdtempSync(join(tmpdir(), 'tmuxclihook-gone-')), 'moved-away');
  writeFileSync(configFile, JSON.stringify({ source: goneDir }));

  const result = resolveSource({
    env: {},
    configFile,
    bundledDir: bundled,
    devRepoRoot: devRepo,
  });

  assert.equal(result.origin, 'bundled');
  assert.equal(result.repoRoot, bundled);
  assert.equal(result.warnings.length, 1);
  assert.match(result.warnings[0], /已保存的 source/);
});

test('resolveSource falls back to dev repo root when neither env, config, nor bundled are valid', () => {
  const invalidBundled = makeInvalidRepo('bundled5');
  const devRepo = makeRepo('dev5');
  const { configFile } = tmpConfigFile('dev-fallback');

  const result = resolveSource({
    env: {},
    configFile,
    bundledDir: invalidBundled,
    devRepoRoot: devRepo,
  });

  assert.equal(result.origin, 'repo');
  assert.equal(result.repoRoot, devRepo);
});

test('setSource rejects paths without a scripts/ directory and does not write', () => {
  const invalid = makeInvalidRepo('reject');
  const { configFile, configDir } = tmpConfigFile('reject');

  const result = setSource(invalid, { configFile, configDir });

  assert.equal(result.ok, false);
  assert.equal(existsSync(configFile), false);
});

test('setSource persists a valid repo root and getPersistedSource reads it back', () => {
  const repo = makeRepo('persist');
  const { configFile, configDir } = tmpConfigFile('persist');

  const result = setSource(repo, { configFile, configDir });
  assert.equal(result.ok, true);
  assert.equal(result.source, repo);

  const persisted = getPersistedSource({ configFile });
  assert.equal(persisted, repo);

  const raw = JSON.parse(readFileSync(configFile, 'utf8'));
  assert.equal(raw.source, repo);
});

test('clearSource removes the persisted config file', () => {
  const repo = makeRepo('clear');
  const { configFile, configDir } = tmpConfigFile('clear');
  setSource(repo, { configFile, configDir });
  assert.equal(existsSync(configFile), true);

  const result = clearSource({ configFile });
  assert.equal(result.ok, true);
  assert.equal(existsSync(configFile), false);
});

test('clearSource is a no-op when there is nothing to clear', () => {
  const { configFile } = tmpConfigFile('clear-noop');
  const result = clearSource({ configFile });
  assert.equal(result.ok, true);
});

test('isValidSourcePath reflects presence of scripts/ subdirectory', () => {
  const valid = makeRepo('valid-check');
  const invalid = makeInvalidRepo('invalid-check');
  assert.equal(isValidSourcePath(valid), true);
  assert.equal(isValidSourcePath(invalid), false);
  assert.equal(isValidSourcePath(''), false);
});

test('originLabel provides a human readable label for known origins and falls back to raw value', () => {
  assert.equal(originLabel('env'), '环境变量 TMUXCLIHOOK_SOURCE');
  assert.equal(originLabel('bundled'), '包内自带（生产默认）');
  assert.equal(originLabel('unknown-origin'), 'unknown-origin');
});
