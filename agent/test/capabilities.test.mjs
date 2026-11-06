// The sidecar's built-in capabilities (PARITY.md §1, §10): helpers and web
// search. Scripted model, a Rails stand-in and stubbed provider responses only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { createRuntime } from '../runtime.mjs';
import { App } from '../state.mjs';
import { HELPER_INSTRUCTIONS } from '../subagent.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const toolUse = (name, args, id) => message(call(name, args, { id }), { stopReason: 'toolUse' });
async function fixture(t, responses, { deps = {}, ...config } = {}) {
  const cwd = await privateDir('omakase-capabilities-');
  const provider = scriptedProvider(responses);
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...provider,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    invoke: rails.invoke, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  return { runtime, id, rails, provider, cwd };
}
const wait = async (runtime, sub) => (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
async function until(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('fixture_deadline');
}

test('a helper runs the task in a child conversation and its answer is the call result; its calls reach Rails as the root', async t => {
  const frames = [], seen = {};
  const f = await fixture(t, [
    toolUse('subagent', { task: 'Save the note, then ask.' }, 'toolu_h'),
    context => {
      seen.instructions = JSON.stringify(context);
      seen.tools = getCurrentTools(context.messages).map(tool => tool.name);
      seen.task = JSON.stringify(context.messages);
      return toolUse('note', { key: 'k' }, 'toolu_n');
    },
    toolUse('ask', { question: 'Tea?' }, 'toolu_a'),
    message('The helper saved it; the person wants tea.'),
    message('All done.')
  ], { limits: { frameIntervalMs: 20 }, deps: { frame: async data => { frames.push(data); } } });
  const sub = await f.runtime.submit(f.id, { ...scope, requestId: 'help', content: 'get help', definition: definition({ instructions: 'Fixture persona.' }) });

  // The child's question waits like any call, under the root; the root's doorbell finds it.
  await until(async () => f.rails.keys().length === 1);
  assert.equal((await f.runtime.snapshot(f.id, scope)).status, 'waiting');
  // Long enough for the helper's running call to reach a frame.
  await until(async () => frames.some(frame => frame.tools.some(tool => tool.callId === 'toolu_h/toolu_a')));
  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['Tea'] });
  assert.deepEqual(await f.runtime.wake(f.id, { ...scope, key }), { rung: true });
  assert.equal((await wait(f.runtime, sub)).status, 'done');

  assert.deepEqual(f.rails.calls.map(c => [c.tool, c.conversationId, c.callId]),
    [['note', String(f.id), 'toolu_h/toolu_n'], ['ask', String(f.id), 'toolu_h/toolu_a'], ['ask', String(f.id), 'toolu_h/toolu_a']]);
  // The parent's model, instructions and tools, without helpers of its own.
  assert.match(seen.instructions, /Fixture persona\./);
  assert.ok(seen.instructions.includes(HELPER_INSTRUCTIONS));
  assert.ok(seen.tools.includes('note') && seen.tools.includes('codemode'));
  assert.equal(seen.tools.includes('subagent'), false);
  assert.match(seen.task, /Save the note, then ask\./);

  const { entries } = await f.runtime.entries(f.id, scope);
  const result = entries.find(e => e.role === 'toolResult');
  assert.equal(result.toolName, 'subagent');
  assert.equal(result.content, 'The helper saved it; the person wants tea.');
  assert.equal(entries.at(-1).content, 'All done.');
  // The root's run bound counts the helper's model requests too.
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 5);
  // The helper's running calls show under its line in the root's frames.
  await until(async () => frames.at(-1)?.busy === false);
  const helperTools = frames.flatMap(frame => frame.tools).filter(tool => tool.callId.startsWith('toolu_h/'));
  assert.ok(helperTools.some(tool => tool.callId === 'toolu_h/toolu_a' && tool.name === 'ask'), JSON.stringify(helperTools));
  assert.ok(frames.flatMap(frame => frame.tools).some(tool => tool.callId === 'toolu_h' && tool.name === 'subagent'));
});

test('the helper runs within the parent run\'s request bound', async t => {
  const f = await fixture(t, [toolUse('subagent', { task: 'Loop.' }, 'toolu_h'), toolUse('note', { key: 'a' }, 'n1'),
    toolUse('note', { key: 'b' }, 'n2'), message('never')], { limits: { maxRequests: 3, maxRetries: 0 } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'bound', content: 'x', definition: definition() }));
  const { entries } = await f.runtime.entries(f.id, scope);
  const result = entries.find(e => e.role === 'toolResult' && e.toolName === 'subagent');
  assert.equal(result.isError, true);
  assert.match(result.content, /stopped without an answer/);
  assert.equal(f.rails.calls.length, 2);
});

test('a bot without helpers has no subagent tool', async t => {
  const f = await fixture(t, [message('one')]);
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'x', content: 'x', definition: definition({ capabilities: ['codemode'] }) }));
  const tools = (await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx)).tools.map(tool => tool.name);
  assert.equal(tools.includes('subagent'), false);
});
