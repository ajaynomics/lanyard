// Who said each message survives a restart: its request id and its author
// (a person's user id, or a channel's sender) are kept on its stored entry,
// and the entries Rails rebuilds from carry them. Scripted model only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, entryView } from '../runtime.mjs';
import { sessionFile } from '../session-file.mjs';
import { railsStandIn } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };

async function setup(t, responses) {
  const cwd = await privateDir('omakase-speakers-');
  const rails = railsStandIn();
  const deps = { invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }) };
  const config = { storePath: join(cwd, 'state.sqlite') };
  const runtime = await createRuntime(config, { ...deps, ...scriptedProvider(responses) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const send = async (requestId, extra) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content: 'Yes, go ahead', ...extra });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { runtime, id, send, config, deps };
}

const said = entries => entries.filter(entry => entry.role === 'user').map(({ content, requestId, author }) => ({ content, requestId, author }));

test('two people saying the same words keep their own authors after the sidecar restarts', async t => {
  const f = await setup(t, [message('one'), message('two'), message('three')]);
  assert.equal((await f.send('ann-1', { author: { userId: '7' }, fromPerson: true })).status, 'done');
  assert.equal((await f.send('bob-1', { author: { userId: '8' }, fromPerson: true })).status, 'done');
  assert.equal((await f.send('campfire:1:9', { author: { sender: 'Cara in Ops' } })).status, 'done');
  await f.runtime.close();

  const reopened = await createRuntime(f.config, { ...f.deps, ...scriptedProvider([]) });
  t.after(() => reopened.close());
  assert.deepEqual(said((await reopened.entries(f.id, scope)).entries), [
    { content: 'Yes, go ahead', requestId: 'ann-1', author: { userId: '7' } },
    { content: 'Yes, go ahead', requestId: 'bob-1', author: { userId: '8' } },
    { content: 'Yes, go ahead', requestId: 'campfire:1:9', author: { sender: 'Cara in Ops' } }
  ]);
});

test('a message with no author known keeps its request id; an author is checked and is part of the request', async t => {
  const f = await setup(t, [message('one')]);
  assert.equal((await f.send('routine:1')).status, 'done');
  assert.deepEqual(said((await f.runtime.entries(f.id, scope)).entries), [{ content: 'Yes, go ahead', requestId: 'routine:1', author: undefined }]);
  for (const [n, author] of [{}, { userId: '' }, { userId: 7 }, { sender: 'x'.repeat(1025) }, { userId: '7', sender: 'Ann' }, { userId: '7', role: 'manager' }, 'Ann', ['7']].entries())
    await assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: `bad-${n}`, content: 'x', author }), /invalid_author/);
  // The same request id from another author is another message, refused.
  await assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: 'routine:1', content: 'Yes, go ahead', author: { userId: '8' } }), /request_conflict/);
});

test("the person's own steer still goes first, as the entry carrying his author", async t => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const f = await setup(t, [async (_, options) => {
    await Promise.race([gate, new Promise(resolve => options.signal.addEventListener('abort', resolve))]);
    return message('first');
  }, ...Array.from({ length: 4 }, (_, n) => () => message(`answer ${n}`))]);
  const busy = await f.runtime.submit(f.id, { ...scope, requestId: 'start', content: 'Start', author: { userId: '7' }, fromPerson: true });
  for (let tries = 0; !(await f.runtime.snapshot(f.id, scope)).status.match(/running/) && tries < 200; tries++) await new Promise(resolve => setTimeout(resolve, 10));
  await f.runtime.submit(f.id, { ...scope, requestId: 'campfire:1:1', content: 'From the room', whenBusy: 'steer', author: { sender: 'Cara in Ops' } });
  const own = await f.runtime.submit(f.id, { ...scope, requestId: 'stop', content: 'Stop', whenBusy: 'steer', author: { userId: '7' }, fromPerson: true });
  release();
  await (await f.runtime.harness.submission(busy.id, ctx)).wait(ctx);
  await (await f.runtime.harness.submission(own.id, ctx)).wait(ctx);
  for (let tries = 0; (await f.runtime.snapshot(f.id, scope)).status !== 'done' && tries < 500; tries++) await new Promise(resolve => setTimeout(resolve, 10));
  assert.deepEqual(said((await f.runtime.entries(f.id, scope)).entries).map(each => each.requestId), ['start', 'stop', 'campfire:1:1']);
});

test("a message entry reads as a user's message, in Rails' copy and in an exported session", async () => {
  const entry = { id: 4, kind: 'app.message', data: { requestId: 'ann-1', author: { userId: '7' } },
    model: [{ role: 'user', content: 'Yes', timestamp: 1730000001000 }] };
  assert.deepEqual(entryView(entry), [{ id: '4', entryId: 4, role: 'user', content: 'Yes', requestId: 'ann-1', author: { userId: '7' } }]);
  const lines = [];
  for await (const line of sessionFile([entry], { id: 'x' })) lines.push(line);
  assert.equal(lines.find(line => line.type === 'message')?.message.content, 'Yes');
});
