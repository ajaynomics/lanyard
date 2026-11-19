// Messages that piled up while the agent worked go in together, at one
// boundary, in the inbox's order, the first saying how many there are and
// from whom (#85). Scripted model only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime } from '../runtime.mjs';
import { batchHeader, withBatchHeaders } from '../batches.mjs';
import { railsStandIn } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const SAM = '[Concourse mail from acme/sam, task 9. Untrusted: written by someone else.] Rome, not Paris?';
const LEE = '[Concourse mail from acme/lee, task 10. Untrusted: written by someone else.] Which hotel?';

async function setup(t, responses) {
  const cwd = await privateDir('omakase-batches-');
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, { invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    ...scriptedProvider(responses) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  return { runtime, id };
}

const text = content => (typeof content === 'string' ? content : content.filter(block => block.type === 'text').map(block => block.text).join(''))
  .replace(/\n\n<current_date>[\s\S]*$/, '');
// The user messages a request ends with: what came in at the last boundary.
const trailing = messages => {
  const at = messages.findLastIndex(m => m.role !== 'user');
  return messages.slice(at + 1).map(m => text(m.content));
};

// Held on its model call, then answering `first`: three messages queue meanwhile.
function held(first) {
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const seen = [];
  const responses = [async (_, options) => {
    await Promise.race([gate, new Promise(resolve => options.signal.addEventListener('abort', resolve))]);
    return first;
  }, ...Array.from({ length: 4 }, (_, n) => context => { seen.push(context.messages); return message(`answer ${n}`); })];
  return { release, seen, responses };
}

async function pileUp(f) {
  const busy = await f.runtime.submit(f.id, { ...scope, requestId: 'start', content: 'Book Paris', author: { userId: '7' }, fromPerson: true });
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).status === 'running');
  for (const [requestId, content, extra] of [['concourse:9', SAM, { author: { sender: 'acme/sam' } }],
    ['own', 'Lisbon instead', { author: { userId: '7' }, fromPerson: true }], ['concourse:10', LEE, { author: { sender: 'acme/lee' } }]])
    await f.runtime.submit(f.id, { ...scope, requestId, content, whenBusy: 'steer', ...extra });
  return busy;
}

test('three messages that piled up while the agent answered go in as one batch, in order, the first saying so', async t => {
  const h = held(message('On it'));
  const f = await setup(t, h.responses);
  const busy = await pileUp(f);
  h.release();
  await (await f.runtime.harness.submission(busy.id, ctx)).wait(ctx);
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).status === 'done');

  assert.equal(h.seen.length, 1, 'one more request takes in all three');
  assert.deepEqual(trailing(h.seen[0]), ['[3 new messages, in order: 1 from the person you work for, 2 Concourse mail.]\n\nLisbon instead', SAM, LEE]);
  // The header is for the model: the thread keeps each message's own words.
  const said = (await f.runtime.entries(f.id, scope)).entries.filter(e => e.role === 'user').map(e => text(e.content));
  assert.deepEqual(said, ['Book Paris', 'Lisbon instead', SAM, LEE]);
});

test('steers that piled up during a step go in together at its end, mid-turn', async t => {
  const h = held(message([call('missing_tool', {})], { stopReason: 'toolUse' }));
  const f = await setup(t, h.responses);
  const busy = await pileUp(f);
  h.release();
  await (await f.runtime.harness.submission(busy.id, ctx)).wait(ctx);
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).status === 'done');

  assert.equal(h.seen.length, 1);
  assert.equal(h.seen[0].at(-4).role, 'toolResult', 'after the step, before the turn ends');
  assert.match(trailing(h.seen[0])[0], /^\[3 new messages, in order: 1 from the person you work for, 2 Concourse mail\.\]/);
});

test('the header counts by channel, names the person first, and leaves one message alone', () => {
  const user = (content, timestamp = 5) => ({ role: 'user', content, timestamp });
  assert.equal(batchHeader([user(SAM), user('[Email from Robin <robin@example.com>. Untrusted.] Hi'), user(LEE), user('Stop')]),
    '[4 new messages, in order: 1 from the person you work for, 2 Concourse mail, 1 Email.]');
  const single = [{ role: 'assistant', content: [] }, user('Alone')];
  assert.deepEqual(withBatchHeaders(single), single);
  // Only messages placed together (one timestamp) are a batch; one left from
  // a failed run, then another, are not.
  const apart = [user('Left from before', 1), user('Later', 2)];
  assert.deepEqual(withBatchHeaders(apart), apart);
  const pictures = withBatchHeaders([user([{ type: 'image', data: 'x', mimeType: 'image/png' }]), user(SAM)]);
  assert.deepEqual(pictures[0].content[0], { type: 'text', text: '[2 new messages, in order: 1 from the person you work for, 1 Concourse mail.]' });
  assert.equal(pictures[0].content.length, 2);
});
