import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { connect, createServer } from 'node:net';
import { connect as connectTLS } from 'node:tls';
import { Decision } from '../guest/hold/decision.mjs';
import { fromPage, HeldRequest } from '../guest/hold/held-request.mjs';
import { RequestReader, refuse } from '../guest/hold/request-reader.mjs';
import { SiteCertificates } from '../guest/hold/site-certificates.mjs';
import { ThrowawayAuthority } from '../guest/hold/throwaway-authority.mjs';
import { Tunnel } from '../guest/hold/tunnel.mjs';
import { decisionKey, LineSocket, MUTATIONS, signedDecision } from '../guest/hold/wire.mjs';
import { WebSocketServer } from 'ws';
import { devtools, proofControl } from './hold-proof-check.mjs';

const host = '127.0.0.1';
const form = 'note=synthetic+hello&password=do-not-show';
const json = '{"note": "synthetic hello", "password": "do-not-show"}';
const until = async ready => { while (!ready()) await new Promise(resolve => setTimeout(resolve, 10)); };
const digest = value => createHash('sha256').update(value).digest('hex');

async function fixture(t) {
  const dir = await mkdtemp('/dev/shm/hold-sequence-');
  t.after(() => rm(dir, { recursive: true, force: true }));
  const authority = new ThrowawayAuthority(dir);
  const ca = await readFile(authority.cert);
  const key = decisionKey('synthetic relay secret');
  const decision = new Decision(key);
  const relay = createServer(socket => decision.attach(socket));
  const upstream = [];
  const tunnel = new Tunnel(new SiteCertificates(authority), new RequestReader(async (request, response, site, signal) => {
    if (MUTATIONS.has(request.method) && !fromPage(request.headers)) return void refuse(response, 'browser write not from a page');
    if (MUTATIONS.has(request.method) && !await decision.wait(new HeldRequest(site.site, request).ticket, signal)) {
      if (!response.destroyed) refuse(response);
      return;
    }
    upstream.push([request.method, request.body.toString()]);
    response.writeHead(200, { connection: 'close' }).end('ok');
  }));
  const sockets = new Set();
  function track(socket) {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
    socket.on('error', () => {});
    return socket;
  }
  t.after(async () => {
    for (const socket of sockets) socket.destroy();
    await Promise.all([tunnel.server, relay].map(server => new Promise(resolve => server.close(resolve))));
  });
  tunnel.listen(0);
  relay.listen(0, host);
  await Promise.all([once(tunnel.server, 'listening'), once(relay, 'listening')]);
  const control = new LineSocket(track(connect(relay.address().port, host)));
  assert.deepEqual(await control.next(AbortSignal.timeout(6000)), { status: 'ready' });

  async function open(options, hostname = host) {
    const raw = track(connect(tunnel.server.address().port, host));
    raw.write(`CONNECT ${hostname}:443 HTTP/1.1\r\nHost: ${hostname}:443\r\n\r\n`);
    const [ready] = await Promise.race([once(raw, 'data'), once(raw, 'close').then(() => { throw new Error('CONNECT closed'); })]);
    assert.match(ready.toString(), /^HTTP\/1\.1 200 /);
    const socket = track(connectTLS({ socket: raw, host: hostname, ca, ALPNProtocols: ['http/1.1'], ...options }));
    await once(socket, 'secureConnect');
    return socket;
  }
  async function request(method, body, type, hostname = host, from = 'same-origin') {
    const socket = await open(undefined, hostname);
    const chunks = [];
    socket.on('data', chunk => chunks.push(chunk));
    const response = once(socket, 'close');
    const content = body === undefined ? '' : `Content-Type: ${type}\r\nContent-Length: ${Buffer.byteLength(body)}\r\n`;
    socket.write(`${method} /submit HTTP/1.1\r\nHost: ${hostname}\r\nConnection: keep-alive\r\nSec-Fetch-Site: ${from}\r\n${content}\r\n${body ?? ''}`);
    await response;
    return Number(/^HTTP\/1\.1 (\d+) /.exec(Buffer.concat(chunks).toString())?.[1]);
  }
  return { control, request, open, upstream, sign: (ticket, answer = 'allow') => signedDecision(key, ticket, answer) };
}

