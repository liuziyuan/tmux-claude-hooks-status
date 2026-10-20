import test from 'node:test';
import assert from 'node:assert/strict';

import { checkToolDetail, renderToolDetail, summarizeDetails } from '../src/check-detail.js';

const TOOL = {
  id: 'claude',
  label: 'Claude Code',
  installer: '/fake/scripts/install-claude-hooks.sh',
};

// 依赖注入：run mock 返回 execa 风格结果 { stdout, exitCode }；throw 模拟 spawn 失败
function runFrom(result) {
  if (result instanceof Error) {
    return async () => { throw result; };
  }
  return async () => result;
}

const OK_JSON = JSON.stringify({
  tool: 'claude', status: 'ok', mode: 'ccswitch', suppress: false,
  events: { SessionStart: { registered: 1, alive: 1, scriptPaths: ['/a/tmux-ai-status'] } },
  plugin: null,
  registeredPaths: ['/a/tmux-ai-status'],
  drift: { drifted: false, expected: '/a/tmux-ai-status', currentScriptsDir: '/a', stale: [] },
});

test('checkToolDetail parses ok JSON with exit 0', async () => {
  const d = await checkToolDetail(TOOL, { run: runFrom({ stdout: OK_JSON, exitCode: 0 }) });
  assert.equal(d.ok, true);
  assert.equal(d.status, 'ok');
  assert.equal(d.mode, 'ccswitch');
  assert.equal(d.drift.drifted, false);
  assert.equal(d.error, null);
});

test('checkToolDetail parses missing JSON with exit 1', async () => {
  const missing = JSON.stringify({
    tool: 'claude', status: 'missing', mode: 'file', suppress: true,
    events: { SessionStart: { registered: 1, alive: 0, scriptPaths: ['/dead/tmux-ai-status'] } },
    plugin: null,
    registeredPaths: ['/dead/tmux-ai-status'],
    drift: { drifted: true, expected: '/a/tmux-ai-status', currentScriptsDir: '/a', stale: ['/dead/tmux-ai-status'] },
  });
  const d = await checkToolDetail(TOOL, { run: runFrom({ stdout: missing, exitCode: 1 }) });
  assert.equal(d.ok, false);
  assert.equal(d.status, 'missing');
  assert.equal(d.suppress, true);
  assert.equal(d.drift.drifted, true);
});

test('checkToolDetail surfaces jq-missing error JSON as unknown', async () => {
  const errJson = JSON.stringify({
    tool: 'claude', status: 'missing', mode: 'unknown', suppress: false,
    events: {}, plugin: null, registeredPaths: [],
    drift: { drifted: false, expected: '', currentScriptsDir: '/a', stale: [] },
    error: 'jq not found',
  });
  const d = await checkToolDetail(TOOL, { run: runFrom({ stdout: errJson, exitCode: 1 }) });
  assert.equal(d.status, 'unknown');
  assert.equal(d.error, 'jq not found');
});

test('checkToolDetail marks non-JSON output as unknown', async () => {
  const d = await checkToolDetail(TOOL, { run: runFrom({ stdout: 'ok\n', exitCode: 0 }) });
  assert.equal(d.status, 'unknown');
  assert.match(d.error, /不是合法 JSON/);
});

test('checkToolDetail catches spawn failure', async () => {
  const err = new Error('spawn ENOENT');
  err.shortMessage = 'Command failed: bash /fake/...';
  const d = await checkToolDetail(TOOL, { run: runFrom(err) });
  assert.equal(d.status, 'unknown');
  assert.ok(d.error.includes('Command failed'));
});

test('renderToolDetail renders drift warning with stale paths', () => {
  const lines = renderToolDetail({
    ok: false, status: 'ok', tool: 'claude', label: 'Claude Code', mode: 'file',
    suppress: false, events: {}, plugin: null, registeredPaths: ['/old/tmux-ai-status'],
    drift: { drifted: true, expected: '/a/tmux-ai-status', currentScriptsDir: '/a', stale: ['/old/tmux-ai-status'] },
    error: null,
  });
  const text = lines.join('\n');
  assert.match(text, /hooks 完整/);
  assert.match(text, /漂移/);
  assert.match(text, /\/old\/tmux-ai-status/);
  assert.match(text, /当前 source 路径/);
});

