// A paused agent (#52): Rails answers the access check with no, and the sidecar
// already asks it before every tool call and model request. Scripted model
// and local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { obj } from '@earendil-works/pi-schema';
import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { createRuntime } from '../runtime.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const toolUse = name => message(call(name, {}), { stopReason: 'toolUse' });

async function setup(t, responses) {
  const cwd = await privateDir('omakase-pause-');
  const state = { paused: false, ran: [] };
  const tools = defineExtension({ name: 'fixture.pause', tools: ['fx_one', 'fx_two'].map(name => defineTool({ name, description: name,
    parameters: obj({}), replay: 'safe', execute: async () => { state.ran.push(name); return { output: [{ type: 'text', text: 'ok' }] }; } })) });
  const provider = scriptedProvider(responses);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { ...provider,
    // As Rails answers for a paused agent (Sidecar::AccessesController).
    authorize: async requested => state.paused ? { allowed: false, paused: true } : { ...requested, allowed: true, cwd }, invoke: async () => ({ status: 'done', result: {} }),
    extensions: [tools] });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  return { runtime, id, provider, state };
}

test('paused mid-turn, the call running ends, and no further call or model request is made', async t => {
  let f;
  f = await setup(t, [
    () => toolUse('fx_one'),
    // Paused while the model answers: its call is never run, and nothing is asked of the model again.
    () => { f.state.paused = true; return toolUse('fx_two'); },
    () => message('never')]);
  const sent = await f.runtime.submit(f.id, { ...scope, requestId: 'go', content: 'go' });
  await (await f.runtime.harness.submission(sent.id, ctx)).wait(ctx);

  assert.deepEqual(f.state.ran, ['fx_one']);
  assert.equal(f.provider.faux.state.callCount, 2);
  const snapshot = await f.runtime.snapshot(f.id, scope);
  assert.notEqual(snapshot.status, 'running');
  // Rails reads this end as idle, not an error; the model is told why its call was blocked.
  assert.equal(snapshot.failure?.reason, 'paused_by_owner');
  const blocked = (await f.runtime.entries(f.id, scope)).entries.find(e => e.role === 'toolResult' && e.toolName === 'fx_two');
  assert.match(blocked.content, /Tool call blocked: paused_by_owner/);
});

test('a message taken back is never read again under its own id; under a new one it is read once', async t => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const f = await setup(t, [async () => { await gate; return message('first'); }, message('second'), message('never')]);
  await f.runtime.submit(f.id, { ...scope, requestId: 'first', content: 'first' });
  await eventually(() => f.provider.faux.state.callCount === 1);
  const held = await f.runtime.submit(f.id, { ...scope, requestId: 'mail', content: 'mail' });
  assert.deepEqual(await f.runtime.withdrawQueued(f.id, { ...scope, id: String(held.id) }), { withdrawn: true });
  release();
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).status === 'done');

  const again = await f.runtime.submit(f.id, { ...scope, requestId: 'mail', content: 'mail' });
  assert.equal(again.id, held.id);
  assert.equal(again.status, 'unanswered', 'the same id is the withdrawn message, and nothing new is admitted');
  const renewed = await f.runtime.submit(f.id, { ...scope, requestId: 'mail:held', content: 'mail' });
  await (await f.runtime.harness.submission(renewed.id, ctx)).wait(ctx);
  const said = (await f.runtime.entries(f.id, scope)).entries.filter(e => e.role === 'user').map(e => e.content.replace(/\n\n<current_date>[\s\S]*$/, ''));
  assert.deepEqual(said, ['first', 'mail']);
  assert.equal(f.provider.faux.state.callCount, 2);
});
