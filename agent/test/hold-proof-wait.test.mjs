import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { until } from './hold-proof-check.mjs';

// The image check's waits (hold-proof-check.mjs). Run 9984 failed one on a
// loaded runner: the browser's socket came after the 8 s it allowed.
test('a wait outlasts a slow boot and wakes on the file appearing, in a folder made later', async t => {
  const root = await mkdtemp('/dev/shm/hold-proof-wait-');
  t.after(() => rm(root, { recursive: true, force: true }));
  const socket = `${root}/browser/cdp.sock`;
  const slowBoot = delay(9_000).then(async () => { await mkdir(`${root}/browser`); await writeFile(socket, ''); });

  const started = Date.now();
  assert.equal(await until('browser trust installed', () => existsSync(socket), { changes: root }), true);
  assert(Date.now() - started >= 9_000);
  await slowBoot;
});

test('a wait ends when the computer exits, after one last look', async () => {
  let exited;
  const failed = new Promise(resolve => { exited = resolve; });
  const waiting = until('hold proxy', () => false, { failed });
  exited('the computer exited');
  await assert.rejects(waiting, { message: 'hold proxy: the computer exited' });

  let up = false;
  const late = until('stopped proxy', () => up, { failed: Promise.resolve('the computer exited').finally(() => { up = true; }) });
  assert.equal(await late, true, 'what came true as the computer exited still counts');
});
