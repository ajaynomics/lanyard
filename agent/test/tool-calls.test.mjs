import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { fauxAssistantMessage, fauxProvider, fauxToolCall } from '@earendil-works/pi-ai/providers/faux';
import { createRegistry, defineExtension, defineTool, Harness } from '@earendil-works/pi-durable';
import { MemoryStorage } from '@earendil-works/pi-durable/storage/memory';
import { obj } from '@earendil-works/pi-schema';
import { createRuntime, stalledRun, TOOL_EXECUTION } from '../runtime.mjs';
import { apply, PATCHES } from '../patches.mjs';
import { desktop } from '../desktop.mjs';
import { visitWebsite } from '../browser.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

// Seeded, so a failing run can be replayed.
const random = seed => { let s = seed >>> 0 || 1; return () => { s ^= s << 13; s ^= s >>> 17; s ^= s << 5; return (s >>> 0) / 2 ** 32; }; };
const hop = () => new Promise(resolve => setImmediate(resolve));
// Each draw: no delay, a few microtasks, one or two event-loop hops, or both.
const delayer = next => async () => {
  const kind = Math.floor(next() * 4);
  for (let i = 0; i < (kind & 1 ? 1 + Math.floor(next() * 3) : 0); i++) await Promise.resolve();
  for (let i = 0; i < (kind & 2 ? 1 + Math.floor(next() * 2) : 0); i++) await hop();
};

// earendil-works/pi#11892's reproduction, shuffled: a round of parallel tool
// calls, with delays after tool bodies and after store commits. Unpatched,
// some runs never wake the generation once every call has ended.
async function run({ seed, calls, tool = 't' }) {
  const next = random(seed);
  const toolDelay = delayer(next), commitDelay = delayer(next);
  let running = 0, most = 0, order;
  const execute = async () => {
    most = Math.max(most, ++running);
    await toolDelay(); await toolDelay();
    running--;
    return { output: [{ type: 'text', text: 'ok' }] };
  };
  const ext = defineExtension({ name: 'x', tools: [defineTool({ name: 't', description: 't', parameters: obj({}), execute }),
    defineTool({ name: 's', description: 's', parameters: obj({}), executionMode: 'sequential', execute })] });
  const ids = Array.from({ length: calls }, (_, i) => `call_${seed}_${i}`);
  const faux = fauxProvider({ provider: 'faux', models: [{ id: 'm' }], tokenSize: { min: 1000, max: 1000 } });
  faux.setResponses([fauxAssistantMessage(ids.map(id => fauxToolCall(tool, {}, { id })), { stopReason: 'toolUse' }),
    context => { order = context.messages.filter(m => m.role === 'toolResult').map(m => m.toolCallId); return fauxAssistantMessage('done'); }]);
  const models = createModels();
  models.setProvider(faux.provider);
  const registry = createRegistry();
  registry.install(ext);
  const memory = new MemoryStorage();
  const storage = new Proxy(memory, { get(target, prop) {
    const value = Reflect.get(target, prop, target);
    if (prop === 'commit') return async (...args) => { const result = await value.apply(target, args); await commitDelay(); return result; };
    return typeof value === 'function' ? value.bind(target) : value;
  } });
  const harness = await Harness.open(storage, { models, registry, settings: { toolExecution: TOOL_EXECUTION } }, ctx);
  try {
    const conversation = await harness.createConversation({ ownership: { kind: 'ownerless' },
      agent: { model: { provider: 'faux', modelId: 'm' }, extensions: [ext] } }, ctx);
    const submission = await conversation.submit({ type: 'input', content: 'go' }, ctx);
    // A timer that holds the event loop open: a hung harness leaves nothing else pending.
    const timer = new AbortController();
    const timeout = setTimeout(() => timer.abort(), 1000);
    const settled = await submission.wait({ ...ctx, abortSignal: timer.signal }).then(() => true, () => false);
    clearTimeout(timeout);
    return { settled, order, ids, most };
  } finally {
    await harness.close(ctx).catch(() => {});
  }
}

test('the pi-durable patch is applied to the installed package, and fails the install when its code has moved', async () => {
  const dir = await privateDir('omakase-patches-');
  for (const patch of PATCHES) {
    const installed = readFileSync(join(import.meta.dirname, '..', patch.file), 'utf8');
    assert.ok(installed.includes(patch.after), `${patch.name}: run node patches.mjs after npm ci`);
    const copy = { ...patch, file: 'copy.js' };
    writeFileSync(join(dir, 'copy.js'), installed.replace(patch.after, patch.before));
    assert.equal(apply(copy, dir), 'applied');
    assert.equal(apply(copy, dir), 'present', 'applied once');
    writeFileSync(join(dir, 'copy.js'), 'export {};');
    assert.equal(apply(copy, dir), 'missing', 'an upgrade that moved the code stops the build');
  }
});

