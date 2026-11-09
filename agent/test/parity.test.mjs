// Pi 1.5.0 parity: native compaction, bounded provider retries and run failures
// surfaced to Rails. Scripted model and local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { writeFile, access } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { obj } from '@earendil-works/pi-schema';
import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { createRuntime } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { App } from '../state.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir, launch, client, history } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const query = '?actorId=alice&workspaceId=one';
const toolUse = (name, args) => message(call(name, args), { stopReason: 'toolUse' });
// A harmless tool for long tool-round scripts.
const inspector = defineExtension({ name: 'fixture.inspect', tools: [defineTool({ name: 'fx_inspect', description: 'Inspect',
  parameters: obj({}), replay: 'safe', execute: async () => ({ output: [{ type: 'text', text: 'inspected' }] }) })] });
const deps = (cwd, provider, extra = {}) => ({ ...provider, authorize: async requested => ({ ...requested,
  allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }), invoke: async () => ({ status: 'done', result: {} }),
  extensions: [inspector], ...extra });
async function setup(t, responses, config = {}, options = {}) {
  const cwd = await privateDir('omakase-parity-');
  const provider = scriptedProvider(responses, options.provider);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, deps(cwd, provider, options.deps));
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId, content = requestId) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run };
}
const exists = async path => { try { await access(path); return true; } catch { return false; } };

// ---- item 5: no silent truncation ---------------------------------------------------------------


const WINDOW = 4000;
const INPUTS = 60;
const filler = n => `${n} `.repeat(330).slice(0, 1000); // about 250 tokens per input
const compactionModel = { model: { contextWindow: WINDOW, maxTokens: 500 } };
const chars = messages => JSON.stringify(messages.filter(m => m.role !== 'system')).length;
const compactingModel = calls => context => {
  if (JSON.stringify(context.messages).includes('context summarization assistant')) { calls.summaries++; return message('SUMMARY: the person sent numbered filler.'); }
  if (chars(context.messages) > WINDOW * 4) { calls.overflows++; return message('', { stopReason: 'error', errorMessage: 'prompt is too long: context_length_exceeded' }); }
  calls.answers++;
  return message(`answer ${calls.answers}`);
};

// A thread that runs long, summarised on its own again and again: the agent
// answers every message, the context stays inside the window, and Rails' copy
// and the export still hold every message.
test('a long scripted conversation compacts natively instead of overflowing; history stays visible', async t => {
  const calls = { summaries: 0, overflows: 0, answers: 0 };
  const f = await setup(t, Array.from({ length: 3 * INPUTS }, () => compactingModel(calls)),
    { compaction: { reserveTokens: 1500, keepRecentTokens: 1000, backgroundTokens: 0 } }, { provider: compactionModel });
  for (let n = 1; n <= INPUTS; n++) assert.equal((await f.run(`input-${n}`, filler(n))).status, 'done', `input ${n}`);
  assert.ok(calls.summaries >= 3, `compacted ${calls.summaries} times`);
  assert.equal(calls.overflows, 0);
  assert.equal(calls.answers, INPUTS);
  const conversation = await f.runtime.harness.conversation(f.id, ctx);
  const stored = (await conversation.entries({ order: 'ascending' }, 1000, undefined, ctx)).items;
  assert.ok(stored.some(e => e.kind === 'pi.compaction'));
  assert.equal((await f.runtime.snapshot(f.id, scope)).status, 'done');
  const view = await history(after => f.runtime.entries(f.id, scope, after));
  assert.ok(view.some(e => e.role === 'summary' && /SUMMARY/.test(e.content)));
  // Every input stays in the Rails view; the model works from the compacted context.
  assert.equal(view.filter(e => e.role === 'user').length, INPUTS);
  assert.ok(chars((await conversation.context(ctx)).messages) < WINDOW * 4);
  const exported = await Array.fromAsync(await f.runtime.export(f.id, { ...scope, title: 'Long' }));
  assert.equal(exported.filter(line => line.message?.role === 'user').length, INPUTS);
  assert.equal(exported.filter(line => line.type === 'compaction').length, calls.summaries);
});

