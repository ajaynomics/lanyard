import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from '@earendil-works/pi-ai/providers/faux';
import { createRegistry, defineExtension, defineTool, Harness } from '@earendil-works/pi-durable';
import { MemoryStorage } from '@earendil-works/pi-durable/storage/memory';
import { obj } from '@earendil-works/pi-schema';
import { createRuntime, TOOL_EXECUTION } from '../runtime.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

// earendil-works/pi#11892's reproduction, as filed: three parallel tool calls,
// with a few event-loop hops after tool bodies and commits. The generation is
// never woken after they all end. Resolves true when the turn settles.
async function settles(toolExecution) {
  const hop = () => new Promise(resolve => setImmediate(resolve));
  const counter = delays => { let n = 0; return async () => {
    const [micro, hops] = delays[n++] ?? [0, 0];
    for (let i = 0; i < micro; i++) await Promise.resolve();
    for (let i = 0; i < hops; i++) await hop();
  }; };
  const toolDelay = counter({ 3: [0, 1], 4: [0, 1] });
  const commitDelay = counter({ 6: [0, 1], 8: [0, 1], 10: [2, 0] });
  const faux = fauxProvider({ provider: 'faux', models: [{ id: 'm' }], tokenSize: { min: 1000, max: 1000 } });
  faux.setResponses([fauxAssistantMessage([fauxToolCall('t', {}), fauxToolCall('t', {}), fauxToolCall('t', {})], { stopReason: 'toolUse' }),
    fauxAssistantMessage('done')]);
  const models = createModels();
  models.setProvider(faux.provider);
  const ext = defineExtension({ name: 't', tools: [defineTool({ name: 't', description: 't', parameters: obj({}),
    execute: async () => { await toolDelay(); await toolDelay(); return { output: [{ type: 'text', text: 'ok' }] }; } })] });
  const registry = createRegistry();
  registry.install(ext);
  const memory = new MemoryStorage();
  const storage = new Proxy(memory, { get(target, prop) {
    const value = Reflect.get(target, prop, target);
    if (prop === 'commit') return async (...args) => { const result = await value.apply(target, args); await commitDelay(); return result; };
    return typeof value === 'function' ? value.bind(target) : value;
  } });
  const harness = await Harness.open(storage, { models, registry, settings: { toolExecution } }, ctx);
  const conversation = await harness.createConversation({ ownership: { kind: 'ownerless' },
    agent: { model: { provider: 'faux', modelId: 'm' }, extensions: [ext] } }, ctx);
  const submission = await conversation.submit({ type: 'input', content: 'go' }, ctx);
  // A timer that holds the event loop open: a hung harness leaves nothing else pending.
  const timer = new AbortController();
  const timeout = setTimeout(() => timer.abort(), 2000);
  const settled = await submission.wait({ ...ctx, abortSignal: timer.signal }).then(() => true, () => false);
  clearTimeout(timeout);
  return settled;
}

test('pi-durable 1.5.0 hangs a turn on parallel tool calls (pi#11892); one at a time it settles', async () => {
  // When this fails, Durable has fixed it: TOOL_EXECUTION can go back to parallel.
  assert.equal(await settles('parallel'), false, 'parallel tool calls hang');
  assert.equal(TOOL_EXECUTION, 'sequential');
  assert.equal(await settles(TOOL_EXECUTION), true);
});

test('the sidecar runs a round of tool calls one at a time, and the turn ends', async t => {
  const cwd = await privateDir('omakase-tool-calls-');
  let running = 0, most = 0;
  const slow = defineExtension({ name: 'fixture.slow', tools: [defineTool({ name: 'fx_slow', description: 'Slow', parameters: obj({}),
    replay: 'safe', execute: async () => {
      most = Math.max(most, ++running);
      await new Promise(resolve => setTimeout(resolve, 20));
      running--;
      return { output: [{ type: 'text', text: 'ok' }] };
    } })] });
  const provider = scriptedProvider([message([call('fx_slow', {}), call('fx_slow', {}), call('fx_slow', {})], { stopReason: 'toolUse' }), message('done')]);
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { ...provider, extensions: [slow],
    authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const submitted = await runtime.submit(id, { ...scope, requestId: 'go', content: 'go' });
  const settled = await (await runtime.harness.submission(submitted.id, ctx)).wait({ ...ctx, abortSignal: AbortSignal.timeout(10000) });
  assert.equal(settled.status, 'done');
  assert.equal(most, 1, 'never two tool calls at once');
});