test('400 shuffled rounds of parallel tool calls all end, with results in the order the model made the calls (pi#11892)', async () => {
  assert.equal(TOOL_EXECUTION, 'parallel', "pi's default");
  const hung = [];
  let overlapped = 0;
  for (let seed = 1; seed <= 400; seed++) {
    const result = await run({ seed, calls: 2 + (seed % 4) });
    if (!result.settled) { hung.push(seed); continue; }
    assert.deepEqual(result.order, result.ids, `seed ${seed}: source order`);
    if (result.most > 1) overlapped++;
  }
  assert.deepEqual(hung, [], 'no round hangs');
  assert.ok(overlapped > 200, `calls really ran at once (${overlapped}/400)`);
});

// The other half of pi#11892: a tool that starts a helper (a child
// conversation its task owns, as subagent.mjs does) and returns before the
// helper's turn ends holds as `completing`. Unpatched, the helper's end can
// be erased from the finalize pass's checks, and the parent turn never ends.
async function helperRun(seed) {
  const next = random(seed);
  const toolDelay = delayer(next), commitDelay = delayer(next);
  const ext = defineExtension({ name: 'x', tools: [defineTool({ name: 'spawn', description: 'spawn', parameters: obj({}), execute: async (_args, api, c) => {
    const child = await api.commit(tx => tx.createConversation({ ownership: { kind: 'task', taskId: api.taskId } }).then(x => x.id), c);
    await (await api.conversation(child, c)).submit({ type: 'input', content: 'child' }, c);
    await toolDelay(); await toolDelay();
    return { output: [{ type: 'text', text: 'ok' }] };
  } })] });
  const calls = 1 + (seed % 3);
  const ids = Array.from({ length: calls }, (_, i) => `call_${seed}_${i}`);
  const text = m => typeof m.content === 'string' ? m.content : (m.content ?? []).map(b => b.text ?? '').join('');
  const faux = fauxProvider({ provider: 'faux', models: [{ id: 'm' }], tokenSize: { min: 1000, max: 1000 } });
  faux.setResponses(Array.from({ length: calls + 4 }, () => context => {
    if (text(context.messages.find(m => m.role === 'user') ?? {}) === 'child') return fauxAssistantMessage('child done');
    if (context.messages.some(m => m.role === 'toolResult')) return fauxAssistantMessage('done');
    return fauxAssistantMessage(ids.map(id => fauxToolCall('spawn', {}, { id })), { stopReason: 'toolUse' });
  }));
  const models = createModels();
  models.setProvider(faux.provider);
  const registry = createRegistry();
  registry.install(ext);
  const memory = new MemoryStorage();
  const storage = new Proxy(memory, { get(target, prop) {
    const value = Reflect.get(target, prop, target);
    if (prop === 'commit') return async (...args) => { const result = await value.apply(target, args); await commitDelay(); return result; };
    return typeof value === 'function' ? value.bind(target) : value;
  } });
  const harness = await Harness.open(storage, { models, registry, settings: { toolExecution: TOOL_EXECUTION } }, ctx);
  try {
    const conversation = await harness.createConversation({ ownership: { kind: 'ownerless' },
      agent: { model: { provider: 'faux', modelId: 'm' }, extensions: [ext] } }, ctx);
    const submission = await conversation.submit({ type: 'input', content: 'go' }, ctx);
    const timer = new AbortController();
    const timeout = setTimeout(() => timer.abort(), 1500);
    const settled = await submission.wait({ ...ctx, abortSignal: timer.signal }).then(() => true, () => false);
    clearTimeout(timeout);
    return settled;
  } finally {
    await harness.close(ctx).catch(() => {});
  }
}

test('400 shuffled rounds of tools that start a helper and return before it ends all end (pi#11892, completing)', async () => {
  const hung = [];
  for (let seed = 1; seed <= 400; seed++) if (!(await helperRun(seed))) hung.push(seed);
  assert.deepEqual(hung, [], 'no parent turn left completing');
});

test('a tool that declares sequential runs its round one call at a time; the screen tools do', async () => {
  for (let seed = 1; seed <= 50; seed++) {
    const result = await run({ seed, calls: 3, tool: 's' });
    assert.ok(result.settled, `seed ${seed}`);
    assert.equal(result.most, 1, `seed ${seed}: never two at once`);
  }
  assert.equal(desktop.executionMode, 'sequential');
  assert.equal(visitWebsite.executionMode, 'sequential');
});

test('the sidecar runs a round of tool calls at once, and the turn ends', async t => {
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
  assert.equal(most, 3, 'all three at once');
});

// What a missed wake leaves (a generation `pending` with nothing running) is
// `stalled`; a person's wait runs inside its tool, and a timer sleeps.
test('a run is stalled only when its tasks are there and none runs, sleeps or is blocked', () => {
  assert.equal(stalledRun([{ kind: 'pending' }]), true);
  assert.equal(stalledRun([{ kind: 'waiting', on: ['t1'] }, { kind: 'completing' }]), true, "a helper's task that never finishes");
  assert.equal(stalledRun([{ kind: 'waiting', on: ['t1'] }, { kind: 'running' }]), false);
  assert.equal(stalledRun([{ kind: 'sleeping', until: 1 }]), false);
  assert.equal(stalledRun([{ kind: 'blocked' }]), false, 'blocked is its own status');
  assert.equal(stalledRun([]), false);
});