// The Sprite proof failed at altered method (#286): Chromium's own write to
// update.googleapis.com, which it sends every minute, reached the relay
// between two stages, while the check was not reading.
test('a browser write to another site between stages is denied, and the proof still gets every ticket', { timeout: 15000 }, async t => {
  const { control: channel, request, open, upstream, sign } = await fixture(t);
  const control = proofControl(channel, sign);
  t.mock.method(console, 'log', () => {});
  for (const version of ['TLSv1.2', 'TLSv1.3']) {
    const options = { minVersion: version, maxVersion: version };
    const fallback = await open({ ...options, ALPNProtocols: ['h2', 'http/1.1'] });
    assert.equal(fallback.alpnProtocol, 'http/1.1');
    fallback.destroy();
    await assert.rejects(open({ ...options, ALPNProtocols: ['h2'] }), { code: 'ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL' });
  }
  const read = async () => assert.equal(await request('GET'), 200);
  const urlencoded = 'application/x-www-form-urlencoded';
  async function write(name, reply, status, method = 'POST', body = form, type = urlencoded) {
    const before = upstream.length;
    const arriving = control.next(AbortSignal.timeout(6000));
    const result = request(method, body, type);
    void result.catch(() => {});
    const ticket = await arriving;
    if (!ticket) {
      const closed = control.closeReason ?? (channel.socket.destroyed ? 'closed' : 'open');
      assert.fail(`${name}: no ${method} ticket (response=${await result}, control=${closed})`);
    }
    assert.equal(ticket.method, method);
    assert.equal(ticket.digest, digest(body));
    assert.equal(upstream.length, before, `${name}: not forwarded while pending`);
    const answer = reply(ticket);
    control.send(answer);
    assert.equal(await result, status, name);
    assert.equal(upstream.length, before + Number(status === 200), `${name}: upstream writes`);
    if (status === 200) assert.deepEqual(upstream.at(-1), [method, body]);
    return answer;
  }

  await read();
  const replay = await write('native form', sign, 200);
  for (const method of ['PUT', 'PATCH', 'DELETE']) {
    await read();
    await write(method, sign, 200, method, json, 'application/json');
  }
  const allowed = upstream.length;
  for (const [body, type] of [
    ['unknown content', 'text/plain;charset=UTF-8'],
    ['note=' + 'a'.repeat(65536), urlencoded],
    ['--sample--\r\n', 'multipart/form-data; boundary=sample'],
  ]) assert.equal(await request('POST', body, type), 403);
  assert.equal(upstream.length, allowed);

  for (const [name, reply] of [
    ['deny', ticket => sign(ticket, 'deny')],
    ['forged', ticket => ({ ...sign(ticket), mac: '0'.repeat(64) })],
    ['reused', () => replay],
    ['altered site', ticket => sign({ ...ticket, site: 'https://example.com' })],
    ['altered path', ticket => sign({ ...ticket, targetDigest: digest('/other') })],
    ['altered body', ticket => sign({ ...ticket, digest: digest('other') })],
    ['altered method', ticket => sign({ ...ticket, method: 'PUT' })],
  ]) {
    let background;
    if (name === 'altered method') {
      // It reaches the relay while the check waits on nothing.
      background = request('POST', '{"request":{}}', 'application/json', 'localhost');
      await until(() => console.log.mock.calls.length || channel.socket.destroyed);
    }
    await write(name, reply, 403);
    if (background) {
      assert.equal(await background, 403, 'the write to another site was denied');
      assert.deepEqual(console.log.mock.calls.map(call => call.arguments), [['NOTE: denied a browser write to another site, which the check did not make']]);
    }
  }
});

test('the proof can distinguish its own missing-ticket deadline from relay closure', { timeout: 5000 }, async t => {
  const errors = t.mock.method(console, 'error', () => {});
  const { control, request, sign } = await fixture(t);
  const ticket = control.next(AbortSignal.timeout(3000));
  const response = request('POST', form, 'application/x-www-form-urlencoded');
  const held = await ticket;
  assert(held);
  control.send(sign({ ...held, digest: digest('other') }));
  assert.equal(await response, 403);
  assert.equal(control.socket.destroyed, false, 'the rejected answer did not close the channel');

  // No browser write arrives. The proof itself times out and closes its end.
  const deadline = new AbortController();
  const missing = control.next(deadline.signal);
  deadline.abort(new DOMException('synthetic deadline', 'TimeoutError'));
  assert.equal(await missing, null);
  assert.equal(control.socket.destroyed, true);
  assert.equal(control.closeReason, 'read deadline');
  await once(control.socket, 'close');
  assert.deepEqual(errors.mock.calls[0]?.arguments, ['browser hold: refused: no valid allow']);
});

