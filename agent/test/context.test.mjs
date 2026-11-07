// PARITY.md round 2: summarising at about 262k tokens, /compact, the
// history as pi's session file, and the bot's notes file. Scripted models and
// local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { LiveDoc } from '@earendil-works/pi-durable';
import { createRuntime, compactionOverride, compactAtOf, failureReason, DEFAULT_COMPACTION, COMPACT_AT_TOKENS } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const SUMMARISER = 'context summarization assistant';
const summarising = context => JSON.stringify(context.messages).includes(SUMMARISER);

async function setup(t, responses, { config = {}, model, deps = {} } = {}) {
  const cwd = await privateDir('omakase-context-');
  const provider = scriptedProvider(responses, model ? { model } : {});
  const frames = [];
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), limits: { maxRetries: 0, frameIntervalMs: 5 }, ...config }, {
    ...provider, authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    invoke: async () => ({ status: 'done', result: {} }), frame: async payload => { frames.push(payload); }, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId, content = requestId, extra = {}) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content, ...extra });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run, frames };
}

// ---- 15: compaction at about 262k ----------------------------------------------------------------

test('a large window blocks at 262,144 tokens; a background summary starts about 229k; a small window keeps Durable\'s reserve', () => {
  const blockAt = window => window - (compactionOverride(window, DEFAULT_COMPACTION)?.reserveTokens ?? DEFAULT_COMPACTION.reserveTokens);
  assert.equal(COMPACT_AT_TOKENS, 262144);
  assert.deepEqual(compactionOverride(1048576, DEFAULT_COMPACTION), { reserveTokens: 786432 });
  assert.equal(blockAt(1048576), 262144);
  assert.equal(blockAt(1048576) - DEFAULT_COMPACTION.backgroundTokens, 229376);
  assert.deepEqual(compactionOverride(400000, DEFAULT_COMPACTION), { reserveTokens: 137856 });
  assert.equal(compactionOverride(200000, DEFAULT_COMPACTION), undefined);
  assert.equal(blockAt(200000), 183616);
  // pi-ai's Claude 5.5 windows are 1,000,000 tokens.
  assert.deepEqual(compactionOverride(1000000, DEFAULT_COMPACTION), { reserveTokens: 737856 });
  assert.deepEqual([1048576, 400000, 200000].map(window => compactAtOf(window, DEFAULT_COMPACTION)), [262144, 262144, 183616]);
  assert.equal(compactAtOf(1048576, { ...DEFAULT_COMPACTION, enabled: false }), null);
  assert.equal(compactAtOf(1048576, DEFAULT_COMPACTION, 100000), 100000);
});

test('the harness runs each route\'s override, and GET /v1/models says where each model summarises', async t => {
  const f = await setup(t, [], { model: { contextWindow: 1048576 } });
  assert.deepEqual(f.runtime.compaction.modelOverrides, { 'fixture/scripted': { reserveTokens: 786432 } });
  assert.equal(f.runtime.compaction.backgroundTokens, 32768);
  assert.equal(f.runtime.catalogue().models[0].compactAt, 262144);
  const small = await setup(t, [], { model: { contextWindow: 200000 } });
  assert.deepEqual(small.runtime.compaction.modelOverrides, {});
  assert.equal(small.runtime.catalogue().models[0].compactAt, 183616);
  await assert.rejects(setup(t, [], { config: { compactAtTokens: 12.5 } }), /invalid_compact_at/);
});

test('every Claude route the sidecar serves, subscription and API key alike, blocks at 262k', async t => {
  const cwd = await privateDir('omakase-context-routes-');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    claudeSubscription: { file: join(cwd, 'claude.json'), vaultKey: 'a'.repeat(64), environment: 'test' } },
  { authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { modelOverrides } = server.runtime.compaction;
  for (const provider of ['anthropic', 'anthropic-api']) {
    assert.deepEqual(modelOverrides[`${provider}/claude-opus-5-5`], { reserveTokens: 737856 }, provider);
    assert.deepEqual(modelOverrides[`${provider}/claude-sonnet-5-5`], { reserveTokens: 737856 }, provider);
    assert.equal(modelOverrides[`${provider}/claude-haiku-4-5`], undefined, provider);
  }
  const views = Object.fromEntries(server.runtime.catalogue().models.map(model => [model.id, model.compactAt]));
  assert.equal(views['anthropic-api/claude-opus-5-5'], 262144);
  assert.equal(views['anthropic/claude-haiku-4-5'], 183616);
});

