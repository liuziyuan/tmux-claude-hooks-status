import test from 'node:test';
import assert from 'node:assert/strict';

import {
  displayWidth,
  note,
  padDisplay,
  renderNote,
  wrapDisplay,
} from '../src/tui.js';

const shellMessage =
  '  当前交互 shell：zsh（/bin/zsh）\n' +
  '  说明：hook 脚本 shebang 为 #!/bin/bash，由 AI CLI 触发时以 bash 执行，\n' +
  '        与你的交互 shell（zsh）无关。macOS 自带 bash 3.2 即可，无需升级。';

function boxLines(output) {
  return output.split('\n').filter((line) => /[◇│├]/u.test(line));
}

test('displayWidth measures CJK, combining marks, emoji, and ANSI by terminal columns', () => {
  assert.equal(displayWidth('shell 说明'), 10);
  assert.equal(displayWidth('e\u0301'), 1);
  assert.equal(displayWidth('👩‍💻'), 2);
  assert.equal(displayWidth('⚠'), 1);
  assert.equal(displayWidth('⚠️'), 2);
  assert.equal(displayWidth('\u001B[31m中文A\u001B[0m'), 5);
});

test('padDisplay pads to visible columns rather than JavaScript string length', () => {
  const padded = padDisplay('环境', 6);
  assert.equal(padded, '环境  ');
  assert.equal(displayWidth(padded), 6);
});

test('wrapDisplay wraps mixed CJK and ASCII without splitting grapheme clusters', () => {
  assert.deepEqual(wrapDisplay('ab中文👩‍💻cd', 6), ['ab中文', '👩‍💻cd']);
  assert.deepEqual(wrapDisplay('e\u0301e\u0301e\u0301', 2), ['e\u0301e\u0301', 'e\u0301']);
});

test('wrapDisplay prefers word boundaries and can indent continuation lines', () => {
  assert.deepEqual(wrapDisplay('abc def', 6), ['abc', 'def']);
  assert.deepEqual(
    wrapDisplay('  AI CLI status', 8, { continuationIndent: '  ' }),
    ['  AI CLI', '  status'],
  );
});

test('renderNote keeps every shell note border line aligned', () => {
  const output = renderNote(shellMessage, 'shell 说明', { columns: 100, color: false });
  const lines = boxLines(output).slice(1);
  const widths = lines.map(displayWidth);

  assert.ok(lines.length >= 7);
  assert.equal(new Set(widths).size, 1, `line widths differ: ${widths.join(', ')}`);
  assert.match(lines[0], /^◇  shell 说明 /u);
  assert.match(lines.at(-1), /^├─+╯$/u);
});

test('renderNote wraps long text to terminal width and preserves a closed border', () => {
  const output = renderNote(shellMessage, 'shell 说明', { columns: 50, color: false });
  const lines = boxLines(output).slice(1);

  assert.ok(lines.length > 7, 'expected long shell explanation to wrap');
  assert.ok(lines.every((line) => displayWidth(line) === 50));
  assert.ok(lines.slice(1, -1).every((line) => line.startsWith('│') && line.endsWith('│')));
  assert.match(lines.at(-1), /^├─+╯$/u);
});

test('renderNote never overflows very narrow terminals with deeply indented CJK', () => {
  const output = renderNote('        中文内容', '窄终端', { columns: 13, color: false });
  const lines = boxLines(output).slice(1);

  assert.ok(lines.every((line) => displayWidth(line) === 13));
});

test('note writes a terminal-width-aware card to the provided stream', () => {
  let output = '';
  const stream = {
    columns: 40,
    write(chunk) { output += chunk; },
  };

  note('中文 mixed content that needs wrapping', '环境依赖', {
    stream,
    color: false,
  });

  const lines = boxLines(output).slice(1);
  assert.ok(lines.every((line) => displayWidth(line) === 40));
});

test('renderNote aligns all current Chinese note titles and representative content', () => {
  const cards = [
    ['环境依赖', '  ✓ tmux   v3.5             (要求 ≥ 3.1)\n  ✓ bash   v3.2             (要求 任意版本)'],
    ['AI CLI', '  ✓ Claude Code    v1.2.3  已装 hooks\n  ✗ Codex          未安装'],
    ['tmux 软链', '  软链 ✓ 指向本仓库\n  .tmux.conf: ✗ 未引用（需手动加 @plugin 或 run）'],
  ];

  for (const [title, message] of cards) {
    const lines = boxLines(renderNote(message, title, { columns: 80, color: false })).slice(1);
    assert.equal(new Set(lines.map(displayWidth)).size, 1, `${title} border is misaligned`);
  }
});
