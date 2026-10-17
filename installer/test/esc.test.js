import test from 'node:test';
import assert from 'node:assert/strict';

import { enableEscapeCancel, setSpinnerActive } from '../src/esc.js';

// 监听合成 keypress（esc.js 的转译产物是 process.stdin.emit('keypress', '\x03', …)）
function captureSynthetic() {
  const seen = [];
  const onKeypress = (ch, key) => {
    if (ch === '\x03') seen.push({ ch, key });
  };
  process.stdin.on('keypress', onKeypress);
  return { seen, restore: () => process.stdin.off('keypress', onKeypress) };
}

test('escape is translated to synthetic ctrl+c, other keys ignored', () => {
  const { seen, restore } = captureSynthetic();
  const off = enableEscapeCancel();
  process.stdin.emit('keypress', '\x1b', { name: 'escape' });
  process.stdin.emit('keypress', 'a', { name: 'a' });
  process.stdin.emit('keypress', '\x1b[A', { name: 'up' });
  off();
  restore();
  assert.equal(seen.length, 1);
  assert.equal(seen[0].key.ctrl, true);
});

test('escape is ignored while spinner active, resumes after', () => {
  const { seen, restore } = captureSynthetic();
  const off = enableEscapeCancel();
  setSpinnerActive(true);
  process.stdin.emit('keypress', '\x1b', { name: 'escape' });
  setSpinnerActive(true);
  process.stdin.emit('keypress', '\x1b', { name: 'escape' }); // 嵌套 spinner 仍静默
  setSpinnerActive(false);
  process.stdin.emit('keypress', '\x1b', { name: 'escape' }); // 还剩一层 → 仍静默
  setSpinnerActive(false);
  process.stdin.emit('keypress', '\x1b', { name: 'escape' }); // 全部结束 → 转译
  off();
  restore();
  assert.equal(seen.length, 1);
});
