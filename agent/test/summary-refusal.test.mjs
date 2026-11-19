// A summary the model's provider refuses (a safety filter, not an error that
// passes): retried once on another offered model, and, refused there too, not
// asked for again on its own after every turn. Scripted models only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { LiveDoc, UsageDoc } from '@earendil-works/pi-durable';
import * as sidecar from '../runtime.mjs';

// Through the module, so a missing export fails its own test.
const { createRuntime, failureReason, DEFAULT_LIMITS } = sidecar;
const summaryFallback = (...args) => sidecar.summaryFallback(...args);
const refusedSummary = message => sidecar.refusedSummary(message);
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const summarising = context => JSON.stringify(context.messages).includes('context summarization assistant');
// What Anthropic's `stop_reason: "refusal"` becomes in pi-ai: an error, with the provider's stop reason kept raw.
const refusal = () => ({ ...message('', { stopReason: 'error', errorMessage: 'Safeguards flagged this message.' }), rawStopReason: 'refusal' });
const WINDOW = 4000;
const filler = n => `${n} `.repeat(330).slice(0, 1000);
// The conversation's own model, and a lighter one the install also offers.
const MODELS = [{ id: 'scripted', reasoning: true, contextWindow: WINDOW, maxTokens: 500, cost: { input: 4, output: 20, cacheRead: 0, cacheWrite: 0 } },
  { id: 'lighter', reasoning: true, contextWindow: WINDOW, maxTokens: 500, cost: { input: 1, output: 5, cacheRead: 0, cacheWrite: 0 } }];
const ROUTES = MODELS.map(model => ({ provider: 'fixture', modelId: model.id }));

// Every answer and summary from one script; `refuses` says which models refuse to summarise.
function script(calls, refuses) {
  return Array.from({ length: 400 }, () => (context, _options, _state, model) => {
    if (!summarising(context)) return message('answer');
    calls.push(model.id);
    return refuses.includes(model.id) ? refusal() : message('SUMMARY: the person sent numbered filler.');
  });
}

async function setup(t, responses, { config = {}, deps = {} } = {}) {
  const cwd = await privateDir('omakase-refusal-');
  const provider = scriptedProvider(responses, { models: MODELS });
  const frames = [];
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), limits: { maxRetries: 0, frameIntervalMs: 5 }, ...config }, {
    ...provider, routes: ROUTES, authorize: async requested => ({ ...requested, allowed: true, cwd }),
    invoke: async () => ({ status: 'done', result: {} }), frame: async payload => { frames.push(payload); }, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId, content = requestId) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { runtime, id, run, frames };
}

test('a refusal is told by the provider\'s stop reason, not its words', () => {
  assert.equal(refusedSummary(refusal()), true);
  for (const raw of ['refusal', 'sensitive', 'content_filter', 'SAFETY', 'PROHIBITED_CONTENT', 'guardrail_intervened', 'incomplete.content_filter'])
    assert.equal(refusedSummary({ stopReason: 'error', rawStopReason: raw }), true, raw);
  assert.equal(refusedSummary(message('', { stopReason: 'error', errorMessage: 'refused: 429 rate limited' })), false);
  assert.equal(refusedSummary({ ...message('SUMMARY'), rawStopReason: 'end_turn' }), false);
});

test('the fallback is the cheapest other offered model of the same provider whose window holds as much; config may name one or none', () => {
  const catalogue = {
    'p/big': { contextWindow: 1000000, cost: { input: 4 } }, 'p/mid': { contextWindow: 1000000, cost: { input: 2 } },
    'p/tiny': { contextWindow: 200000, cost: { input: 0.5 } }, 'p/small': { contextWindow: 1000000, cost: { input: 0.1 } },
    'q/cheap': { contextWindow: 1000000, cost: { input: 0.01 } } };
  const routes = Object.keys(catalogue).map(name => ({ provider: name.split('/')[0], modelId: name.split('/')[1] }));
  const modelOf = route => catalogue[`${route.provider}/${route.modelId}`];
  const name = route => route && `${route.provider}/${route.modelId}`;
  assert.equal(name(summaryFallback(routes[0], routes, modelOf)), 'p/small');
  assert.equal(name(summaryFallback(routes[3], routes, modelOf)), 'p/mid');
  // Another provider only when the conversation's has nothing that fits.
  assert.equal(name(summaryFallback({ provider: 'q', modelId: 'cheap' }, routes, modelOf)), 'p/small');
  assert.equal(name(summaryFallback(routes[0], routes, modelOf, 'p/mid')), 'p/mid');
  assert.equal(summaryFallback(routes[0], routes, modelOf, false), undefined);
  assert.equal(summaryFallback(routes[1], [routes[1]], modelOf), undefined);
  assert.equal(DEFAULT_LIMITS.summaryBackoffMs, 1800000);
});

