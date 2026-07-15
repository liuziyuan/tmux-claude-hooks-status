import test from 'node:test';
import assert from 'node:assert/strict';

import { checkEnv } from '../src/detect.js';

function probeFrom(values) {
  return async (bin) => values[bin] ?? { found: false, version: null, raw: null };
}

function indexByName(results) {
  return Object.fromEntries(results.map((result) => [result.name, result]));
}

test('checkEnv classifies missing and outdated dependencies', async () => {
  const results = await checkEnv({
    probeCommand: probeFrom({
      tmux: { found: true, version: '3.0', raw: 'tmux 3.0' },
      jq: { found: false, version: null, raw: null },
      bash: { found: true, version: '3.2', raw: 'GNU bash, version 3.2' },
      node: { found: true, version: '20.15.1', raw: 'v20.15.1' },
    }),
  });
  const byName = indexByName(results);

  assert.equal(byName.tmux.status, 'outdated');
  assert.equal(byName.tmux.ok, false);
  assert.equal(byName.jq.status, 'missing');
  assert.equal(byName.jq.ok, false);
  assert.equal(byName.bash.status, 'ready');
  assert.equal(byName.node.status, 'ready');
});

test('checkEnv marks every satisfied dependency ready and preserves ok compatibility', async () => {
  const results = await checkEnv({
    probeCommand: probeFrom({
      tmux: { found: true, version: '3.5', raw: 'tmux 3.5' },
      jq: { found: true, version: '1.7', raw: 'jq-1.7' },
      bash: { found: true, version: '3.2', raw: 'GNU bash, version 3.2' },
      node: { found: true, version: '22.0.0', raw: 'v22.0.0' },
    }),
  });

  assert.ok(results.every((result) => result.status === 'ready'));
  assert.ok(results.every((result) => result.ok === (result.status === 'ready')));
});
