import assert from 'node:assert/strict';
import { once } from 'node:events';
import { connect, createServer } from 'node:net';
import { test } from 'node:test';
import { createServer as httpServer } from 'node:http';
import { HeldPosts } from '../held-posts.mjs';
import { allows, decisionKey, LineSocket } from '../guest/hold/wire.mjs';

const secret = '3'.repeat(64);
const scope = { actorId: '1', workspaceId: '2', conversationId: '3' };
const sample = () => ({ id: '4'.repeat(48), site: 'https://example.com', method: 'POST', path: '/form',
  targetDigest: '5'.repeat(64), digest: '6'.repeat(64), expiresAt: Date.now() + 3000, fields: [['note', 'synthetic']] });

async function fixture(t, approval, listen) {
  const server = createServer();
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => server.close());
  const joined = once(server, 'connection');
  const guest = connect(server.address().port, '127.0.0.1');
  const process = listen ? listen(guest) : new HeldPosts({ scope, relaySecret: secret, approval, recheckMs: 10 }).listen(guest);
  t.after(async () => { guest.destroy(); await process; });
  const [socket] = await joined;
  const [data] = await once(socket, 'data');
  assert(data.toString() === `AGENT-HOLD ${secret}\n`);
  const relay = new LineSocket(socket);
  relay.send({ status: 'ready' });
  await new Promise(resolve => setTimeout(resolve, 20));
  t.after(() => relay.close());
  return relay;
}

test('sidecar opens one card, waits, and signs the exact answer', async t => {
  const calls = [];
  const ticket = sample();
  const relay = await fixture(t, async ({ operation, ...request }) => {
    calls.push(operation);
    assert.deepEqual(request, { ...scope, held_post: ticket });
    return { status: calls.length < 3 ? 'waiting' : 'allow' };
  });
  const pending = relay.next();
  relay.send(ticket);
  const answer = await pending;
  assert(allows(decisionKey(secret), ticket, answer));
  assert.deepEqual(calls, ['open', 'answer', 'answer']);
});

test('an approval error denies without retrying a possibly consumed answer', async t => {
  const calls = [];
  const ticket = sample();
  const relay = await fixture(t, async ({ operation }) => {
    calls.push(operation);
    // As slow as a loaded CI runner: the deny comes after the old 1 s read limit.
    if (operation === 'answer') { await new Promise(resolve => setTimeout(resolve, 1200)); throw new Error('reply lost'); }
    return { status: 'waiting' };
  });
  // The relay's line or its close ends the wait, never a timer of the test's.
  const pending = relay.next();
  relay.send(ticket);
  const answer = await pending;
  assert.equal(answer.answer, 'deny');
  assert(!allows(decisionKey(secret), ticket, answer));
  assert.deepEqual(calls, ['open', 'answer', 'cancel']);
});

test('losing the relay aborts the outstanding Rails request and cancels the card', async t => {
  let answering, cancelled;
  const reached = new Promise(resolve => { answering = resolve; });
  const closed = new Promise(resolve => { cancelled = resolve; });
  const relay = await fixture(t, async ({ operation }, signal) => {
    if (operation === 'cancel') { cancelled(); return { status: 'deny' }; }
    if (operation === 'open') return { status: 'waiting' };
    answering();
    await once(signal, 'abort');
    return { status: 'allow' };
  });
  relay.send(sample());
  await reached;
  relay.close();
  await closed;
});

test('explicit sidecar proof session uses the authenticated Rails callback', async t => {
  const { listenForHeldPosts } = await import('../server.mjs');
  const token = 'synthetic-rails-callback-token';
  const ticket = sample(), calls = [];
  const rails = httpServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    calls.push({ path: request.url, method: request.method, authorization: request.headers.authorization,
      body: JSON.parse(Buffer.concat(chunks)) });
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ status: calls.length === 1 ? 'waiting' : 'allow' }));
  });
  rails.listen(0, '127.0.0.1');
  await once(rails, 'listening');
  t.after(() => { rails.closeAllConnections(); rails.close(); });
  const relay = await fixture(t, null, socket => listenForHeldPosts(
    { railsUrl: `http://127.0.0.1:${rails.address().port}`, railsToken: token },
    { socket, scope, relaySecret: secret }));
  const waiting = relay.next(AbortSignal.timeout(2000));
  relay.send(ticket);
  assert(allows(decisionKey(secret), ticket, await waiting));
  assert.deepEqual(calls, ['open', 'answer'].map(operation => ({ path: '/agent/held_posts', method: 'POST',
    authorization: `Bearer ${token}`, body: { ...scope, held_post: ticket, operation } })));
});