test('without compaction the same conversation overflows and fails', async t => {
  const calls = { summaries: 0, overflows: 0, answers: 0 };
  const f = await setup(t, Array.from({ length: 3 * INPUTS }, () => compactingModel(calls)), { compaction: { enabled: false } }, { provider: compactionModel });
  const statuses = [];
  for (let n = 1; n <= INPUTS; n++) statuses.push((await f.run(`input-${n}`, filler(n))).status);
  assert.ok(statuses.includes('unanswered'));
  assert.equal(calls.summaries, 0);
  assert.ok(calls.overflows >= 1);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'error');
  assert.deepEqual(view.failure, { reason: 'model_error' });
});

test('an invalid compaction setting refuses to start', async t => {
  const cwd = await privateDir('omakase-parity-compaction-');
  for (const compaction of [{ enabled: 'yes' }, { reserveTokens: -1 }, { unknown: 1 }]) {
    await assert.rejects(createRuntime({ storePath: join(cwd, `${Object.keys(compaction)[0]}.sqlite`), compaction },
      deps(cwd, scriptedProvider([]))), /invalid_compaction/);
  }
});

// ---- item 8: bounded retries and run failures ---------------------------------------------------

const transient = () => message('', { stopReason: 'error', errorMessage: '503 service temporarily unavailable (overloaded)' });

test('a retryable provider error is retried within the bound; each attempt reserves a request', async t => {
  const f = await setup(t, [transient(), transient(), message('recovered')], { limits: { retryBaseDelayMs: 5 } });
  assert.equal((await f.run('retry')).status, 'done');
  assert.equal(f.provider.faux.state.callCount, 3);
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 3);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'done');
  assert.equal(view.failure, null);
});

test('retries stop at maxRetries and the run failure reaches the snapshot; permanent errors are not retried', async t => {
  const f = await setup(t, [transient(), transient(), transient(), message('never')], { limits: { maxRetries: 1, retryBaseDelayMs: 5 } });
  assert.equal((await f.run('exhaust')).status, 'unanswered');
  assert.equal(f.provider.faux.state.callCount, 2);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'error');
  assert.deepEqual(view.failure, { reason: 'model_error' });
  const permanent = await setup(t, [message('', { stopReason: 'error', errorMessage: 'manufactured invalid request' }), message('never')],
    { limits: { retryBaseDelayMs: 5 } });
  assert.equal((await permanent.run('permanent')).status, 'unanswered');
  assert.equal(permanent.provider.faux.state.callCount, 1);
  // The next run clears the failure.
  permanent.provider.faux.setResponses([message('fine')]);
  assert.equal((await permanent.run('next')).status, 'done');
  assert.equal((await permanent.runtime.snapshot(permanent.id, scope)).failure, null);
});

