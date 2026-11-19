// Background helpers (subagent.mjs): the call returns at once, the helper runs
// under a background task its conversation owns, tells Rails what it does and
// how it ended, and is cancelled on its own. Scripted model and a Rails
// stand-in only: no request leaves the process.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime } from '../runtime.mjs';
import { App, Definitions, Helpers } from '../state.mjs';
import { HELPER_INSTRUCTIONS, backgroundStarted, HELPERS_PER_CONVERSATION, HELPERS_PER_SIDECAR, subagentExtension } from '../subagent.mjs';
import { railsStandIn, definition, FIXTURE_TOOLS } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const toolUse = (name, args, id) => message(call(name, args, { id }), { stopReason: 'toolUse' });
const background = (task, id) => toolUse('subagent', { task, background: true }, id);

// The model's answers, by who asks: the agent ('parent'), or the helper whose
// task names the key. Each asks in its own order, whatever the interleaving.
function routed(scripts) {
  const queues = Object.fromEntries(Object.entries(scripts).map(([key, list]) => [key, [...list]]));
  const answer = context => {
    const text = JSON.stringify(context);
    const key = text.includes(HELPER_INSTRUCTIONS) ? Object.keys(queues).find(each => each !== 'parent' && text.includes(each)) : 'parent';
    const next = queues[key]?.shift();
    if (!next) throw new Error(`no scripted answer for ${key}`);
    return typeof next === 'function' ? next(context) : next;
  };
  return Array.from({ length: 64 }, () => answer);
}

async function fixture(t, scripts, { cwd, limits = {}, reports = [], helper } = {}) {
  cwd ??= await privateDir('omakase-helpers-');
  const rails = railsStandIn();
  const config = { storePath: join(cwd, 'state.sqlite'), limits: { frameIntervalMs: 20, helperRetryMs: 20, ...limits } };
  const deps = { ...scriptedProvider(routed(scripts)), invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    helper: helper ?? (async data => { reports.push(structuredClone(data)); return null; }) };
  const runtime = await createRuntime(config, deps);
  let closed = false;
  const close = async () => { if (!closed) { closed = true; await runtime.close(); } };
  t.after(close);
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  return { runtime, id, rails, reports, close, config, cwd };
}
const wait = async (runtime, sub) => (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
async function until(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('fixture_deadline');
}
const ended = reports => reports.filter(report => report.state !== 'running');

test('a background helper returns at once, works on while the agent is done, and reports how it ended', async t => {
  const f = await fixture(t, {
    parent: [background('Job A: save, then ask.', 'toolu_h'), message('A helper is on it.')],
    'Job A': [toolUse('note', { key: 'k' }, 'toolu_n'), toolUse('ask', { question: 'Tea?' }, 'toolu_a'), message('Job A is done: tea.')]
  });
  const sub = await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
  const { entries } = await f.runtime.entries(f.id, scope);
  assert.equal(entries.find(e => e.role === 'toolResult').content, backgroundStarted('toolu_h'));
  assert.equal(entries.at(-1).content, 'A helper is on it.');

  // The helper waits on the person; the agent's own run is over and not kept busy.
  await until(async () => f.rails.keys().length === 1);
  assert.equal((await f.runtime.snapshot(f.id, scope)).status, 'done');
  // On the agent's own model and level, which it says.
  assert.deepEqual(f.reports[0], { ...scope, conversationId: String(f.id), callId: 'toolu_h', state: 'running', task: 'Job A: save, then ask.', tools: [], count: 0,
    model: 'fixture/scripted', thinking: 'medium' });
  await until(async () => f.reports.some(report => report.tools?.some(tool => tool.name === 'ask')));
  const progress = f.reports.findLast(report => report.tools?.some(tool => tool.name === 'ask'));
  assert.deepEqual(progress.tools.map(tool => [tool.callId, tool.name]), [['toolu_n', 'note'], ['toolu_a', 'ask']]);
  assert.equal(progress.tools[0].status, 'done');

  // The person's answer reaches it through the root's doorbell.
  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['Tea'] });
  await f.runtime.wake(f.id, { ...scope, key });
  await until(async () => ended(f.reports).length === 1);
  const [done] = ended(f.reports);
  assert.equal(done.state, 'done');
  assert.equal(done.answer, 'Job A is done: tea.');
  assert.equal(done.conversationId, String(f.id));
  assert.deepEqual(done.tools.map(tool => [tool.name, tool.status]), [['note', 'done'], ['ask', 'done']]);
  assert.equal(done.count, 2);
  assert.ok(done.usage && typeof done.usage.totalTokens === 'number');
  // Its own models' and tools' rows too, since its thread's totals never count it (docs/billing.md).
  assert.equal(Object.values(done.usage.models).reduce((sum, row) => sum + row.totalTokens, 0) +
    Object.values(done.usage.tools).reduce((sum, row) => sum + row.totalTokens, 0), done.usage.totalTokens);
  // Its calls reached Rails as the root's, under the call that started it.
  assert.deepEqual([...new Set(f.rails.calls.map(c => [c.conversationId, c.callId].join(' ')))],
    [`${f.id} toolu_h/toolu_n`, `${f.id} toolu_h/toolu_a`]);
  // Its requests counted against its own bound, not the agent's run.
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 2);
  await new Promise(r => setTimeout(r, 100));
  assert.equal(ended(f.reports).length, 1);
  // It forgets the call that started it once it has ended.
  assert.deepEqual((await f.runtime.harness.snapshot(Helpers, ctx)).byCall, {});
});

