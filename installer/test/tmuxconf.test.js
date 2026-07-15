import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { ensureTmuxIntegration } from '../src/tmuxconf.js';

function tmpConfPath(name) {
  const dir = mkdtempSync(join(tmpdir(), `tmuxconf-${name}-`));
  return join(dir, '.tmux.conf');
}

const ENTRY_A = '/opt/homebrew/lib/node_modules/tmuxclihook/tmux-ai-hooks-status.tmux';
const ENTRY_B = '/Users/dev/work/tmux-claude-hooks-status/tmux-ai-hooks-status.tmux';

test('ensureTmuxIntegration creates .tmux.conf with the run-shell line when the file is missing', () => {
  const path = tmpConfPath('missing');
  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });

  assert.equal(result.ok, true);
  assert.equal(result.action, 'created');
  assert.equal(readFileSync(path, 'utf8'), `run-shell '${ENTRY_A}'\n`);
});

test('ensureTmuxIntegration appends the run-shell line to an existing file without one', () => {
  const path = tmpConfPath('append');
  writeFileSync(path, 'set -g status on\nset -g mouse on\n');

  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });

  assert.equal(result.ok, true);
  assert.equal(result.action, 'appended');
  const raw = readFileSync(path, 'utf8');
  assert.equal(raw, `set -g status on\nset -g mouse on\nrun-shell '${ENTRY_A}'\n`);
});

test('ensureTmuxIntegration adds a trailing newline before appending when file lacks one', () => {
  const path = tmpConfPath('append-no-newline');
  writeFileSync(path, 'set -g mouse on');

  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });

  assert.equal(result.action, 'appended');
  assert.equal(readFileSync(path, 'utf8'), `set -g mouse on\nrun-shell '${ENTRY_A}'\n`);
});

test('ensureTmuxIntegration is a no-op when the exact current line already exists', () => {
  const path = tmpConfPath('noop');
  writeFileSync(path, `set -g mouse on\nrun-shell '${ENTRY_A}'\n`);

  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });

  assert.equal(result.ok, true);
  assert.equal(result.action, 'noop');
  assert.equal(readFileSync(path, 'utf8'), `set -g mouse on\nrun-shell '${ENTRY_A}'\n`);
});

test('ensureTmuxIntegration replaces a stale run-shell line pointing at a previous source path', () => {
  const path = tmpConfPath('replace');
  writeFileSync(path, `set -g mouse on\nrun-shell '${ENTRY_B}'\nset -g status on\n`);

  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });

  assert.equal(result.ok, true);
  assert.equal(result.action, 'replaced');
  const raw = readFileSync(path, 'utf8');
  assert.equal(raw, `set -g mouse on\nrun-shell '${ENTRY_A}'\nset -g status on\n`);
  assert.ok(!raw.includes(ENTRY_B));
});

test('ensureTmuxIntegration leaves legacy TPM @plugin declarations untouched and appends the new line', () => {
  const path = tmpConfPath('legacy');
  writeFileSync(path, "set -g @plugin 'tmux-ai-hooks-status'\nset -g @plugin 'tmux-plugins/tpm'\nrun '~/.tmux/plugins/tpm/tpm'\n");

  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });

  assert.equal(result.action, 'appended');
  const raw = readFileSync(path, 'utf8');
  assert.ok(raw.includes("set -g @plugin 'tmux-ai-hooks-status'"));
  assert.ok(raw.includes("run '~/.tmux/plugins/tpm/tpm'"));
  assert.ok(raw.includes(`run-shell '${ENTRY_A}'`));
});

test('ensureTmuxIntegration reports failure gracefully without throwing on write errors', () => {
  // 指向一个不可能写入的路径（父目录不存在且不会被创建）
  const path = join('/nonexistent-root-for-test', 'nested', '.tmux.conf');
  const result = ensureTmuxIntegration({ tmuxEntry: ENTRY_A, path });
  assert.equal(result.ok, false);
  assert.ok(result.output);
});