test('bad control frames close the hold channel and log only fixed reasons', { timeout: 5000 }, async t => {
  const errors = t.mock.method(console, 'error', () => {});
  const { control, request, upstream } = await fixture(t);
  const ticket = control.next(AbortSignal.timeout(3000));
  const response = request('POST', form, 'application/x-www-form-urlencoded');
  assert(await ticket);
  const closed = once(control.socket, 'close');
  control.socket.write('{"password":"synthetic-response-secret"}\n{}\n');
  await closed;
  assert.equal(await response, 403);
  assert.deepEqual(upstream, []);
  assert.deepEqual(errors.mock.calls.map(call => call.arguments), [
    ['browser hold: control closed: extra bytes after frame'],
    ['browser hold: refused: control unavailable'],
  ]);
});

// Chromium checks on its on-device model every minute from no page (#286).
test("the browser's own write, from no page, is refused without asking anyone", { timeout: 5000 }, async t => {
  const errors = t.mock.method(console, 'error', () => {});
  const { control, request, upstream } = await fixture(t);
  const ticket = control.next(AbortSignal.timeout(1000));
  assert.equal(await request('POST', '{"request":{}}', 'application/json', 'localhost', 'none'), 403);
  assert.equal(await ticket, null, 'no ticket reached the relay');
  assert.deepEqual(upstream, []);
  assert.deepEqual(errors.mock.calls[0]?.arguments, ['browser hold: refused: browser write not from a page']);
});

// A page's DevTools: it answers each command at once, but hands each
// Runtime.evaluate to the test to answer, late or never.
async function fakeDevtools(t) {
  const server = new WebSocketServer({ host, port: 0 });
  t.after(() => new Promise(resolve => {
    for (const socket of server.clients) socket.terminate();
    server.close(resolve);
  }));
  await once(server, 'listening');
  const evaluations = [];
  let arrived = () => {};
  server.on('connection', socket => socket.on('message', data => {
    const { id, method } = JSON.parse(data);
    if (method !== 'Runtime.evaluate') return socket.send(JSON.stringify({ id, result: {} }));
    evaluations.push({ socket, id });
    arrived();
  }));
  const evaluation = () => evaluations.shift() ?? new Promise(resolve => { arrived = () => resolve(evaluations.shift()); });
  return { address: `ws://${host}:${server.address().port}`, evaluation };
}

test('the proof waits for a slow DevTools answer, as a loaded runner gives one', { timeout: 15000 }, async t => {
  const fake = await fakeDevtools(t);
  const page = await devtools(fake.address);
  t.after(() => page.close());
  const value = page.evalPage('window.holdResult');
  const { socket, id } = await fake.evaluation();
  // Runs 10319 and 10326: one poll in the timeout stage's 90 seconds came
  // back after the proof had stopped waiting for it.
  await new Promise(resolve => setTimeout(resolve, 6000));
  socket.send(JSON.stringify({ id, result: { result: { value: 403 } } }));
  assert.equal(await value, 403);
});

test('the proof stops waiting on DevTools when it closes or the page crashes', { timeout: 5000 }, async t => {
  const fake = await fakeDevtools(t);
  const closing = await devtools(fake.address);
  const unanswered = closing.evalPage('window.holdResult');
  (await fake.evaluation()).socket.terminate();
  await assert.rejects(unanswered, /DevTools closed: Runtime.evaluate/);
  await assert.rejects(closing.evalPage('1'), /DevTools closed: Runtime.evaluate/);

  const crashing = await devtools(fake.address);
  t.after(() => crashing.close());
  const pending = crashing.evalPage('window.holdResult');
  (await fake.evaluation()).socket.send(JSON.stringify({ method: 'Inspector.targetCrashed', params: {} }));
  await assert.rejects(pending, /DevTools: Inspector.targetCrashed: Runtime.evaluate/);
});