test('the agent\'s Stop leaves a helper running; Cancel ends it and says what it had done', async t => {
  const f = await fixture(t, {
    parent: [background('Job B: save, then ask.', 'toolu_h'), message('On it.')],
    'Job B': [toolUse('note', { key: 'k' }, 'toolu_n'), toolUse('ask', { question: 'Tea?' }, 'toolu_a'), message('never')]
  });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  await until(async () => f.rails.keys().length === 1);

  assert.deepEqual(await f.runtime.cancel(f.id, { ...scope, requestId: 'stop' }), { cancelled: true });
  const live = async () => (await f.runtime.harness.inspect(ctx)).tasks.some(task => task.record.kind === 'omakase.helper');
  assert.equal(await live(), true);

  // Rails' sweep asks whether it still runs; asking stops nothing.
  assert.deepEqual(await f.runtime.helper(f.id, { ...scope, callId: 'toolu_h' }), { status: 'running' });
  assert.equal(await live(), true);
  const cancelled = await f.runtime.cancelHelper(f.id, { ...scope, callId: 'toolu_h' });
  assert.equal(cancelled.cancelled, true);
  assert.deepEqual(cancelled.tools.map(tool => [tool.callId, tool.name, tool.status]), [['toolu_n', 'note', 'done'], ['toolu_a', 'ask', 'stopped']]);
  assert.equal(cancelled.count, 2);
  assert.deepEqual(cancelled.tools[0].arguments, { key: 'k' });
  assert.equal(await live(), false);
  // Once is enough; an unknown call is not found; another person's scope is refused.
  assert.equal((await f.runtime.cancelHelper(f.id, { ...scope, callId: 'toolu_h' })).cancelled, false);
  await assert.rejects(f.runtime.cancelHelper(f.id, { ...scope, callId: 'toolu_x' }), { status: 404 });
  assert.deepEqual(await f.runtime.helper(f.id, { ...scope, callId: 'toolu_h' }), { status: 'terminal' });
  await assert.rejects(f.runtime.helper(f.id, { ...scope, callId: 'toolu_x' }), { status: 404 });
  await assert.rejects(f.runtime.cancelHelper(f.id, { actorId: 'mallory', workspaceId: 'one', callId: 'toolu_h' }));
  await new Promise(r => setTimeout(r, 100));
  assert.deepEqual(ended(f.reports), []);
  assert.deepEqual((await f.runtime.harness.snapshot(Helpers, ctx)).byCall, {});
});

