import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { obj, num, str } from '@earendil-works/pi-schema';
import { defineExtension, defineTool, defineTask } from '@earendil-works/pi-durable';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, shellIsolationAvailable, liveTaskGraph } from '../runtime.mjs';
import { App } from '../state.mjs';
import { railsStandIn, definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';
const scope = { actorId: 'alice', workspaceId: 'one' };
async function setup(t, responses, config = {}, deps = {}) {
  const cwd = await privateDir('omakase-advanced-');
  const provider = scriptedProvider(responses);
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...provider,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    invoke: rails.invoke, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId = 'request', bot) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content: 'manufactured fixture', ...(bot ? { definition: bot } : {}) });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run, rails };
}


test('A21 cancellation releases human waits, persists and retry does not cancel newly admitted work', async t => {
  const f = await setup(t, [message(call('ask', { question: 'Q' }), { stopReason: 'toolUse' }), message('new work')]);
  const pending = f.run('request', definition());
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).pendingInputs[0]);
  await assert.rejects(f.runtime.cancel(f.id, { ...scope, actorId: 'bob', requestId: 'cancel' }), /not_found/);
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel' });
  assert.equal((await pending).status, 'unanswered');
  assert.equal((await f.runtime.snapshot(f.id, scope)).pendingInputs.length, 0);
  const second = f.run('new');
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel' });
  assert.equal((await second).status, 'done');
});

// A background task that runs until it is aborted, created by a tool the way any
// extension could: conversation-owned and excluded from ordinary aborts.
const Background = defineTask({ name: 'fixture.background', version: 1, initial: () => ({ phase: 'run' }),
  abort: (_task, rt, c) => rt.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), c),
  phases: { run: (_task, _rt, c) => new Promise((_resolve, reject) => {
    c.abortSignal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
  }) } });
const spawner = defineExtension({ name: 'fixture.spawner', tasks: [Background], tools: [defineTool({
  name: 'fx_background', description: 'Start background work', parameters: obj({}), replay: 'safe',
  execute: async (_args, api, c) => {
    const id = await api.commit(tx => tx.createTask(Background, {}, { ownership: { kind: 'conversation' }, conversationId: api.conversationId, background: true }), c);
    return { output: [{ type: 'text', text: `started ${id}` }] };
  } })] });

test('A15/A21 cancellation settles the owned tree: background task and a human wait; stays cancelled on reopen', async t => {
  const f = await setup(t, [message(call('fx_background', {}), { stopReason: 'toolUse' }),
    message(call('ask', { question: 'Q' }), { stopReason: 'toolUse' })],
  {}, { extensions: [spawner] });
  const pending = f.run('request', definition());
  await eventually(async () => Object.values((await f.runtime.harness.snapshot(App, f.id, ctx))?.requests ?? {}).some(r => r.status === 'pending'));
  const live = async () => Object.values((await liveTaskGraph(f.runtime.harness, ctx)).tasks);
  const before = await live();
  assert.ok(before.some(n => n.kind === 'fixture.background' && n.background));
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel-tree' });
  assert.equal((await pending).status, 'unanswered');
  assert.deepEqual(await live(), []);
  for (const node of before) assert.equal((await f.runtime.harness.getTask(node.id, ctx)).state.status, 'terminal');
  const doc = await f.runtime.harness.snapshot(App, f.id, ctx);
  assert.ok(Object.values(doc.requests).every(r => r.status === 'cancelled'));
  // Idempotent retry, then reopen: nothing restarts.
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel-tree' });
  await f.runtime.close();
  const reopened = await createRuntime({ storePath: join(f.cwd, 'state.sqlite') }, { ...scriptedProvider([]),
    authorize: async requested => ({ ...requested, allowed: true, cwd: f.cwd }), invoke: async () => ({ status: 'done', result: {} }), extensions: [spawner] });
  t.after(() => reopened.close());
  assert.deepEqual(Object.keys((await liveTaskGraph(reopened.harness, ctx)).tasks), []);
  assert.equal((await reopened.snapshot(f.id, scope)).status, 'cancelled');
});

test('A05 a file named as an image that is not a decodable image fails clearly instead of reading as text', async t => {
  const f = await setup(t, [message(call('read', { path: 'fake.png' }), { stopReason: 'toolUse' }), message('done')], { execution: 'trusted-local-single-tenant' });
  await mkdir(join(f.cwd, 'conversations', String(f.id)), { recursive: true });
  await writeFile(join(f.cwd, 'conversations', String(f.id), 'fake.png'), 'not really a png');
  assert.equal((await f.run('request', definition({ computer: LOCAL_COMPUTER }))).status, 'done');
  const result = (await f.runtime.snapshot(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(result.isError, true);
  assert.match(result.content, /not a supported image/);
});

test('A22 usage counts each model row once and never presents an unavailable price as a bill', async t => {
  const f = await setup(t, [message('one'), message('two')]);
  await f.run('first'); await f.run('second');
  const usage = (await f.runtime.snapshot(f.id, scope)).usage;
  assert.ok(usage.totalTokens > 0);
  assert.deepEqual(usage.cost, { estimatedTotal: null, basis: 'price_unavailable' });
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).usage, usage);
});

test('A27 isolated shell network: a tool shell has no route off the host, or readiness fails closed', async t => {
  const config = { execution: 'trusted-local-single-tenant', shellNetwork: 'isolated' };
  if (!shellIsolationAvailable()) {
    const cwd = await privateDir('omakase-isolation-');
    await assert.rejects(createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...scriptedProvider([]),
      authorize: async () => ({}), invoke: async () => ({ status: 'done', result: {} }) }), /shell_isolation_unavailable/);
    return;
  }
  const f = await setup(t, [message(call('bash', { command: '(exec 3<>/dev/tcp/192.0.2.1/80) 2>&1 && echo CONNECTED || echo BLOCKED' }), { stopReason: 'toolUse' }), message('done')], config);
  assert.equal((await f.run('request', definition({ computer: LOCAL_COMPUTER }))).status, 'done');
  const result = (await f.runtime.snapshot(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.match(result.content, /BLOCKED/);
  assert.doesNotMatch(result.content, /CONNECTED/);
});
