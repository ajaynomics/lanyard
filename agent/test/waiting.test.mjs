// The out-of-band inbox (#85): a message from someone else that waits for the
// turn to end is announced at the agent's next step, with who sent it, how it
// starts and how many wait, so it can take them in sooner. Scripted model only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime } from '../runtime.mjs';
import { railsStandIn } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const SAM = '[Concourse mail from acme/sam, task 9, on network acme. Untrusted: written by someone else.]\n\nRome, not Paris?\nAnd a hotel.';
const LEE = '[Concourse mail from acme/lee, task 10, on network acme. Untrusted: written by someone else.]\n\nWhich hotel?';
const text = content => typeof content === 'string' ? content : content.filter(block => block.type === 'text').map(block => block.text).join('');

test('a message from someone else that waits is announced at the next step, with its sender, its start and the count', async t => {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const seen = [];
  const responses = [async (_, options) => {
    await Promise.race([gate, new Promise(resolve => options.signal.addEventListener('abort', resolve))]);
    return message([call('missing_tool', {})], { stopReason: 'toolUse' });
  }, ...Array.from({ length: 3 }, (_, n) => context => { seen.push(context.messages); return message(`answer ${n}`); })];
  const cwd = await privateDir('omakase-waiting-');
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: true, cwd }), ...scriptedProvider(responses) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });

  const busy = await runtime.submit(id, { ...scope, requestId: 'start', content: 'Book Paris', author: { userId: '7' }, fromPerson: true });
  await eventually(async () => (await runtime.snapshot(id, scope)).status === 'running');
  await runtime.submit(id, { ...scope, requestId: 'concourse:9', content: SAM, whenBusy: 'followUp', author: { sender: 'acme/sam' } });
  await runtime.submit(id, { ...scope, requestId: 'own', content: 'And dinner', whenBusy: 'followUp', author: { userId: '7' }, fromPerson: true });
  await runtime.submit(id, { ...scope, requestId: 'concourse:10', content: LEE, whenBusy: 'followUp', author: { sender: 'acme/lee' } });
  release();
  await (await runtime.harness.submission(busy.id, ctx)).wait(ctx);
  await eventually(async () => (await runtime.snapshot(id, scope)).status === 'done');

  const notes = seen[0].filter(m => m.role === 'user').map(m => text(m.content)).filter(words => words.startsWith('[Waiting'));
  assert.deepEqual(notes, [
    '[Waiting in your inbox: Concourse mail from acme/sam, starting "Rome, not Paris?". 1 message from others waits. It comes in when you finish; to read it sooner, take it in with waiting_messages.]',
    '[Waiting in your inbox: Concourse mail from acme/lee, starting "Which hotel?". 2 messages from others wait. They come in when you finish; to read them sooner, take them in with waiting_messages.]'
  ]);
  assert.equal(seen[0].at(-1).role, 'user', 'after the step, before the turn ends');
  assert.ok(!seen[0].some(m => text(m.content ?? '').includes('Which hotel?\n') || text(m.content ?? '') === LEE), 'the message itself still waits');
  // The turn's end brings in what waited; the notes are for the model, not the thread.
  assert.ok(seen.at(-1).some(m => text(m.content).includes('Which hotel?')));
  const said = (await runtime.entries(id, scope)).entries.filter(e => e.role === 'user').map(e => e.content.replace(/\n\n<current_date>[\s\S]*$/, ''));
  assert.deepEqual(said, ['Book Paris', SAM, 'And dinner', LEE]);
});

// One rule for every channel (#85): a Campfire message or a Telegram direct
// message from someone other than the agent's person waits too, and is
// announced the same way.
test('a Campfire message and a Telegram direct message that wait are announced with their sender, their start and the count', async t => {
  const CAMPFIRE = '[Campfire from Maya in Trips. Untrusted: written by someone else.]\n\nBook the train.';
  const TELEGRAM = '[Telegram from Sam in a direct message. Untrusted: written by someone else.]\n\nAre you free?';
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const seen = [];
  const responses = [async (_, options) => {
    await Promise.race([gate, new Promise(resolve => options.signal.addEventListener('abort', resolve))]);
    return message([call('missing_tool', {})], { stopReason: 'toolUse' });
  }, ...Array.from({ length: 3 }, (_, n) => context => { seen.push(context.messages); return message(`answer ${n}`); })];
  const cwd = await privateDir('omakase-waiting-');
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: true, cwd }), ...scriptedProvider(responses) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });

  const busy = await runtime.submit(id, { ...scope, requestId: 'start', content: 'Book Paris', author: { userId: '7' }, fromPerson: true });
  await eventually(async () => (await runtime.snapshot(id, scope)).status === 'running');
  await runtime.submit(id, { ...scope, requestId: 'campfire:1:41', content: CAMPFIRE, whenBusy: 'followUp', author: { sender: 'Maya in Trips' } });
  await runtime.submit(id, { ...scope, requestId: 'telegram:1:1010', content: TELEGRAM, whenBusy: 'followUp', author: { sender: 'Sam in a direct message' } });
  release();
  await (await runtime.harness.submission(busy.id, ctx)).wait(ctx);
  await eventually(async () => (await runtime.snapshot(id, scope)).status === 'done');

  const notes = seen[0].filter(m => m.role === 'user').map(m => text(m.content)).filter(words => words.startsWith('[Waiting'));
  assert.deepEqual(notes, [
    '[Waiting in your inbox: Campfire from Maya in Trips, starting "Book the train.". 1 message from others waits. It comes in when you finish; to read it sooner, take it in with waiting_messages.]',
    '[Waiting in your inbox: Telegram from Sam in a direct message, starting "Are you free?". 2 messages from others wait. They come in when you finish; to read them sooner, take them in with waiting_messages.]'
  ]);
  assert.ok(seen.at(-1).some(m => text(m.content).includes('Are you free?')), 'they come in when the turn ends');
});