test(`at most ${HELPERS_PER_CONVERSATION} helpers run in a conversation and ${HELPERS_PER_SIDECAR} in the sidecar`, async t => {
  const jobs = ['Job 1', 'Job 2', 'Job 3', 'Job 4', 'Job 5', 'Job 6', 'Job 7', 'Job 8'];
  const waitOnPerson = id => [toolUse('ask', { question: id }, `ask_${id}`), message('done')];
  const start = ids => message(ids.map(id => call('subagent', { task: `${id}.`, background: true }, { id: `h_${id.at(-1)}` })), { stopReason: 'toolUse' });
  const f = await fixture(t, {
    parent: [start(jobs.slice(0, 4)), message('first'), start(jobs.slice(4, 7)), message('second'), start(jobs.slice(7)), message('third')],
    ...Object.fromEntries(jobs.map(id => [id, waitOnPerson(id)]))
  });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'one', content: 'go', definition: definition() }));
  const refusals = async conversationId => (await f.runtime.entries(conversationId, scope)).entries
    .filter(e => e.role === 'toolResult' && e.isError).map(e => e.content);
  assert.deepEqual(await refusals(f.id), [`${HELPERS_PER_CONVERSATION} helpers are already working in this conversation, the most at once. Wait for one to finish, or do it yourself.`]);
  await until(async () => f.rails.keys().length === 3);

  // A second conversation runs three more, and then the sidecar is full.
  const { id: second } = await f.runtime.create({ ...scope, requestId: 'create-second' });
  await wait(f.runtime, await f.runtime.submit(second, { ...scope, requestId: 'two', content: 'go', definition: definition() }));
  assert.deepEqual(await refusals(second), []);
  await until(async () => f.rails.keys().length === 6);
  const { id: third } = await f.runtime.create({ ...scope, requestId: 'create-third' });
  await wait(f.runtime, await f.runtime.submit(third, { ...scope, requestId: 'three', content: 'go', definition: definition() }));
  assert.deepEqual(await refusals(third), [`${HELPERS_PER_SIDECAR} helpers are already working across every conversation here, the most at once. Wait for one to finish, or do it yourself.`]);
});