test('/compact is repeatable by request id, refuses changed or overlong instructions, and passes the instructions to the summary', async t => {
  const seen = [];
  const f = await setup(t, [message('one'), message('two'), context => { seen.push(JSON.stringify(context.messages)); return message('SUMMARY: numbers'); }],
    { config: { compaction: { keepRecentTokens: 1 } } });
  for (const words of ['first', 'second']) assert.equal((await f.run(words)).status, 'done');
  const input = { ...scope, requestId: 'c-1', instructions: 'Keep the numbers' };
  const first = await f.runtime.compact(f.id, input);
  assert.deepEqual(await f.runtime.compact(f.id, input), first);
  await assert.rejects(f.runtime.compact(f.id, { ...input, instructions: 'Keep the words' }), /request_conflict/);
  await assert.rejects(f.runtime.compact(f.id, { ...input, requestId: 'c-2', instructions: 'x'.repeat(4097) }), /invalid_instructions/);
  await assert.rejects(f.runtime.compact(f.id, { ...input, actorId: 'bob' }), /not_found/);
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).entries.some(entry => entry.role === 'summary'));
  assert.equal(seen.length, 1);
  assert.match(seen[0], /Keep the numbers/);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.deepEqual([view.compaction, view.compactionFailed], [null, null]);
});

test('frames say a summary is running, then that it failed, without the provider\'s words', async t => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  const f = await setup(t, [message('one'), message('two'), async () => {
    await held;
    return message('', { stopReason: 'error', errorMessage: 'provider secret words' });
  }], { config: { compaction: { keepRecentTokens: 1 } } });
  for (const words of ['first', 'second']) assert.equal((await f.run(words)).status, 'done');
  await f.runtime.compact(f.id, { ...scope, requestId: 'c-1' });
  await eventually(() => f.frames.some(frame => frame.compaction?.trigger === 'manual'));
  assert.equal((await f.runtime.snapshot(f.id, scope)).compaction.trigger, 'manual');
  release();
  await eventually(() => f.frames.some(frame => frame.compactionFailed?.trigger === 'manual' && frame.compaction === null));
  const failed = f.frames.findLast(frame => frame.compactionFailed);
  assert.equal(failed.busy, false);
  assert.deepEqual(failed.compactionFailed, { trigger: 'manual' });
  assert.doesNotMatch(JSON.stringify(f.frames), /provider secret words/);
  assert.match((await f.runtime.harness.snapshot(LiveDoc, f.id, ctx)).compactionFailure.error, /provider secret words/);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.deepEqual(view.compactionFailed, { trigger: 'manual' });
  assert.doesNotMatch(JSON.stringify(view), /provider secret words/);
  // A request that waited for a summary that failed.
  assert.equal(failureReason({ reason: 'model_error', detail: 'Compaction failed: 429 rate limited' }), 'compaction_failed');
  assert.equal(failureReason({ reason: 'model_error', detail: '429 rate limited' }), 'rate_limited');
});

test('POST /v1/conversations/:id/compactions answers 202 with the id, 409 and 422 as the contract says', async t => {
  const cwd = await privateDir('omakase-context-http-');
  const provider = scriptedProvider([message('one'), message('SUMMARY')]);
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...provider, authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const { id } = await server.runtime.create({ ...scope, requestId: 'create' });
  const post = body => fetch(`http://127.0.0.1:${port}/v1/conversations/${id}/compactions`, { method: 'POST',
    headers: { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' }, body: JSON.stringify({ ...scope, ...body }) });
  const first = await post({ requestId: 'c-1' });
  assert.equal(first.status, 202);
  const answer = await first.json();
  assert.equal(typeof answer.id, 'string');
  assert.deepEqual(await (await post({ requestId: 'c-1' })).json(), answer);
  assert.equal((await post({ requestId: 'c-1', instructions: 'other' })).status, 409);
  const long = await post({ requestId: 'c-2', instructions: 'x'.repeat(4097) });
  assert.deepEqual([long.status, await long.json()], [422, { error: 'invalid_instructions' }]);
});
