import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import { HELP_TEXT } from '../src/help.js';

test('help lists every command', () => {
  for (const token of [
    'tmuxclihook check',
    'tmuxclihook update',
    'tmuxclihook update --prune',
    'tmuxclihook version',
    'tmuxclihook help',
    '--version / -v 等价',
    '--help / -h 等价',
  ]) {
    assert.ok(HELP_TEXT.includes(token), `help 缺少：${token}`);
  }
});

test('help lists every tmux binding', () => {
  for (const key of [
    'prefix + I',
    'prefix + C-h',
    'prefix + C-u',
    'prefix + M-h',
    'prefix + M-u',
    'prefix + C-p',
    'prefix + M-p',
    'prefix + r',
  ]) {
    assert.ok(HELP_TEXT.includes(key), `help 缺少快捷键：${key}`);
  }
  assert.ok(HELP_TEXT.includes('Ctrl+b'));
  assert.ok(HELP_TEXT.includes('以你的配置为准'));
});

test('help bindings stay in sync with the tmux entry script', () => {
  const entry = readFileSync(
    fileURLToPath(new URL('../../tmux-ai-hooks-status.tmux', import.meta.url)),
    'utf8',
  );
  // 键位以入口脚本的 bind-key 为准；help 与入口不一致时这条测试会失败。
  for (const key of ['I', 'C-h', 'C-u', 'M-h', 'M-u', 'C-p', 'M-p', 'r']) {
    assert.match(entry, new RegExp(`bind-key\\s+${key}\\b`), `入口脚本缺少 bind-key ${key}`);
  }
});