async function processSetup(extra = {}) {
  const cwd = await privateDir('omakase-parity-process-');
  return { cwd, storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'synthetic-rails-token-456', ...extra };
}
async function crashDuringModelRequest(t, limits) {
  const config = await processSetup({ limits, responses: [{ fixtureHang: true }] });
  const owner = await launch(config, config.cwd, '-hang'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  await api(`${path}/submissions`, { requestId: 'hang', content: 'answer slowly' });
  await eventually(() => exists(join(config.cwd, 'model-started')));
  // Past persistWithinMs, so the running attempt is stored before the crash.
  await new Promise(resolve => setTimeout(resolve, 500));
  await owner.stop('SIGKILL');
  const resumed = await launch({ ...config, responses: [message('answered after the crash')] }, config.cwd, '-resumed');
  t.after(() => resumed.stop());
  const resumedApi = client(resumed, config);
  const final = await eventually(async () => { const s = (await resumedApi(path + query)).body; return ['done', 'error', 'blocked'].includes(s.status) && s; }, 15000);
  return { ...final, entries: (await resumedApi(`${path}/entries${query}`)).body.entries };
}

test('a crash during a model request with no retry left ends the run `interrupted`, surfaced to Rails', async t => {
  const final = await crashDuringModelRequest(t, { maxRetries: 0 });
  assert.equal(final.status, 'error');
  assert.deepEqual(final.failure, { reason: 'interrupted' });
  assert.equal(final.entries.some(e => e.content === 'answered after the crash'), false);
});

test('a crash during a model request is retried once retries are allowed', async t => {
  const final = await crashDuringModelRequest(t, { maxRetries: 1, retryBaseDelayMs: 5 });
  assert.equal(final.status, 'done');
  assert.equal(final.failure, null);
  assert.ok(final.entries.some(e => e.content === 'answered after the crash'));
});

test('work the restart limit cuts off is reported `blocked` with reason restart_limit, not retried silently', async t => {
  const config = await processSetup({ limits: { restartLimit: 1 }, fixtureExtensions: ['sleep'], responses: [toolUse('fx_sleep', {})] });
  const owner = await launch(config, config.cwd, '-loop'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  await api(`${path}/submissions`, { requestId: 'sleep', content: 'sleep' });
  await eventually(() => exists(join(config.cwd, 'sleep-starts')));
  await owner.stop('SIGKILL');
  const resumed = await launch({ ...config, responses: [] }, config.cwd, '-loop-resumed'); t.after(() => resumed.stop());
  const resumedApi = client(resumed, config);
  const final = await eventually(async () => { const s = (await resumedApi(path + query)).body; return ['done', 'error', 'blocked'].includes(s.status) && s; }, 15000);
  assert.equal(final.status, 'blocked');
  assert.deepEqual(final.failure, { reason: 'restart_limit' });
  assert.equal((await resumedApi(`${path}/entries${query}`)).body.entries.find(e => e.toolName === 'fx_sleep')?.isError, true);
  const inspection = await resumed.inspect(conversation.id);
  assert.equal(inspection.liveTasks, 0);
  // No further model request after the crash loop: the run stops, as the 1.4 park did.
  assert.equal(inspection.modelCalls, 0);
});


// ---- mail into a busy, failed or stuck agent -----------------------------------------------------

test('a message that arrives while the agent works waits its turn and is answered next, not dropped', async t => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const seen = [];
  const f = await setup(t, [async () => { await gate; return message('first answer'); },
    context => { seen.push(JSON.stringify(context.messages)); return message('mail answer'); }]);
  const first = await f.runtime.submit(f.id, { ...scope, requestId: 'first', content: 'first' });
  await eventually(() => f.provider.faux.state.callCount === 1);
  const mail = await f.runtime.submit(f.id, { ...scope, requestId: 'mail', content: '[Concourse mail from a peer] hello', whenBusy: 'followUp' });
  release();
  assert.equal((await (await f.runtime.harness.submission(first.id, ctx)).wait(ctx)).status, 'done');
  assert.equal((await (await f.runtime.harness.submission(mail.id, ctx)).wait(ctx)).status, 'done');
  assert.match(seen.join(), /Concourse mail from a peer/);
  const { entries } = await f.runtime.entries(f.id, scope);
  assert.deepEqual(entries.filter(e => e.role === 'assistant').map(e => e.content), ['first answer', 'mail answer']);
});

test('a steer joins the turn the agent is in: the model reads it at its next step', async t => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const seen = [];
  const f = await setup(t, [async () => { await gate; return toolUse('fx_inspect', {}); },
    context => { seen.push(JSON.stringify(context.messages)); return message('changed course'); }]);
  const first = await f.runtime.submit(f.id, { ...scope, requestId: 'first', content: 'book Paris' });
  await eventually(() => f.provider.faux.state.callCount === 1);
  const steer = await f.runtime.submit(f.id, { ...scope, requestId: 'steer', content: '[Concourse mail from a peer] Rome, not Paris', whenBusy: 'steer' });
  release();
  assert.equal((await (await f.runtime.harness.submission(first.id, ctx)).wait(ctx)).status, 'done');
  await (await f.runtime.harness.submission(steer.id, ctx)).wait(ctx);
  assert.equal(f.provider.faux.state.callCount, 2, 'one turn, not a second');
  assert.match(seen[0], /Rome, not Paris/);
});