test('a helper whose report Rails could not take tells it again, once, and after a restart', async t => {
  const cwd = await privateDir('omakase-helpers-restart-');
  const scripts = { parent: [background('Job C: ask.', 'toolu_h'), message('On it.')],
    'Job C': [toolUse('ask', { question: 'Tea?' }, 'toolu_a'), message('Job C is done.')] };
  const first = await fixture(t, scripts, { cwd });
  await wait(first.runtime, await first.runtime.submit(first.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  await until(async () => first.rails.keys().length === 1);
  const key = first.rails.keys()[0];
  await first.close();

  // Rails refuses twice, then takes it.
  const reports = [];
  let refusals = 0;
  const helper = async data => {
    if (data.state !== 'running' && refusals < 2) { refusals++; throw new Error('rails_callback_failed'); }
    reports.push(data); return null;
  };
  const second = await fixture(t, { parent: [], 'Job C': [message('Job C is done.')] }, { cwd, helper });
  second.rails.decide(key, { selections: ['Tea'] });
  await second.runtime.wake(first.id, { ...scope, key });
  await until(async () => ended(reports).length === 1);
  assert.equal(refusals, 2);
  assert.equal(ended(reports)[0].answer, 'Job C is done.');
  await new Promise(r => setTimeout(r, 150));
  assert.equal(ended(reports).length, 1);
});

test('a background helper stops at its own request bound and reports it failed', async t => {
  const f = await fixture(t, {
    parent: [background('Job D: loop.', 'toolu_h'), message('On it.')],
    'Job D': [toolUse('note', { key: 'a' }, 'n1'), toolUse('note', { key: 'b' }, 'n2'), toolUse('note', { key: 'c' }, 'n3'), message('never')]
  }, { limits: { maxRequests: 3, maxRetries: 0 } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  await until(async () => ended(f.reports).length === 1);
  const [failed] = ended(f.reports);
  assert.equal(failed.state, 'failed');
  assert.equal(typeof failed.reason, 'string');
  assert.deepEqual(failed.tools.map(tool => tool.name), ['note', 'note', 'note']);
  // The agent's run kept its own two requests.
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 2);
});

test('a script cannot start a helper in the background: its line on the page is the call\'s own', async t => {
  const script = `return await tools.subagent({ task: 'Job E.', background: true });`;
  const f = await fixture(t, { parent: [message(call('codemode', { code: script }, { id: 'toolu_s' }), { stopReason: 'toolUse' }), message('done')] });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  const { entries } = await f.runtime.entries(f.id, scope);
  assert.match(entries.find(e => e.role === 'toolResult').content, /Start a helper in the background with a call of your own, not from a script\./);
  assert.equal((await f.runtime.harness.inspect(ctx)).tasks.some(task => task.record.kind === 'omakase.helper'), false);
  assert.deepEqual(f.reports, []);
});

test('a rerun of the call that started a helper finds it rather than starting another', async () => {
  const tool = subagentExtension({ toolLine: slot => slot, modelOf: () => ({ reasoning: true }) }).tools[0];
  const helpers = { byCall: {} }, created = [];
  const stored = { byDigest: { d: { model: 'fixture/scripted', thinkingLevel: 'medium' } }, conversations: { 3: 'd' } };
  const tx = { doc: async kind => kind === Definitions ? stored : helpers, scanTasks: async () => ({ items: [], next: undefined }),
    createTask: async (task, input, options) => { created.push({ input, options }); return created.length; } };
  const api = { callId: 'toolu_h', taskId: 7, conversationId: 3, commit: async change => change(tx) };
  for (let run = 0; run < 2; run++) {
    assert.equal((await tool.execute({ task: 'Job F.', background: true }, api, ctx)).output[0].text, backgroundStarted('toolu_h'));
  }
  assert.deepEqual(created, [{ input: { callId: 'toolu_h', task: 'Job F.', context: null, model: { id: 'fixture/scripted', label: 'fixture/scripted', thinkingLevel: 'medium' } },
    options: { ownership: { kind: 'conversation' }, conversationId: 3, background: true } }]);
  assert.deepEqual(helpers.byCall, { 7: 1 });
});

test('a helper whose ending Rails never takes stops trying in the end', async t => {
  const tried = [];
  const f = await fixture(t, { parent: [background('Job G.', 'toolu_h'), message('On it.')], 'Job G': [message('Job G is done.')] },
    { limits: { helperReportForMs: 100 }, helper: async data => { if (data.state !== 'running') { tried.push(data.state); throw new Error('rails_callback_failed'); } } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  const live = async () => (await f.runtime.harness.inspect(ctx)).tasks.some(task => task.record.kind === 'omakase.helper');
  await until(async () => tried.length > 0 && !(await live()));
  const count = tried.length;
  assert.ok(count >= 2, `tried ${count} times`);
  await new Promise(r => setTimeout(r, 150));
  assert.equal(tried.length, count);
});

test('a person\'s message reaches a working helper at its next step; one that ended takes none', async t => {
  const seen = [];
  const f = await fixture(t, {
    parent: [background('Job S: ask, then book.', 'toolu_h'), message('On it.')],
    'Job S': [toolUse('ask', { question: 'Which day?' }, 'toolu_a'), context => { seen.push(JSON.stringify(context.messages)); return message('Booked Rome for Friday.'); }]
  });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  await until(async () => f.rails.keys().length === 1);

  const text = '[Message from the person] Rome, not Paris.';
  assert.deepEqual(await f.runtime.messageHelper(f.id, { ...scope, callId: 'toolu_h', requestId: 'm1', text }), { delivered: true });
  // The same request is the same message.
  assert.deepEqual(await f.runtime.messageHelper(f.id, { ...scope, callId: 'toolu_h', requestId: 'm1', text }), { delivered: true });
  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['Friday'] });
  await f.runtime.wake(f.id, { ...scope, key });
  await until(async () => ended(f.reports).length === 1);
  assert.equal(ended(f.reports)[0].answer, 'Booked Rome for Friday.');
  assert.equal(seen.length, 1, 'read in the turn it was working on, not a turn of its own');
  assert.equal(seen[0].split('Rome, not Paris.').length - 1, 1, 'once');
  assert.ok(seen[0].indexOf('Friday') < seen[0].indexOf('Rome, not Paris.'), 'after the call it was waiting on');

  assert.deepEqual(await f.runtime.messageHelper(f.id, { ...scope, callId: 'toolu_h', requestId: 'm2', text: 'And a hotel.' }), { delivered: false });
  await assert.rejects(f.runtime.messageHelper(f.id, { ...scope, callId: 'toolu_x', requestId: 'm3', text: 'Hello?' }), { status: 404 });
  await assert.rejects(f.runtime.messageHelper(f.id, { ...scope, callId: 'toolu_h', requestId: 'm4', text: ' ' }), { status: 422 });
  await assert.rejects(f.runtime.messageHelper(f.id, { actorId: 'mallory', workspaceId: 'one', callId: 'toolu_h', requestId: 'm5', text: 'Hi' }));
});

test('a message that arrives as the helper writes its answer is still read, and the answer after it is the one reported', async t => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const f = await fixture(t, {
    parent: [background('Job U: book.', 'toolu_h'), message('On it.')],
    'Job U': [async () => { await gate; return message('Booked Paris.'); }, message('Booked Rome instead.')]
  });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  await until(async () => f.reports.length > 0);
  const live = async () => (await f.runtime.harness.inspect(ctx)).tasks.some(task => task.record.kind === 'omakase.helper');
  await until(live);
  await new Promise(r => setTimeout(r, 50));
  assert.deepEqual(await f.runtime.messageHelper(f.id, { ...scope, callId: 'toolu_h', requestId: 'm1', text: 'Rome, not Paris.' }), { delivered: true });
  release();
  await until(async () => ended(f.reports).length === 1);
  assert.equal(ended(f.reports)[0].answer, 'Booked Rome instead.');
});

test('the agent tells its helper something with message_helper, by the call that started it', async t => {
  const seen = [];
  const f = await fixture(t, {
    parent: [background('Job T: ask, then book.', 'toolu_h'), message('On it.'),
      toolUse('message_helper', { helper: 'toolu_h', message: 'Rome, not Paris.' }, 'toolu_m'), message('Told it.'),
      toolUse('message_helper', { helper: 'toolu_h', message: 'And a hotel.' }, 'toolu_m2'), message('Too late.'),
      toolUse('message_helper', { helper: 'toolu_nope', message: 'Hello?' }, 'toolu_m3'), message('No such helper.')],
    'Job T': [toolUse('ask', { question: 'Which day?' }, 'toolu_a'), context => { seen.push(JSON.stringify(context.messages)); return message('Booked Rome.'); }]
  });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'start it', definition: definition() }));
  await until(async () => f.rails.keys().length === 1);
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'steer', content: 'Tell it Rome.' }));
  const results = async () => (await f.runtime.entries(f.id, scope)).entries.filter(e => e.role === 'toolResult' && e.toolName === 'message_helper');
  assert.deepEqual((await results()).map(e => [e.content, !!e.isError]), [['The helper has your message. It reads it at its next step.', false]]);

  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['Friday'] });
  await f.runtime.wake(f.id, { ...scope, key });
  await until(async () => ended(f.reports).length === 1);
  assert.match(seen[0], /Message from the assistant who gave you this task, sent while you work\] Rome, not Paris\./);
  assert.equal(ended(f.reports)[0].answer, 'Booked Rome.');

  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'late', content: 'And a hotel.' }));
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'none', content: 'Hello?' }));
  assert.deepEqual((await results()).slice(1).map(e => [e.content, !!e.isError]), [
    ['That helper has already finished, so it can\'t take a message. Its answer comes as a message.', true],
    ['No helper started by that call is working in this conversation.', true]]);
});

