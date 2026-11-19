import assert from 'node:assert/strict';
import test from 'node:test';
import { createHash } from 'node:crypto';
import { copyFile, mkdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime } from '../runtime.mjs';
import { definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

// Another install's thread moved in with its workspace (docs/import.md): the
// operator puts a copy of that install's store in this one's storage folder,
// and Rails asks for the thread under this install's ids, naming the thread
// it was there. The model then sees what it saw there, and the copy is only read.
const deps = (provider, cwd) => ({ ...provider, authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {}, isError: false }) });
const wait = async (runtime, sub) => (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
const sha256 = async path => createHash('sha256').update(await readFile(path)).digest('hex');
const texts = messages => messages.filter(m => m.role !== 'system')
  .map(m => typeof m.content === 'string' ? m.content : m.content.filter(b => b.type === 'text').map(b => b.text).join(''));

async function otherInstall(root) {
  const there = { actorId: '7', workspaceId: '3' };
  const source = await createRuntime({ storePath: join(root, 'there', 'durable.sqlite') }, deps(scriptedProvider([message('The books balance.')]), root));
  const { id } = await source.create({ ...there, requestId: 'there-1' });
  await wait(source, await source.submit(id, { ...there, requestId: 'ask', content: 'Do the books balance?', definition: definition() }));
  await source.close();
  await mkdir(join(root, 'import'));
  const store = join(root, 'import', 'agent-durable.sqlite');
  await copyFile(join(root, 'there', 'durable.sqlite'), store);
  return { store, from: id };
}

test('a thread from another install comes with what its model saw, under this install ids', async t => {
  const root = await privateDir('omakase-carry-');
  const { store, from } = await otherInstall(root);
  const before = await sha256(store);
  const seen = [];
  const here = scriptedProvider([context => { seen.push(context.messages); return message('Yes, still.'); }]);
  const runtime = await createRuntime({ storePath: join(root, 'agent', 'durable.sqlite') }, deps(here, root));
  t.after(() => runtime.close());
  const scope = { actorId: '41', workspaceId: '12' };
  const carry = { store, conversationId: from };

  const made = await runtime.create({ ...scope, requestId: 'import-1', carry });

  assert.ok(Number.isSafeInteger(made.carried), 'the entry Rails starts pulling after');
  assert.deepEqual(await runtime.create({ ...scope, requestId: 'import-1', carry }), made, 'a repeat finds the same thread');
  await assert.rejects(runtime.create({ ...scope, requestId: 'import-1', carry: { ...carry, conversationId: from + 1 } }), /request_conflict/);
  assert.deepEqual((await runtime.entries(made.id, scope, String(made.carried))).entries, [], 'Rails already has these as messages');
  await assert.rejects(runtime.snapshot(made.id, { actorId: '7', workspaceId: '3' }), /not_found/, 'the other install ids reach nothing here');

  await wait(runtime, await runtime.submit(made.id, { ...scope, requestId: 'next', content: 'Still?', definition: definition() }));

  assert.deepEqual(texts(seen[0]), ['Do the books balance?', 'The books balance.', 'Still?']);
  assert.equal(await sha256(store), before, 'the copy is never written');
});

test('a carry names a store in this storage folder and a thread it holds', async t => {
  const root = await privateDir('omakase-carry-');
  const { store, from } = await otherInstall(root);
  const runtime = await createRuntime({ storePath: join(root, 'agent', 'durable.sqlite') }, deps(scriptedProvider([]), root));
  t.after(() => runtime.close());
  const scope = { actorId: '41', workspaceId: '12' };

  await assert.rejects(runtime.create({ ...scope, requestId: 'a', carry: { store: '/etc/passwd', conversationId: from } }), /invalid_carry/);
  await assert.rejects(runtime.create({ ...scope, requestId: 'b', carry: { store: join(root, 'import', 'none.sqlite'), conversationId: from } }), /invalid_carry/);
  await assert.rejects(runtime.create({ ...scope, requestId: 'c', carry: { store, conversationId: 999999 } }), /invalid_carry/);
  await assert.rejects(runtime.create({ ...scope, requestId: 'd', carry: { store } }), /invalid_carry/);
});