test('renderToolDetail renders missing reasons and suppress marker', () => {
  const lines = renderToolDetail({
    ok: false, status: 'missing', tool: 'claude', label: 'Claude Code', mode: 'ccswitch',
    suppress: true,
    events: {
      SessionStart: { registered: 0, alive: 0, scriptPaths: [] },
      PreToolUse: { registered: 1, alive: 0, scriptPaths: ['/dead/x'] },
    },
    plugin: null, registeredPaths: [], drift: null, error: null,
  });
  const text = lines.join('\n');
  assert.match(text, /缺失或损坏/);
  assert.match(text, /cc-switch/);
  assert.match(text, /suppressed-claude/);
  assert.match(text, /SessionStart：未注册/);
  assert.match(text, /PreToolUse：脚本不可执行/);
});

test('renderToolDetail renders opencode plugin anomalies', () => {
  const lines = renderToolDetail({
    ok: false, status: 'missing', tool: 'opencode', label: 'opencode', mode: 'plugin',
    suppress: false, events: {},
    plugin: {
      path: '/p/tmux-ai-status.ts', exists: true, marker: true,
      hookScript: '/dead/tmux-ai-status', hookScriptAlive: false,
      structure: { permissionAsked: true, questionAsked: false, permissionReplied: true, requestId: true },
    },
    registeredPaths: [], drift: null, error: null,
  });
  const text = lines.join('\n');
  assert.match(text, /HOOK_SCRIPT 不可执行/);
  assert.match(text, /questionAsked/);
});

test('summarizeDetails aggregates missing/drift/error', () => {
  const mk = (over) => ({ status: 'ok', drift: { drifted: false }, ...over });
  assert.deepEqual(summarizeDetails([mk()]), { hasMissing: false, hasDrift: false, hasError: false });
  assert.equal(summarizeDetails([mk({ status: 'missing' })]).hasMissing, true);
  assert.equal(summarizeDetails([mk({ drift: { drifted: true } })]).hasDrift, true);
  assert.equal(summarizeDetails([mk({ status: 'unknown' })]).hasError, true);
});

test('checkToolDetail parses codex trust dimension', async () => {
  const json = JSON.stringify({
    tool: 'codex', status: 'ok', mode: 'file', suppress: false, events: {},
    plugin: null, registeredPaths: [],
    trust: {
      configFile: '/h/.codex/config.toml', trusted: false, missingEvents: ['stop'],
      instances: [
        { configFile: '/h/.codex/config.toml', hooksFile: '/h/.codex/hooks.json', trusted: false, missingEvents: ['stop'] },
        { configFile: '/h/.cc-switch/instances/codex/a/config.toml', hooksFile: '/h/.cc-switch/instances/codex/a/hooks.json', trusted: false, missingEvents: ['session_start', 'stop'] },
      ],
    },
    drift: { drifted: false, expected: '/a/tmux-ai-status', currentScriptsDir: '/a', stale: [] },
  });
  const d = await checkToolDetail({ ...TOOL, id: 'codex' }, { run: runFrom({ stdout: json, exitCode: 0 }) });
  assert.equal(d.trust.trusted, false);
  assert.deepEqual(d.trust.missingEvents, ['stop']);
  assert.equal(d.trust.instances.length, 2);
});

test('renderToolDetail renders untrusted hooks and other instances', () => {
  const lines = renderToolDetail({
    ok: true, status: 'ok', tool: 'codex', label: 'Codex', mode: 'file',
    suppress: false, events: {}, plugin: null, registeredPaths: [], drift: null, error: null,
    trust: {
      configFile: '/h/.codex/config.toml', trusted: false, missingEvents: ['stop'],
      instances: [
        { configFile: '/h/.codex/config.toml', trusted: false, missingEvents: ['stop'] },
        { configFile: '/h/.cc-switch/instances/codex/a/config.toml', trusted: false, missingEvents: ['session_start'] },
      ],
    },
  });
  const text = lines.join('\n');
  assert.match(text, /hooks 未授信/);
  assert.match(text, /Trust all/);
  assert.match(text, /其他实例未授信/);
  assert.match(text, /instances\/codex\/a/);
});

test('renderToolDetail renders trust record / unknown states', () => {
  const mk = (trust) => ({
    ok: true, status: 'ok', tool: 'codex', label: 'Codex', mode: 'file', suppress: false,
    events: {}, plugin: null, registeredPaths: [], drift: null, error: null, trust,
  });
  assert.match(
    renderToolDetail(mk({ configFile: '/x', trusted: null, missingEvents: [], instances: [] })).join('\n'),
    /无法判定授信状态/
  );
  assert.match(
    renderToolDetail(mk({ configFile: '/x', trusted: true, missingEvents: [], instances: [] })).join('\n'),
    /授信记录存在/
  );
});
