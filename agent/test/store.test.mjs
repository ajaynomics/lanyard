import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx, createRuntime } from '../runtime.mjs';
import { App } from '../state.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const cli = new URL('../store.mjs', import.meta.url).pathname;
// A real child process with no inherited environment: no provider key, no tokens.
function run(...args) {
  return new Promise(resolve => execFile(process.execPath, ['--no-warnings', cli, ...args], { env: { PATH: '/usr/bin:/bin' } },
    (error, stdout, stderr) => resolve({ code: error ? error.code : 0, out: JSON.parse((stdout || stderr).trim().split('\n').at(-1)) })));
}
const scope = { actorId: 'alice', workspaceId: 'one' };
const question = message(call('question', { tabs: [{ title: 'Keep?', options: [{ id: 'yes', label: 'Yes' }] }] }), { stopReason: 'toolUse' });
const deps = (cwd, responses) => ({ ...scriptedProvider(responses),
  authorize: async requested => ({ ...requested, allowed: true, cwd }), railsEffect: async () => ({}) });

test('store CLI imports no provider, harness or extension module', async () => {
  for (const file of ['../store.mjs', '../ownership.mjs']) {
    const source = await readFile(new URL(file, import.meta.url), 'utf8');
    const imports = [...source.matchAll(/^import .* from '([^']+)'/gm)].map(m => m[1]);
    assert.ok(imports.every(name => name.startsWith('node:') || name === './ownership.mjs'), `${file}: ${imports}`);
  }
});

test('A26 snapshot and restore retained state into a fresh store; restored pending question resumes', async t => {
  const cwd = await privateDir('omakase-store-');
  const storePath = join(cwd, 'state.sqlite');
  const runtime = await createRuntime({ storePath }, deps(cwd, [question]));
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const sub = await runtime.submit(id, { ...scope, requestId: 'ask', content: 'ask' });
  const pending = async r => { for (let i = 0; i < 500; i++) { const p = (await r.snapshot(id, scope)).pendingInputs[0]; if (p) return p; await new Promise(x => setTimeout(x, 10)); } };
  const asked = await pending(runtime);
  assert.ok(asked);

  // Refused while the sidecar owns the store; nothing is written.
  const snapshotPath = join(cwd, 'backup.sqlite');
  assert.deepEqual(await run('snapshot', storePath, snapshotPath), { code: 1, out: { category: 'store_already_owned' } });
  await assert.rejects(access(snapshotPath));
  await runtime.close();

  const made = await run('snapshot', storePath, snapshotPath);
  assert.equal(made.code, 0);
  assert.equal(made.out.category, 'snapshot_complete');
  const manifest = JSON.parse(await readFile(`${snapshotPath}.manifest.json`, 'utf8'));
  assert.equal(manifest.integrity, 'ok');
  assert.equal(manifest.sha256, made.out.sha256);
  assert.deepEqual(await run('snapshot', storePath, snapshotPath), { code: 1, out: { category: 'snapshot_exists' } });

  // Restore refuses an existing store, then succeeds into a fresh path.
  assert.deepEqual(await run('restore', snapshotPath, storePath), { code: 1, out: { category: 'store_exists' } });
  const restoredPath = join(cwd, 'restored', 'state.sqlite');
  const restored = await run('restore', snapshotPath, restoredPath);
  assert.equal(restored.code, 0);
  assert.equal(restored.out.sha256, manifest.sha256);

  const reopened = await createRuntime({ storePath: restoredPath }, deps(cwd, [message('kept')]));
  t.after(() => reopened.close());
  const after = await pending(reopened);
  assert.equal(after.id, asked.id);
  // Restore into a store the restored sidecar now owns is refused.
  assert.deepEqual(await run('restore', snapshotPath, restoredPath), { code: 1, out: { category: 'store_already_owned' } });
  await reopened.answer(id, asked.id, { ...scope, answer: { selections: [['yes']] } });
  assert.equal((await (await reopened.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  assert.equal((await reopened.harness.snapshot(App, id, ctx)).requests[asked.id].status, 'answered');
});

test('restore refuses a tampered snapshot, a missing manifest and a non-store file', async () => {
  const cwd = await privateDir('omakase-store-bad-');
  const storePath = join(cwd, 'state.sqlite');
  const runtime = await createRuntime({ storePath }, deps(cwd, []));
  await runtime.create({ ...scope, requestId: 'create' });
  await runtime.close();
  const snapshotPath = join(cwd, 'backup.sqlite');
  assert.equal((await run('snapshot', storePath, snapshotPath)).code, 0);
  const bytes = await readFile(snapshotPath);
  bytes[bytes.length - 100] ^= 0xff;
  await writeFile(snapshotPath, bytes);
  assert.deepEqual(await run('restore', snapshotPath, join(cwd, 'a.sqlite')), { code: 1, out: { category: 'snapshot_digest_mismatch' } });
  await assert.rejects(access(join(cwd, 'a.sqlite')));
  await writeFile(join(cwd, 'loose.sqlite'), 'not sqlite');
  assert.deepEqual(await run('restore', join(cwd, 'loose.sqlite'), join(cwd, 'b.sqlite')), { code: 1, out: { category: 'manifest_missing' } });
  assert.deepEqual(await run('snapshot', join(cwd, 'absent.sqlite'), join(cwd, 'c.sqlite')), { code: 1, out: { category: 'store_missing' } });
  assert.deepEqual(await run('bogus'), { code: 64, out: { category: 'usage' } });
});