test('a waiting message shows as queued, and can become a steer before the agent takes it in', async t => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const seen = [], frames = [];
  const f = await setup(t, [async () => { await gate; return toolUse('fx_inspect', {}); },
    context => { seen.push(JSON.stringify(context.messages)); return message('changed course'); }],
    { limits: { frameIntervalMs: 20 } }, { deps: { frame: async data => { frames.push(data); } } });
  const first = await f.runtime.submit(f.id, { ...scope, requestId: 'first', content: 'book Paris' });
  await eventually(() => f.provider.faux.state.callCount === 1);
  const later = await f.runtime.submit(f.id, { ...scope, requestId: 'later', content: 'Rome, not Paris', whenBusy: 'followUp' });
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).queued, [{ id: String(later.id), mode: 'followUp', text: 'Rome, not Paris', pictures: 0 }]);
  await eventually(() => frames.some(frame => frame.queued?.length === 1));

  assert.deepEqual(await f.runtime.changeQueued(f.id, { ...scope, id: String(later.id), whenBusy: 'steer' }), { changed: true });
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).queued.map(item => [item.mode, item.text]), [['steer', 'Rome, not Paris']]);
  release();
  assert.equal((await (await f.runtime.harness.submission(first.id, ctx)).wait(ctx)).status, 'done');
  assert.equal(f.provider.faux.state.callCount, 2, 'taken in as a steer: one turn, not a second');
  assert.match(seen[0], /Rome, not Paris/);
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).queued, []);
  // Taken in: nothing left to change.
  assert.deepEqual(await f.runtime.changeQueued(f.id, { ...scope, id: String(later.id), whenBusy: 'followUp' }), { changed: false });
  await eventually(() => frames.at(-1)?.busy === false);
  assert.deepEqual(frames.at(-1).queued ?? frames.findLast(frame => frame.queued).queued, []);
});

test('a waiting message taken back is never answered, and the run it waited behind still ends done', async t => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const seen = [];
  const f = await setup(t, [async () => { await gate; return message('first answer'); },
    context => { seen.push(JSON.stringify(context.messages)); return message('never'); }]);
  const first = await f.runtime.submit(f.id, { ...scope, requestId: 'first', content: 'first' });
  await eventually(() => f.provider.faux.state.callCount === 1);
  const later = await f.runtime.submit(f.id, { ...scope, requestId: 'later', content: 'oops' });
  assert.deepEqual(await f.runtime.withdrawQueued(f.id, { ...scope, id: String(later.id) }), { withdrawn: true });
  assert.deepEqual(await f.runtime.withdrawQueued(f.id, { ...scope, id: String(later.id) }), { withdrawn: false });
  release();
  assert.equal((await (await f.runtime.harness.submission(first.id, ctx)).wait(ctx)).status, 'done');
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).status === 'done');
  assert.equal(f.provider.faux.state.callCount, 1);
  assert.deepEqual(seen, []);
  // Another conversation's message is not this one's to take back.
  await assert.rejects(f.runtime.withdrawQueued(f.id, { actorId: 'mallory', workspaceId: 'one', id: String(later.id) }), { status: 404 });
});

test('an agent whose last run failed answers the next message', async t => {
  const f = await setup(t, [message('', { stopReason: 'error', errorMessage: 'manufactured invalid request' }), message('back')]);
  assert.equal((await f.run('fails')).status, 'unanswered');
  assert.equal((await f.runtime.snapshot(f.id, scope)).status, 'error');
  assert.equal((await f.run('[Concourse mail from a peer] hello')).status, 'done');
  assert.equal((await f.runtime.snapshot(f.id, scope)).status, 'done');
});

test('an agent stuck after a crash loop answers the next message', async t => {
  const config = await processSetup({ limits: { restartLimit: 1 }, fixtureExtensions: ['sleep'], responses: [toolUse('fx_sleep', {})] });
  const owner = await launch(config, config.cwd, '-stuck'); t.after(() => owner.stop());
  const { body: conversation } = await client(owner, config)('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  await client(owner, config)(`${path}/submissions`, { requestId: 'sleep', content: 'sleep' });
  await eventually(() => exists(join(config.cwd, 'sleep-starts')));
  await owner.stop('SIGKILL');
  const stuck = await launch({ ...config, responses: [message('back')] }, config.cwd, '-stuck-1'); t.after(() => stuck.stop());
  const api = client(stuck, config);
  await eventually(async () => (await api(path + query)).body.status === 'blocked', 15000);
  assert.equal((await api(`${path}/submissions`, { requestId: 'mail', content: '[Concourse mail from a peer] hello' })).status, 202);
  const final = await eventually(async () => { const s = (await api(path + query)).body; return ['done', 'error', 'blocked'].includes(s.status) &&
    (await api(`${path}/entries${query}`)).body.entries.some(e => e.content === 'back') && s; }, 15000);
  assert.equal(final.status, 'done');
});
