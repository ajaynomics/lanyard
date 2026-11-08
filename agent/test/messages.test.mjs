// PARITY.md items 2 and 4: images in a person's message, and forks. Scripted
// model and local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, IMAGE_LIMITS } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { App, Definitions } from '../state.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
// A 1x1 transparent PNG.
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
const image = (data = PNG, mimeType = 'image/png') => ({ type: 'image', data, mimeType });
const text = value => ({ type: 'text', text: value });

async function setup(t, responses, { model } = {}) {
  const cwd = await privateDir('omakase-messages-');
  const provider = scriptedProvider(responses, { model });
  const rails = railsStandIn();
  const deps = { ...provider, invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }) };
  const config = { storePath: join(cwd, 'state.sqlite') };
  const runtime = await createRuntime(config, deps);
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (conversation, requestId, content = requestId, extra = {}) => {
    const submitted = await runtime.submit(conversation, { ...scope, requestId, content, ...extra });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, rails, run, config, deps };
}

// ---- item 2: images ---------------------------------------------------------------------------

test('a message with images reaches the model and its entry carries them; a repeat is the same submission', async t => {
  let seen;
  const f = await setup(t, [context => { seen = context.messages; return message('a pixel'); }]);
  const content = [text('What is this?'), image()];
  const first = await f.runtime.submit(f.id, { ...scope, requestId: 'look', content });
  assert.equal((await f.runtime.submit(f.id, { ...scope, requestId: 'look', content })).id, first.id);
  assert.equal((await (await f.runtime.harness.submission(first.id, ctx)).wait(ctx)).status, 'done');
  const asked = seen.filter(m => m.role === 'user').at(-1);
  assert.deepEqual(asked.content, content);
  const { entries } = await f.runtime.entries(f.id, scope);
  const person = entries.find(entry => entry.role === 'user');
  assert.equal(person.content, 'What is this?');
  assert.deepEqual(person.images, [{ mimeType: 'image/png', data: PNG }]);
  // The request id's digest covers the images, not only the words.
  await assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: 'look', content: [text('What is this?'), image(), image()] }), /request_conflict/);
});

test('images alone are a message; the limits are refused before anything is admitted', async t => {
  const f = await setup(t, [message('nice')]);
  assert.equal((await f.run(f.id, 'photo', [image()])).status, 'done');
  const refuse = (content, category) => assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: `bad-${category}-${Math.random()}`, content }),
    new RegExp(category));
  const big = 'A'.repeat(Math.ceil(IMAGE_LIMITS.bytes / 3) * 4 + 4);
  await refuse(Array.from({ length: 5 }, () => image()), 'invalid_images');
  await refuse([text('six blocks'), ...Array.from({ length: 5 }, () => image())], 'invalid_content');
  await refuse([text('x'), image(PNG, 'image/svg+xml')], 'invalid_images');
  await refuse([text('x'), image(big)], 'invalid_images');
  await refuse([text('x'), image('not base64!')], 'invalid_images');
  await refuse([text('x'), { ...image(), extra: true }], 'invalid_content');
  await refuse([text('   ')], 'invalid_content');
  await refuse([], 'invalid_content');
  await refuse('', 'invalid_content');
  const entries = (await f.runtime.entries(f.id, scope)).entries.filter(entry => entry.role === 'user');
  assert.equal(entries.length, 1);
});

test('a model without image input is refused images with images_unsupported; words still go', async t => {
  const f = await setup(t, [message('words only')], { model: { input: ['text'] } });
  await assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: 'look', content: [text('see'), image()] }), /images_unsupported/);
  assert.equal((await f.run(f.id, 'hello')).status, 'done');
});