// Rails starts a helper itself for each step of a workflow (Rails' Workflow::Step),
// naming the call: the same helper, caps and reports as the agent's own.
const ready = async f => wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'hello', content: 'hi', definition: definition() }));

test('Rails starts a helper for a workflow step, once for its call, and it reports as the agent\'s own do', async t => {
  const f = await fixture(t, { parent: [message('Hello.')],
    'Step one': [toolUse('note', { key: 'k' }, 'toolu_n'), message('Step one found three hotels.')] });
  await assert.rejects(f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-1', task: 'Step one.' }), { status: 409, category: 'conversation_not_started' });
  await ready(f);

  assert.deepEqual(await f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-1', task: 'Step one: find hotels.', context: 'In Lisbon.' }), { started: true });
  assert.deepEqual(await f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-1', task: 'Step one: find hotels.' }), { started: false });
  await until(async () => ended(f.reports).length === 1);
  const [done] = ended(f.reports);
  assert.deepEqual([done.callId, done.state, done.answer, done.task], ['workflow-1-1', 'done', 'Step one found three hotels.', 'Step one: find hotels.']);
  assert.deepEqual(f.rails.calls.map(c => c.callId), ['workflow-1-1/toolu_n']);
  // Asked again once it has ended, it still starts nothing.
  assert.deepEqual(await f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-1', task: 'Step one: find hotels.' }), { started: false });
  await new Promise(r => setTimeout(r, 100));
  assert.equal(ended(f.reports).length, 1);

  await assert.rejects(f.runtime.startHelper(f.id, { ...scope, callId: 'toolu_s/c1', task: 'x' }), { status: 422, category: 'invalid_call' });
  await assert.rejects(f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-2', task: ' ' }), { status: 422, category: 'invalid_task' });
  await assert.rejects(f.runtime.startHelper(f.id, { actorId: 'mallory', workspaceId: 'one', callId: 'workflow-1-2', task: 'x' }), { status: 404 });
});

test(`a workflow step waits its turn at ${HELPERS_PER_CONVERSATION} helpers: Rails is told why, and a later start works`, async t => {
  const jobs = ['Step 1', 'Step 2', 'Step 3', 'Step 4'];
  const f = await fixture(t, { parent: [message('Hello.')],
    ...Object.fromEntries(jobs.map(id => [id, [toolUse('ask', { question: id }, `ask_${id.at(-1)}`), message(`${id} done.`)]])) });
  await ready(f);
  for (const job of jobs.slice(0, 3)) assert.equal((await f.runtime.startHelper(f.id, { ...scope, callId: `w-${job.at(-1)}`, task: `${job}.` })).started, true);
  await assert.rejects(f.runtime.startHelper(f.id, { ...scope, callId: 'w-4', task: 'Step 4.' }),
    { status: 429, category: 'helpers_busy', detail: `${HELPERS_PER_CONVERSATION} helpers are already working in this conversation, the most at once. Wait for one to finish, or do it yourself.` });
  await until(async () => f.rails.keys().length === 3);
  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['ok'] });
  await f.runtime.wake(f.id, { ...scope, key });
  await until(async () => ended(f.reports).length === 1);
  await until(async () => !(await f.runtime.harness.inspect(ctx)).tasks.some(task => task.record.kind === 'omakase.helper' && task.record.input?.callId === ended(f.reports)[0].callId));
  assert.equal((await f.runtime.startHelper(f.id, { ...scope, callId: 'w-4', task: 'Step 4.' })).started, true);
  // Cancel finds a step's helper by its call, as it finds the agent's own.
  assert.equal((await f.runtime.cancelHelper(f.id, { ...scope, callId: 'w-4' })).cancelled, true);
});

test('a workflow step\'s helper goes on after a sidecar restart and reports once', async t => {
  const cwd = await privateDir('omakase-helpers-step-restart-');
  const first = await fixture(t, { parent: [message('Hello.')], 'Step R': [toolUse('ask', { question: 'Tea?' }, 'toolu_a'), message('never')] }, { cwd });
  await ready(first);
  assert.equal((await first.runtime.startHelper(first.id, { ...scope, callId: 'workflow-9-1', task: 'Step R: ask.' })).started, true);
  await until(async () => first.rails.keys().length === 1);
  const key = first.rails.keys()[0];
  await first.close();

  const reports = [];
  const second = await fixture(t, { parent: [], 'Step R': [message('Step R is done.')] }, { cwd, reports });
  // Rails asks again, not knowing whether the first request landed: nothing new starts.
  assert.deepEqual(await second.runtime.startHelper(first.id, { ...scope, callId: 'workflow-9-1', task: 'Step R: ask.' }), { started: false });
  second.rails.decide(key, { selections: ['Tea'] });
  await second.runtime.wake(first.id, { ...scope, key });
  await until(async () => ended(reports).length === 1);
  assert.deepEqual([ended(reports)[0].callId, ended(reports)[0].answer], ['workflow-9-1', 'Step R is done.']);
  await new Promise(r => setTimeout(r, 150));
  assert.equal(ended(reports).length, 1);
});

test('a script starts a workflow as it calls any of Rails\' tools, with the definition whole', async t => {
  const runWorkflow = { name: 'run_workflow', description: 'Start a workflow',
    parameters: { type: 'object', additionalProperties: false, required: ['name', 'kind', 'steps'], properties: {
      name: { type: 'string' }, kind: { type: 'string', enum: ['fan_out', 'pipeline'] },
      steps: { type: 'array', items: { type: 'object', additionalProperties: false, required: ['task'], properties: { task: { type: 'string' } } } } } } };
  const workflow = { name: 'Hotels', kind: 'fan_out', steps: [{ task: 'Lisbon hotels.' }, { task: 'Porto hotels.' }] };
  const script = `return await tools.run_workflow(${JSON.stringify(workflow)});`;
  const f = await fixture(t, { parent: [toolUse('codemode', { code: script }, 'toolu_s'), message('Started.')] });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'go',
    definition: definition({ tools: [...FIXTURE_TOOLS, runWorkflow] }) }));
  const [sent] = f.rails.calls;
  assert.deepEqual([sent.callId, sent.tool, sent.arguments], ['toolu_s/c1', 'run_workflow', workflow]);
  const { entries } = await f.runtime.entries(f.id, scope);
  assert.match(entries.find(e => e.role === 'toolResult').content, /Lisbon hotels\./);
});
