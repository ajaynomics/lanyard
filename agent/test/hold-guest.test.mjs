import { test } from 'node:test';
import assert from 'node:assert/strict';
import { X509Certificate } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm } from 'node:fs/promises';
import { Readable } from 'node:stream';
import { createServer, connect } from 'node:net';
import { once } from 'node:events';
import { Decision } from '../guest/hold/decision.mjs';
import { HeldRequest } from '../guest/hold/held-request.mjs';
import { RequestReader } from '../guest/hold/request-reader.mjs';
import { SiteCertificates } from '../guest/hold/site-certificates.mjs';
import { ThrowawayAuthority } from '../guest/hold/throwaway-authority.mjs';
import { allows, decisionKey, LineSocket, signedDecision } from '../guest/hold/wire.mjs';

const site = 'https://example.com';
const held = (body, type = 'application/x-www-form-urlencoded', path = '/submit') =>
  new HeldRequest(site, { method: 'POST', type, body: Buffer.from(body), path }).ticket;

test('held fields preserve form duplicates and numeric JSON but redact names, types, and query secrets', () => {
  const form = held('note=one&note=two&password=not-shown', undefined, '/submit?session_token=hidden');
  assert.deepEqual(form.fields, [['Query: session_token', '[withheld]'], ['note', 'one'], ['note', 'two'], ['password', '[withheld]']]);
  assert.equal(form.path, '/submit');
  const body = '{"number":1.12345678901234567890,"order":{"type":"password","content":"secret"},"a":[false,2]}';
  const json = held(body, 'application/json');
  assert.deepEqual(json.fields, [
    ['number', '1.12345678901234567890'], ['order › type', '[withheld]'], ['order › content', '[withheld]'],
    ['a › 0', 'false'], ['a › 1', '2']
  ]);
  assert.throws(() => held('{"a":{"x":1,"x":2}}', 'application/json'), /duplicate JSON field/);
  assert.throws(() => held('bad=%c0%80'), URIError);
  assert.throws(() => held('bad=%00'), /unreviewable/);
});

test('an allow is bound to the unique request and every digest, not just the visible preview', () => {
  const key = decisionKey('a'.repeat(64));
  const ticket = held('password=first');
  const second = held('password=second');
  assert.deepEqual(ticket.fields, second.fields);
  const allow = signedDecision(key, ticket, 'allow');
  assert(allows(key, ticket, allow));
  assert(!allows(key, second, allow));
  assert(!allows(key, ticket, { ...allow, answer: 'deny' }));
  for (const altered of [{ site: 'https://www.example.com' }, { method: 'PUT' }, { targetDigest: '0'.repeat(64) }, { expiresAt: 1 }])
    assert(!allows(key, ticket, signedDecision(key, { ...ticket, ...altered }, 'allow')));
});

test('concurrent requests keep distinct decisions and deadlines', async () => {
  const key = decisionKey('b'.repeat(64));
  const gate = new Decision(key);
  const listener = createServer(peer => gate.attach(peer));
  listener.listen(0, '127.0.0.1');
  await once(listener, 'listening');
  const socket = connect(listener.address().port, '127.0.0.1');
  const channel = new LineSocket(socket);
  const signal = AbortSignal.timeout(5000);
  try {
    assert.deepEqual(await channel.next(signal), { status: 'ready' });
    const first = held('message=first');
    const second = held('message=second');
    const expired = new HeldRequest(site, { method: 'POST', body: Buffer.alloc(0), path: '/submit' }, { now: 0 }).ticket;
    const ticket = channel.next(signal);
    const a = gate.wait(first, signal), b = gate.wait(second, signal), c = gate.wait(expired, signal);
    assert.deepEqual(await ticket, first);
    const pending = channel.next(signal);
    channel.send(signedDecision(key, first, 'allow'));
    assert(await a);
    assert.deepEqual(await pending, second);
    channel.send(signedDecision(key, second, 'deny'));
    assert.equal(await b, false);
    assert.equal(await c, false);
  } finally {
    channel.close();
    listener.close();
  }
});

test('reader refuses ambiguity, upgrades, other protocols, and unsupported or oversized bodies', async () => {
  const reader = new RequestReader(() => {});
  const authority = { matches: host => host === 'example.com' };
  const fake = (method = 'POST', headers = [], body = '', extra = {}) => Object.assign(Readable.from([Buffer.from(body)]),
    { method, url: '/path?q=original', httpVersion: '1.1', rawHeaders: ['Host', 'example.com', ...headers], complete: true }, extra);
  const type = ['Content-Type', 'application/json; charset=utf-8'];
  const valid = await reader.read(fake('PATCH', [...type, 'Content-Length', '2'], '{}'), authority);
  assert.equal(valid.body.toString(), '{}');
  assert.equal(valid.path, '/path?q=original');
  for (const input of [
    fake('POST', ['Host', 'example.com']), fake('POST', ['Upgrade', 'websocket']),
    fake('POST', ['Transfer-Encoding', 'chunked']), fake('POST', ['Content-Encoding', 'gzip']),
    fake('PUT', ['Content-Type', 'multipart/form-data']), fake('DELETE', ['Content-Length', '65537']),
    fake('GET', ['Content-Length', '2'], '{}'), fake('POST', [...type, 'Content-Length', '8'], '{}'),
    fake('POST', [], '', { httpVersion: '2.0' }), fake('GET', [], '', { url: 'https://example.com/' }),
  ]) await assert.rejects(reader.read(input, authority));
});

test('the boot authority leaves no key file and its memory signs a cached DNS and IP leaf', async () => {
  const dir = await mkdtemp('/dev/shm/hold-unit-');
  try {
    const authority = new ThrowawayAuthority(dir);
    assert.deepEqual(await readdir(dir), ['root.pem']);
    const root = new X509Certificate(await readFile(authority.cert));
    const sites = new SiteCertificates(authority);
    for (const host of ['example.com', '::1']) {
      const leaf = await sites.forSite(host);
      assert.strictEqual(await sites.forSite(host), leaf);
      const cert = new X509Certificate(leaf.cert);
      assert(cert.verify(root.publicKey));
      assert.equal(host === '::1' ? cert.checkIP(host) : cert.checkHost(host), host);
    }
    assert.deepEqual(await readdir(dir), ['root.pem']);
  } finally { await rm(dir, { recursive: true, force: true }); }
});
