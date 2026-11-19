// A helper's model and thinking (subagent.mjs): the agent's own unless its
// call names another of the models Rails offers it (the definition's
// `helperModels`), by the name its settings show; an unknown model, or a level
// that model doesn't support, is refused with the choices. Its report names
// what it ran on. Scripted models and a Rails stand-in only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxProvider, fauxAssistantMessage as message, fauxToolCall as call } from '@earendil-works/pi-ai/providers/faux';
import { createRuntime } from '../runtime.mjs';
import { HELPER_INSTRUCTIONS } from '../subagent.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const toolUse = (name, args, id) => message(call(name, args, { id }), { stopReason: 'toolUse' });
// What Rails offers (Agent#definition): each model's route, name and label as its settings show them.
const OFFERED = [{ id: 'fixture/scripted', name: 'Scripted', label: 'Scripted · Subscription' },
  { id: 'fixture/quick', name: 'Quick 1', label: 'Quick 1 · API key' }];
const agent = (extra = {}) => definition({ helperModels: OFFERED, ...extra });

// Two models: `scripted` thinks, `quick` doesn't. Each request is recorded:
// who asked (the agent or a helper), on which model, at which level.
async function fixture(t, scripts) {
  const cwd = await privateDir('omakase-helper-models-');
  const asked = [];
  const queues = { parent: [...scripts.parent], helper: [...scripts.helper] };
  const answer = (context, options, _state, model) => {
    const who = JSON.stringify(context).includes(HELPER_INSTRUCTIONS) ? 'helper' : 'parent';
    asked.push({ who, model: model.id, reasoning: options?.reasoning ?? 'off' });
    const next = queues[who].shift();
    if (!next) throw new Error(`no scripted answer for ${who}`);
    return next;
  };
  const faux = fauxProvider({ provider: 'fixture', models: [{ id: 'scripted', name: 'Scripted', reasoning: true }, { id: 'quick', name: 'Quick 1', reasoning: false }] });
  faux.setResponses(Array.from({ length: 16 }, () => answer));
  const models = createModels();
  models.setProvider(faux.provider);
  const reports = [], rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), limits: { frameIntervalMs: 20, helperRetryMs: 20 } }, {
    models, model: { provider: 'fixture', modelId: 'scripted' }, routes: [{ provider: 'fixture', modelId: 'scripted' }, { provider: 'fixture', modelId: 'quick' }],
    invoke: rails.invoke, authorize: async requested => ({ ...requested, allowed: true, cwd }),
    helper: async data => { reports.push(structuredClone(data)); return null; } });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  return { runtime, id, asked, reports };
}
const wait = async (runtime, sub) => (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
async function until(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('fixture_deadline');
}
async function helperResult(f, args, extra) {
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'hand it off', definition: agent(extra) }));
  return (await f.runtime.entries(f.id, scope)).entries.find(entry => entry.role === 'toolResult');
}

test('a helper given another offered model, by its name, runs on it, and its report names the model and level', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job Q', model: 'Quick 1' }, 'toolu_h'), message('done')], helper: [message('quick answer')] });
  const result = await helperResult(f);
  assert.equal(result.isError, undefined);
  assert.deepEqual(f.asked.filter(each => each.who === 'helper').map(each => [each.model, each.reasoning]), [['quick', 'off']]);
  assert.deepEqual(f.asked.filter(each => each.who === 'parent').map(each => each.model), ['scripted', 'scripted']);
  assert.match(result.content, /^quick answer/);
  assert.match(result.content, /Quick 1 · API key/);
  assert.match(result.content, /thinking: off/);
});

test('its label, or its route, names a model too, and a level it supports is used as given', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job S', model: 'scripted · subscription', thinking: 'high' }, 'toolu_h'), message('done')],
    helper: [message('deep answer')] });
  const result = await helperResult(f, undefined, { thinkingLevel: 'low' });
  assert.deepEqual(f.asked.filter(each => each.who === 'helper').map(each => [each.model, each.reasoning]), [['scripted', 'high']]);
  assert.match(result.content, /Scripted · Subscription, thinking: high/);
});

test('an unknown model is refused with the choices, and no helper starts', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job U', model: 'Huge 9' }, 'toolu_h'), message('done')], helper: [] });
  const result = await helperResult(f);
  assert.equal(result.isError, true);
  assert.match(result.content, /no model “Huge 9”/);
  assert.match(result.content, /Scripted · Subscription.*Quick 1 · API key/);
  assert.equal(f.asked.filter(each => each.who === 'helper').length, 0);
});

test('a model the agent isn\'t offered is refused, even one the sidecar could run', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job U', model: 'fixture/quick' }, 'toolu_h'), message('done')], helper: [] });
  const result = await helperResult(f, undefined, { helperModels: [OFFERED[0]] });
  assert.equal(result.isError, true);
  assert.match(result.content, /Choose one of: Scripted · Subscription\./);
  assert.equal(f.asked.filter(each => each.who === 'helper').length, 0);
});

test('a level the model doesn\'t support is refused with its levels, never swapped for another', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job L', model: 'Quick 1', thinking: 'high' }, 'toolu_h'), message('done')], helper: [] });
  const result = await helperResult(f);
  assert.equal(result.isError, true);
  assert.match(result.content, /Quick 1 · API key can't think at “high”\. Its levels: off\./);
  assert.equal(f.asked.filter(each => each.who === 'helper').length, 0);
});

test('without either, a helper runs on the agent\'s own model and level, and its answer is as before', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job D' }, 'toolu_h'), message('done')], helper: [message('own answer')] });
  const result = await helperResult(f);
  assert.deepEqual(f.asked.filter(each => each.who === 'helper').map(each => [each.model, each.reasoning]), [['scripted', 'medium']]);
  assert.equal(result.content, 'own answer', 'its own model needs no saying');
});

test('a background helper on another model tells Rails which, and so does one Rails starts for a workflow\'s step', async t => {
  const f = await fixture(t, { parent: [toolUse('subagent', { task: 'Job B', model: 'Quick 1', background: true }, 'toolu_h'), message('on it')],
    helper: [message('b answer'), message('step answer')] });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'hand it off', definition: agent() }));
  const ended = await until(async () => f.reports.find(report => report.callId === 'toolu_h' && report.state === 'done'));
  assert.equal(ended.model, 'fixture/quick');
  assert.equal(ended.thinking, 'off');
  assert.ok(f.reports.filter(report => report.callId === 'toolu_h').every(report => report.model === 'fixture/quick'));
  assert.equal(ended.answer, 'b answer\n\n(The helper ran on Quick 1 · API key, thinking: off.)');
  // Rails meters a background helper by its report's rows (Helper#meter): its spend is the model it ran on, not the agent's.
  assert.deepEqual(Object.keys(ended.usage.models), ['fixture/quick']);
  assert.ok(ended.usage.models['fixture/quick'].totalTokens > 0);

  await assert.rejects(f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-1', task: 'Step', model: 'Huge 9' }),
    error => error.status === 422 && error.category === 'helper_model_refused' && /Quick 1 · API key/.test(error.detail));
  assert.deepEqual(await f.runtime.startHelper(f.id, { ...scope, callId: 'workflow-1-2', task: 'Step', model: 'fixture/scripted', thinking: 'low' }), { started: true });
  const step = await until(async () => f.reports.find(report => report.callId === 'workflow-1-2' && report.state === 'done'));
  assert.equal(step.model, 'fixture/scripted');
  assert.equal(step.thinking, 'low');
  assert.deepEqual(f.asked.filter(each => each.who === 'helper').map(each => [each.model, each.reasoning]), [['quick', 'off'], ['scripted', 'low']]);
});