test('HTTP: a submission may be tens of megabytes; other bodies stay small', async t => {
  const cwd = await privateDir('omakase-messages-http-');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...scriptedProvider([message('seen')]), authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const base = `http://127.0.0.1:${port}`;
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const post = (path, body) => fetch(`${base}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const { id } = await (await post('/v1/conversations', { ...scope, requestId: 'create' })).json();
  // Four images at the limit: 4 x 5 MB, base64.
  const padded = PNG.replace(/=+$/, '');
  const large = (padded + 'A'.repeat(Math.floor(IMAGE_LIMITS.bytes / 3) * 4 - padded.length));
  const response = await post(`/v1/conversations/${id}/submissions`, { ...scope, requestId: 'large', content: [text('four'), ...Array.from({ length: 4 }, () => image(large))] });
  assert.equal(response.status, 202);
  assert.equal((await post('/v1/conversations', { ...scope, requestId: 'x'.repeat(2 * 1024 * 1024) })).status, 413);
});

// ---- item 4: forks ----------------------------------------------------------------------------

test('a fork holds the parent history up to its entry, keeps the scope and definition so tools work, and repeats by request id', async t => {
  const f = await setup(t, [message('first answer'), message('second answer'),
    message(call('note', { key: 'k' }), { stopReason: 'toolUse' }), message('noted in the fork')]);
  const agentDefinition = definition();
  await f.run(f.id, 'one', 'first question', { definition: agentDefinition });
  await f.run(f.id, 'two', 'second question', { definition: agentDefinition });
  const parent = (await f.runtime.entries(f.id, scope)).entries;
  const at = parent.find(entry => entry.content === 'first answer').entryId;

  const { id: fork } = await f.runtime.fork(f.id, { ...scope, requestId: 'branch', at });
  assert.notEqual(fork, f.id);
  assert.deepEqual(await f.runtime.fork(f.id, { ...scope, requestId: 'branch', at }), { id: fork });
  await assert.rejects(f.runtime.fork(f.id, { ...scope, requestId: 'branch', at: at - 1 }), /request_conflict/);
  await assert.rejects(f.runtime.fork(f.id, { ...scope, requestId: 'elsewhere', at: 999999 }), /invalid_entry/);
  await assert.rejects(f.runtime.fork(f.id, { ...scope, requestId: 'string', at: String(at) }), /invalid_entry/);
  await assert.rejects(f.runtime.fork(f.id, { ...scope, actorId: 'bob', requestId: 'theirs', at }), /not_found/);

  // From scratch, the cursor pull brings the parent's history, with the parent's entry ids.
  const copied = (await f.runtime.entries(fork, scope)).entries;
  assert.deepEqual(copied.map(entry => [entry.id, entry.content]), parent.filter(entry => entry.entryId <= at).map(entry => [entry.id, entry.content]));

  const app = await f.runtime.harness.snapshot(App, fork, ctx);
  assert.deepEqual([app.actorId, app.workspaceId, app.cwd], ['alice', 'one', f.cwd]);
  assert.equal((await f.runtime.harness.snapshot(Definitions, ctx)).conversations[fork], agentDefinition.digest);

  // The fork's first message runs the agent's tool through Rails, named as the fork.
  assert.equal((await f.run(fork, 'three', 'save it', { definition: agentDefinition })).status, 'done');
  assert.deepEqual(f.rails.calls.map(c => [c.tool, c.conversationId, c.actorId, c.workspaceId]), [['note', String(fork), 'alice', 'one']]);
  const after = (await f.runtime.entries(fork, scope)).entries.map(entry => entry.content);
  assert.ok(after.includes('noted in the fork'));
  assert.ok(!after.includes('second question'));
  // The parent goes on unchanged.
  assert.equal((await f.runtime.entries(f.id, scope)).entries.length, parent.length);
});

test('a fork of an agent edited since the fork entry runs the agent as it is now', async t => {
  const f = await setup(t, [message('old'), message('new'), message('fork')]);
  await f.run(f.id, 'one', 'hello', { definition: definition({ instructions: 'Old.' }) });
  const at = (await f.runtime.entries(f.id, scope)).entries.find(entry => entry.content === 'old').entryId;
  const now = definition({ instructions: 'New.' });
  await f.run(f.id, 'two', 'again', { definition: now });
  const { id: fork } = await f.runtime.fork(f.id, { ...scope, requestId: 'branch', at });
  const agent = await (await f.runtime.harness.conversation(fork, ctx)).agent(ctx);
  assert.equal(agent.instructions, 'New.');
  assert.ok(agent.extensions.some(e => e.name === `bot.${now.digest}`));
});

test('a fork into another agent of the same actor takes its scope and folder, not the parent agent, and repeats by request id', async t => {
  const cwd = await privateDir('omakase-fork-into-');
  const newCwd = join(cwd, 'bot-2');
  const provider = scriptedProvider([message('first answer'), message(call('note', { key: 'k' }), { stopReason: 'toolUse' }), message('noted by the new agent')]);
  const rails = railsStandIn();
  const folders = { one: cwd, two: newCwd };
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { ...provider, invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId in folders, cwd: folders[requested.workspaceId] }) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (conversation, requestId, content, extra) =>
    (await runtime.harness.submission((await runtime.submit(conversation, { requestId, content, ...extra })).id, ctx)).wait(ctx);
  await run(id, 'one', 'first question', { ...scope, definition: definition({ instructions: 'Old agent.' }) });
  const parent = (await runtime.entries(id, scope)).entries;
  const at = parent.find(entry => entry.content === 'first answer').entryId;
  const into = { workspaceId: 'two', cwd: newCwd };

  const { id: fork } = await runtime.fork(id, { ...scope, requestId: 'new-agent', at, into });
  assert.deepEqual(await runtime.fork(id, { ...scope, requestId: 'new-agent', at, into }), { id: fork });
  await assert.rejects(runtime.fork(id, { ...scope, requestId: 'new-agent', at, into: { workspaceId: 'three', cwd: newCwd } }), /request_conflict/);
  await assert.rejects(runtime.fork(id, { ...scope, requestId: 'new-agent', at }), /request_conflict/);
  for (const bad of [null, 'two', { workspaceId: 'two' }, { workspaceId: 'two', cwd: 'relative' }, { workspaceId: 'two', cwd: `${cwd}/../x` },
    { workspaceId: '', cwd: newCwd }, { workspaceId: 'two', cwd: newCwd, actorId: 'bob' }]) {
    await assert.rejects(runtime.fork(id, { ...scope, requestId: `bad-${Math.random()}`, at, into: bad }), /invalid_(into|workspace)/);
  }

  const app = await runtime.harness.snapshot(App, fork, ctx);
  assert.deepEqual([app.actorId, app.workspaceId, app.cwd], ['alice', 'two', newCwd]);
  assert.equal((await runtime.harness.snapshot(Definitions, ctx)).conversations[fork], undefined);
  const agent = await (await runtime.harness.conversation(fork, ctx)).agent(ctx);
  assert.equal(agent.cwd, newCwd);
  assert.ok(!agent.extensions.some(e => e.name.startsWith('bot.')));
  // The copy is the new agent's: the parent's scope no longer reaches it.
  const two = { actorId: 'alice', workspaceId: 'two' };
  assert.deepEqual((await runtime.entries(fork, two)).entries.map(entry => entry.id), parent.filter(entry => entry.entryId <= at).map(entry => entry.id));
  await assert.rejects(runtime.entries(fork, scope), /not_found/);

  // Its first message carries its own definition, and its tools run as the new agent.
  const own = definition({ instructions: 'New agent.' });
  assert.equal((await run(fork, 'two', 'save it', { ...two, definition: own })).status, 'done');
  assert.equal((await (await runtime.harness.conversation(fork, ctx)).agent(ctx)).instructions, 'New agent.');
  assert.deepEqual(rails.calls.map(c => [c.tool, c.conversationId, c.actorId, c.workspaceId]), [['note', String(fork), 'alice', 'two']]);
});

test('HTTP: POST /v1/conversations/:id/forks answers 201 {id}', async t => {
  const cwd = await privateDir('omakase-forks-http-');
  const provider = scriptedProvider([message('hi')]);
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...provider, authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const base = `http://127.0.0.1:${port}`;
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const post = (path, body) => fetch(`${base}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const { id } = await (await post('/v1/conversations', { ...scope, requestId: 'create' })).json();
  const submitted = await (await post(`/v1/conversations/${id}/submissions`, { ...scope, requestId: 'hello', content: 'hello' })).json();
  await (await server.runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  const { entries } = await (await fetch(`${base}/v1/conversations/${id}/entries?actorId=alice&workspaceId=one`, { headers })).json();
  const response = await post(`/v1/conversations/${id}/forks`, { ...scope, requestId: 'branch', at: entries.at(-1).entryId });
  assert.equal(response.status, 201);
  const { id: fork } = await response.json();
  assert.ok(Number.isInteger(fork) && fork !== id);
  assert.equal((await post(`/v1/conversations/${id}/forks`, { ...scope, requestId: 'branch', at: entries.at(-1).entryId })).status, 201);
});