test('refused on the conversation\'s model, the summary is written by the fallback, which is recorded on the summary and in usage', async t => {
  const calls = [];
  const f = await setup(t, script(calls, ['scripted']), { config: { compaction: { keepRecentTokens: 1, reserveTokens: 1500, backgroundTokens: 0 } } });
  for (const words of ['first', 'second']) assert.equal((await f.run(words)).status, 'done');
  await f.runtime.compact(f.id, { ...scope, requestId: 'c-1' });
  const entries = async () => (await f.runtime.entries(f.id, scope)).entries;
  const summary = await eventually(async () => (await entries()).find(entry => entry.role === 'summary'));
  assert.deepEqual(calls, ['scripted', 'lighter']);
  assert.match(summary.content, /SUMMARY: the person sent numbered filler\./);
  assert.match(summary.content, /Summarized by fixture\/lighter: fixture\/scripted's provider refused/);
  const usage = await f.runtime.harness.snapshot(UsageDoc, f.id, ctx);
  assert.ok(usage.models['fixture/lighter']?.input > 0, 'the fallback\'s summary is counted');
  assert.ok(usage.models['fixture/scripted']?.input > 0, 'the refused request is counted too');
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.compactionFailed, null);
});

test('refused on every model: one failure that says why, no summary on its own until the back-off ends, /compact any time', async t => {
  const calls = [];
  let now = Date.parse('2026-01-01T00:00:00Z');
  const f = await setup(t, script(calls, ['scripted', 'lighter']), {
    config: { compaction: { reserveTokens: 1500, keepRecentTokens: 1000, backgroundTokens: 0 }, limits: { maxRetries: 0, frameIntervalMs: 5, summaryBackoffMs: 600000 } },
    deps: { now: () => now } });
  const statuses = [];
  let n = 0;
  while (calls.length === 0 && n < 40) statuses.push((await f.run(`input-${++n}`, filler(n))).status);
  assert.deepEqual(calls, ['scripted', 'lighter'], 'one refused summary, retried once on the fallback');
  assert.equal(statuses.at(-1), 'unanswered');
  const view = await f.runtime.snapshot(f.id, scope);
  assert.deepEqual(view.failure, { reason: 'compaction_refused' });
  assert.deepEqual(view.compactionFailed, { trigger: 'threshold', reason: 'refused' });
  await eventually(() => f.frames.some(frame => frame.compactionFailed?.reason === 'refused'));
  assert.doesNotMatch(JSON.stringify([view, f.frames]), /Safeguards flagged/);
  assert.match((await f.runtime.harness.snapshot(LiveDoc, f.id, ctx)).compactionFailure.error, /Safeguards flagged/);

  // Over the threshold every turn, yet nothing is summarised and every turn is answered.
  for (let more = 0; more < 4; more++) assert.equal((await f.run(`later-${more}`, filler(n + more))).status, 'done');
  assert.equal(calls.length, 2);

  // The person can still ask for one.
  await f.runtime.compact(f.id, { ...scope, requestId: 'c-1' });
  await eventually(() => calls.length === 4);
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).compaction === null);

  // Once the back-off has passed, the threshold asks again.
  now += 600001;
  await f.run('after-backoff', filler(99));
  assert.ok(calls.length > 4, `asked again after the back-off: ${calls.length}`);
});

test('the reason a run that waited for a refused summary stopped', () => {
  assert.equal(failureReason({ reason: 'model_error', detail: 'Compaction failed: Summarization failed: summary_refused: words' }), 'compaction_refused');
  assert.equal(failureReason({ reason: 'model_error', detail: 'Compaction failed: Summarization failed: other words' }), 'compaction_failed');
});
