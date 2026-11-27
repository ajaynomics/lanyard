// Named Claude routes (claude-routes.mjs): two made-up lenders on real Unix
// sockets, each lending another account's token, and Anthropic stood in for
// inside this process, refusing an account at its limit with HTTP 429.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, productionModels } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { subscriptionCustody } from '../claude-subscription.mjs';
import { lendingServer, borrowedCustody, lendPath } from '../subscription-lending.mjs';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { claudeRouteList, resetOf, PROBE_MS } from '../claude-routes.mjs';
import { digest } from '../state.mjs';
import { privateDir } from './processes.mjs';

const SECRET = 'r'.repeat(40);
// A real response's anthropic-ratelimit-unified-* headers (fixtures/anthropic-unified-headers.json).
const { _source, ...REAL } = JSON.parse(readFileSync(new URL('./fixtures/anthropic-unified-headers.json', import.meta.url), 'utf8'));
// The same at a usage limit, as a 429 carries them: the overall status rejected, resetting at
// `reset` (epoch seconds), or with no usable reset when none is given.
const limitedHeaders = reset => ({ ...REAL, 'anthropic-ratelimit-unified-status': 'rejected', 'anthropic-ratelimit-unified-reset': String(reset ?? 0) });
const HOUR = 60 * 60 * 1000;
const scope = { actorId: 'alice', workspaceId: 'one' };
const token = name => `sk-ant-oat01-${name}-padding`;
const accountOf = bearer => /sk-ant-oat01-([a-z0-9@.-]+)-padding/.exec(bearer ?? '')?.[1] ?? 'none';

// A lender per account: its own grant answers with its token, or, signed out
// there, the lender answers 503 subscription_unavailable.
async function lenders(t, names, clock, gone = []) {
  const dir = await privateDir('claude-routes-');
  const state = { signedOut: new Set(), asked: [] };
  const paths = {};
  for (const name of names) {
    paths[name] = join(dir, `${name}.sock`);
    if (gone.includes(name)) continue;
    const custody = {
      async accessToken() { state.asked.push(name); if (state.signedOut.has(name)) throw Error('signed out'); return token(name); },
      async status() { return { expiresAt: new Date(clock.now + 10 * HOUR).toISOString() }; },
      async start() { throw Error('a borrower never asks a lender to sign in'); }
    };
    const lender = lendingServer({ socketPath: paths[name], secret: SECRET, custody, lender: name });
    await lender.listen();
    t.after(() => lender.close());
  }
  return { state, paths };
}

const sse = events => events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('');
const usage = { input_tokens: 3, output_tokens: 1 };
const reply = (model, blocks, stop) => new Response(sse([
  ['message_start', { type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model, content: [], stop_reason: null, usage } }],
  ...blocks.flatMap((block, index) => [
    ['content_block_start', { type: 'content_block_start', index, content_block: block.type === 'text' ? { type: 'text', text: '' } : { ...block, input: {} } }],
    ['content_block_delta', { type: 'content_block_delta', index, delta: block.type === 'text' ? { type: 'text_delta', text: block.text }
      : { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } }],
    ['content_block_stop', { type: 'content_block_stop', index }]]),
  ['message_delta', { type: 'message_delta', delta: { stop_reason: stop }, usage }],
  ['message_stop', { type: 'message_stop' }]
]), { headers: { 'content-type': 'text/event-stream' } });

// Anthropic's Messages endpoint. An account in `limited` is refused with 429,
// with the reset it maps to (epoch seconds) when one is given; one in `fails`
// gets that response instead. A turn's first answer may be a tool call, every
// later one the reply.
function anthropic(t) {
  const seen = { calls: [], limited: new Map(), fails: new Map(), toolFirst: false };
  const passThrough = globalThis.fetch;
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (seen.tokens && url.href === 'https://platform.claude.com/v1/oauth/token') return seen.tokens(JSON.parse(init.body));
    if (!url.href.startsWith('https://api.anthropic.com/v1/messages')) throw new Error(`unexpected request to ${url.href}`);
    const body = JSON.parse(init.body);
    const account = accountOf(new Headers(init.headers ?? input.headers).get('authorization'));
    seen.calls.push(account);
    if (seen.limited.has(account)) {
      const reset = seen.limited.get(account);
      return new Response(JSON.stringify({ type: 'error', error: { type: 'rate_limit_error', message: 'usage limit reached' } }),
        { status: 429, headers: { 'content-type': 'application/json', ...limitedHeaders(reset) } });
    }
    if (seen.fails.has(account)) return seen.fails.get(account)();
    if (seen.toolFirst) {
      seen.toolFirst = false;
      return reply(body.model, [{ type: 'tool_use', id: 'toolu_1', name: 'note', input: { key: 'dentist' } }], 'tool_use');
    }
    return reply(body.model, [{ type: 'text', text: `Answered on ${account}` }], 'end_turn');
  };
  t.after(() => { globalThis.fetch = passThrough; });
  return seen;
}

function definition(claudeRoute) {
  const body = { instructions: 'You are a fixture agent.', model: 'anthropic/claude-sonnet-5-5', thinkingLevel: 'off', capabilities: [],
    tools: [{ name: 'note', description: 'Save a note', parameters: { type: 'object', properties: { key: { type: 'string' } } } }],
    ...(claudeRoute ? { claudeRoute } : {}) };
  return { ...body, digest: digest(body) };
}

async function setup(t, names = ['main', 'spare'], { gone } = {}) {
  const clock = { now: Date.now() };
  const { state, paths } = await lenders(t, names, clock, gone);
  const api = anthropic(t);
  const logged = [];
  t.mock.method(console, 'error', line => { logged.push(String(line)); });
  const cwd = await privateDir('claude-routes-run-');
  const routes = names.map(name => `${name}=${paths[name]}`).join(',');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), limits: { maxRetries: 0, frameIntervalMs: 5 },
    claudeRoutes: { routes, secret: SECRET } }, {
    authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: { saved: true } }),
    frame: async () => {}, now: () => clock.now });
  t.after(() => runtime.close());
  const conversation = async claudeRoute => {
    const { id } = await runtime.create({ ...scope, requestId: `create-${claudeRoute ?? 'default'}-${Math.random()}` });
    let n = 0;
    const run = async (content = 'Remember my dentist') => {
      const submitted = await runtime.submit(id, { ...scope, requestId: `r-${++n}`, content, definition: definition(claudeRoute) });
      const outcome = await (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
      const entries = (await runtime.entries(id, scope)).entries;
      const view = await runtime.snapshot(id, scope);
      return { status: outcome.status, reply: entries.filter(entry => entry.role === 'assistant').at(-1)?.content, failure: view.failure };
    };
    return { id, run };
  };
  const routesView = async () => (await runtime.subscriptions.anthropic.status()).routes;
  return { clock, state, api, logged, runtime, conversation, routesView };
}

test('the setting is an ordered list of named sockets, checked at boot', () => {
  assert.deepEqual(claudeRouteList('main=/srv/lending/main.sock, spare=/srv/lending/spare.sock'),
    [{ name: 'main', socketPath: '/srv/lending/main.sock' }, { name: 'spare', socketPath: '/srv/lending/spare.sock' }]);
  assert.deepEqual(claudeRouteList('owner@example.test=/a.sock'), [{ name: 'owner@example.test', socketPath: '/a.sock' }]);
  assert.deepEqual(claudeRouteList(`${'a'.repeat(31)}.=/a.sock`).map(route => route.name), [`${'a'.repeat(31)}.`]);
  for (const bad of ['', 'main', 'main=relative.sock', 'Main=/a.sock', '1main=/a.sock', '@main=/a.sock', '.main=/a.sock',
    '-main=/a.sock', 'main_two=/a.sock', 'main+two=/a.sock', 'main/two=/a.sock', 'main two=/a.sock',
    `${'a'.repeat(32)}.=/a.sock`, 'main=/a.sock,main=/b.sock'])
    assert.throws(() => claudeRouteList(bad), /claude_routes_invalid/, bad);
  assert.throws(() => productionModels({ claudeRoutes: { routes: 'main=/a.sock', secret: 'short' } }), /claude_lending_invalid/);
  assert.throws(() => productionModels({ claudeRoutes: { routes: 'main=/a.sock', secret: SECRET }, claudeBorrow: { socketPath: '/b.sock', secret: SECRET } }),
    /claude_routes_ambiguous/);
  assert.equal(productionModels({ claudeRoutes: { routes: 'main=/a.sock', secret: SECRET } }).subscriptions.anthropic.borrowed, true);
});

test('a 429\'s reset is read from a real response\'s unified headers: a rejected window\'s own reset, else the overall one, epoch seconds, only ahead', () => {
  const headers = changes => new Headers({ ...REAL, ...changes });
  const before = () => Date.parse('2026-11-17T07:08:00Z');
  const reset5h = Number(REAL['anthropic-ratelimit-unified-5h-reset']) * 1000, reset7d = Number(REAL['anthropic-ratelimit-unified-7d-reset']) * 1000;
  assert.equal(resetOf(headers({}), before), null, 'allowed everywhere: no limit, no reset');
  assert.equal(resetOf(headers({ 'anthropic-ratelimit-unified-status': 'rejected' }), before), Number(REAL['anthropic-ratelimit-unified-reset']) * 1000);
  assert.equal(resetOf(headers({ 'anthropic-ratelimit-unified-status': 'rejected', 'anthropic-ratelimit-unified-7d-status': 'rejected' }), before), reset7d,
    'a rejected window resets at its own time');
  assert.equal(resetOf(headers({ 'anthropic-ratelimit-unified-5h-status': 'rejected', 'anthropic-ratelimit-unified-7d-status': 'rejected' }), before),
    Math.max(reset5h, reset7d), 'both rejected: the later');
  assert.equal(resetOf(headers({ 'anthropic-ratelimit-unified-status': 'rejected' }), () => reset5h + 1000), null, 'a reset already past is no reset');
  assert.equal(resetOf(new Headers({ 'retry-after': '60' }), before), null, 'Retry-After is not read; the extension does not');
});

test('a usage limit mid-turn falls back to the next route, and no reply is lost; the switch is logged and shown', async t => {
  const f = await setup(t);
  f.api.toolFirst = true;
  const person = await f.conversation();
  // The first request (a tool call) goes through on main; main then hits its limit.
  const original = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (...args) => { if (++calls === 2) f.api.limited.set('main', Math.floor((f.clock.now + HOUR) / 1000)); return original(...args); };
  const turn = await person.run();
  assert.equal(turn.status, 'done', JSON.stringify([turn, f.api.calls, f.logged]));
  assert.equal(turn.reply, 'Answered on spare');
  assert.equal(turn.failure, null);
  assert.deepEqual(f.api.calls, ['main', 'main', 'spare']);
  assert.match(f.logged.join('\n'), /Claude route main refused \(HTTP 429\), resets .*; calls go to the next route/);
  assert.doesNotMatch(f.logged.join('\n'), /sk-ant|\.sock/);
  const view = await f.routesView();
  assert.deepEqual(view.map(route => [route.name, route.state, route.fallback]), [['main', 'limited', false], ['spare', 'active', true]]);
  assert.equal(view[0].resetAt, new Date(Math.floor((f.clock.now + HOUR) / 1000) * 1000).toISOString());
  assert.deepEqual(new Set(f.state.asked), new Set(['main', 'spare']), 'only the sockets were asked; no sign-in anywhere');
});

test('calls stay on the fallback until the first route\'s reset time, then go back to it', async t => {
  const f = await setup(t);
  const person = await f.conversation();
  f.api.limited.set('main', Math.floor((f.clock.now + HOUR) / 1000));
  assert.equal((await person.run()).reply, 'Answered on spare');
  assert.deepEqual(f.api.calls, ['main', 'spare']);
  f.clock.now += PROBE_MS / 2;
  assert.equal((await person.run()).reply, 'Answered on spare', 'before the reset, main is not asked');
  assert.deepEqual(f.api.calls, ['main', 'spare', 'spare']);
  f.api.limited.delete('main');
  f.clock.now += HOUR;
  assert.equal((await person.run()).reply, 'Answered on main');
  assert.match(f.logged.join('\n'), /Claude route main's limit reset at .*; calls go to it again/);
  assert.deepEqual((await f.routesView()).map(route => route.state), ['active', 'standby']);
});

test('with no reset time given, a later call probes the first route and goes back once it answers', async t => {
  const f = await setup(t);
  const person = await f.conversation();
  f.api.limited.set('main', null);
  assert.equal((await person.run()).reply, 'Answered on spare');
  assert.equal((await f.routesView())[0].resetAt, null);
  f.clock.now += PROBE_MS - 1000;
  assert.equal((await person.run()).reply, 'Answered on spare');
  // The probe still refused: once more on the fallback, and the next probe later.
  f.clock.now += 2000;
  assert.equal((await person.run()).reply, 'Answered on spare');
  assert.deepEqual(f.api.calls, ['main', 'spare', 'spare', 'main', 'spare']);
  f.api.limited.delete('main');
  f.clock.now += PROBE_MS;
  assert.equal((await person.run()).reply, 'Answered on main');
  assert.match(f.logged.join('\n'), /Claude route main answers again; calls go to it again/);
  assert.equal((await person.run()).reply, 'Answered on main');
});

test('a lender\'s 503 subscription_unavailable falls back the same way, asking nobody to sign in', async t => {
  const f = await setup(t);
  const person = await f.conversation();
  f.state.signedOut.add('main');
  assert.equal((await person.run()).reply, 'Answered on spare');
  assert.deepEqual(f.api.calls, ['spare']);
  assert.match(f.logged.join('\n'), /Claude route main refused \(lender 503 subscription_unavailable\)/);
});

test('only a 429 the call saw, not "429" in an error\'s words, marks a route limited', async t => {
  const f = await setup(t);
  const person = await f.conversation();
  const failing = (status, type, message) => () => new Response(JSON.stringify({ type: 'error', error: { type, message } }),
    { status, headers: { 'content-type': 'application/json' } });
  for (const [status, type] of [[400, 'invalid_request_error'], [500, 'api_error']]) {
    f.api.fails.set('main', failing(status, type, `request 429 of the batch failed (HTTP ${status})`));
    const turn = await person.run();
    assert.notEqual(turn.status, 'done', JSON.stringify(turn));
    assert.deepEqual(f.api.calls, ['main'], `a ${status} is not asked again on the next route`);
    assert.doesNotMatch(f.logged.join('\n'), /refused/);
    assert.deepEqual((await f.routesView()).map(route => route.state), ['active', 'standby'], `a ${status} leaves main in use`);
    f.api.calls.length = 0;
  }
  f.api.fails.delete('main');
  f.api.limited.set('main', null);
  assert.equal((await person.run()).reply, 'Answered on spare', 'a real 429 still falls back');
  assert.deepEqual(f.api.calls, ['main', 'spare']);
  assert.deepEqual((await f.routesView()).map(route => route.state), ['limited', 'active']);
});

test('a failed fallback is told to the person plainly, not left hanging', async t => {
  const f = await setup(t);
  const person = await f.conversation();
  f.api.limited.set('main', null);
  f.api.limited.set('spare', null);
  const limited = await person.run();
  assert.equal(limited.status, 'unanswered');
  assert.deepEqual(limited.failure, { reason: 'rate_limited' });
  assert.deepEqual(f.api.calls, ['main', 'spare'], 'each route once, no more');

  // Every route at its limit: the first is asked once, and the person told.
  assert.deepEqual((await person.run()).failure, { reason: 'rate_limited' });
  assert.deepEqual(f.api.calls, ['main', 'spare', 'main']);

  // Main limited, the spare's lender signed out.
  const other = await setup(t);
  const someone = await other.conversation();
  other.api.limited.set('main', null);
  other.state.signedOut.add('spare');
  const signedOut = await someone.run();
  assert.equal(signedOut.status, 'unanswered');
  assert.deepEqual(signedOut.failure, { reason: 'credential_missing' });
  assert.deepEqual(other.api.calls, ['main'], 'nothing sent without a token, and never on another route\'s');
});

test('one request tries every route in turn: a 429, then a lender\'s 503, then a route that answers', async t => {
  const f = await setup(t, ['main', 'spare', 'third']);
  const person = await f.conversation();
  f.api.limited.set('main', null);
  f.state.signedOut.add('spare');
  const turn = await person.run();
  assert.equal(turn.status, 'done', JSON.stringify([turn, f.api.calls, f.logged]));
  assert.equal(turn.reply, 'Answered on third');
  assert.deepEqual(f.api.calls, ['main', 'third'], 'spare gave no token, so nothing was sent on it');
  assert.deepEqual((await f.routesView()).map(route => route.state), ['limited', 'limited', 'active']);
});

test('one request goes past a lender whose socket is absent: a 429, then no socket at all, then a route that answers', async t => {
  const f = await setup(t, ['main', 'spare', 'third'], { gone: ['spare'] });
  const person = await f.conversation();
  f.api.limited.set('main', null);
  const turn = await person.run();
  assert.equal(turn.status, 'done', JSON.stringify([turn, f.api.calls, f.logged]));
  assert.equal(turn.reply, 'Answered on third');
  assert.deepEqual(f.api.calls, ['main', 'third'], 'nothing was sent without spare\'s token');
  assert.match(f.logged.join('\n'), /Claude route spare refused \(lender socket ENOENT\)/);
  assert.doesNotMatch(f.logged.join('\n'), /\.sock/);
});

test('when every route refuses, the person is told the limit once, and nothing loops', async t => {
  const f = await setup(t, ['main', 'spare', 'third']);
  const person = await f.conversation();
  for (const name of ['main', 'spare', 'third']) f.api.limited.set(name, null);
  const turn = await person.run();
  assert.equal(turn.status, 'unanswered');
  assert.deepEqual(turn.failure, { reason: 'rate_limited' });
  assert.deepEqual(f.api.calls, ['main', 'spare', 'third'], 'each route once');
  assert.deepEqual((await person.run()).failure, { reason: 'rate_limited' });
  assert.deepEqual(f.api.calls, ['main', 'spare', 'third', 'main'], 'all at their limit: the first is asked once');
});

test('a fallback whose socket nobody answers is told plainly too', async t => {
  const f = await setup(t, ['main', 'spare'], { gone: ['spare'] });
  const person = await f.conversation();
  f.api.limited.set('main', null);
  const turn = await person.run();
  assert.equal(turn.status, 'unanswered');
  assert.deepEqual(turn.failure, { reason: 'credential_missing' });
  assert.deepEqual(f.api.calls, ['main']);
});

test('two agents use their own sockets; the exact route label appears in status and logs', async t => {
  const owner = 'owner@example.test';
  const f = await setup(t, ['main', owner]);
  const onMain = await f.conversation('main');
  const onOwner = await f.conversation(owner);
  const unnamed = await f.conversation('elsewhere');
  assert.equal((await onOwner.run()).reply, `Answered on ${owner}`);
  assert.equal((await onMain.run()).reply, 'Answered on main');
  assert.equal((await unnamed.run()).reply, 'Answered on main', 'a route this sidecar has not got leaves the install\'s order');
  assert.deepEqual(f.api.calls, [owner, 'main', 'main']);
  f.api.limited.set(owner, null);
  assert.equal((await onOwner.run()).reply, 'Answered on main');
  assert.deepEqual(f.api.calls, [owner, 'main', 'main', owner, 'main']);
  assert.deepEqual(await f.routesView(), [
    { name: 'main', state: 'active', fallback: false, resetAt: null },
    { name: owner, state: 'limited', fallback: false, resetAt: null }]);
  assert.deepEqual(f.logged.filter(line => line.startsWith('sidecar: Claude route ')),
    [`sidecar: Claude route ${owner} refused (HTTP 429); calls go to the next route`]);
  const output = JSON.stringify([await f.runtime.subscriptions.anthropic.status(), f.logged]);
  assert.doesNotMatch(output, /sk-ant|\.sock/);
  assert.ok(!output.includes(SECRET));
});

// An install that lends its own account and routes its own calls: its own
// sign-in, made before it boots, sealed in its file; a lender of another
// account as `main`; and its own lend socket as a route, `home`. Anthropic's
// token endpoint is stood in for: a sign-in issues `home`'s token, expiring in
// `expiresIn` seconds, and a refresh `homenew`'s, unless refreshes fail.
const VAULT_KEY = 'a'.repeat(64);
const granted = name => new Response(JSON.stringify({ access_token: token(name), refresh_token: `sk-ant-ort01-${name}-padding`,
  expires_in: 36000, token_type: 'Bearer' }), { headers: { 'content-type': 'application/json' } });

async function lendingInstall(t, { order = ['main', 'home'], expiresIn = 36000, server = true } = {}) {
  const clock = { now: Date.now() };
  const { state, paths } = await lenders(t, ['main'], clock);
  const cwd = await privateDir('claude-routes-lend-');
  const file = join(cwd, 'claude-subscription.json');
  const api = anthropic(t);
  const refresh = { count: 0, fails: false };
  api.tokens = async body => {
    if (body.grant_type === 'authorization_code') {
      const response = granted('home');
      return new Response(JSON.stringify({ ...(await response.json()), expires_in: expiresIn }), { headers: { 'content-type': 'application/json' } });
    }
    refresh.count++;
    refresh.refreshed = body.refresh_token;
    await new Promise(resolve => setTimeout(resolve, 50));
    return refresh.fails ? new Response(JSON.stringify({ error: 'server_error' }), { status: 500, headers: { 'content-type': 'application/json' } })
      : granted('homenew');
  };
  const own = subscriptionCustody({ file, vaultKey: VAULT_KEY, environment: 'test' });
  const started = await own.start((await own.status()).version);
  const signInState = new URL(started.data.authorizationUrl).searchParams.get('state');
  await own.finish({ id: started.data.pending.id, code: `c#${signInState}` }, started.data.version);
  t.mock.method(console, 'error', () => {});
  const lendSocket = join(cwd, 'lend.sock');
  paths.home = lendSocket;
  const config = { storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    limits: { maxRetries: 0, frameIntervalMs: 5 },
    claudeSubscription: { file, vaultKey: VAULT_KEY, environment: 'test' },
    claudeLend: { socketPath: lendSocket, secret: SECRET, lender: 'home' },
    claudeRoutes: { routes: order.map(name => `${name}=${paths[name]}`).join(','), secret: SECRET } };
  const dependencies = { authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: { saved: true } }),
    frame: async () => {}, now: () => clock.now };
  // Without the server, nothing listens on the lend socket.
  let runtime;
  if (server) {
    const app = await createServer(config, dependencies);
    t.after(() => app.close());
    assert.deepEqual(app.readiness(), { ready: true });
    await app.listen(0);
    runtime = app.runtime;
  } else {
    runtime = await createRuntime(config, dependencies);
    t.after(() => runtime.close());
  }
  let n = 0;
  const conversation = async () => {
    const { id } = await runtime.create({ ...scope, requestId: `create-${++n}` });
    return async () => {
      const submitted = await runtime.submit(id, { ...scope, requestId: `r-${++n}`, content: 'Remember my dentist', definition: definition() });
      const outcome = await (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
      return { status: outcome.status, reply: (await runtime.entries(id, scope)).entries.filter(entry => entry.role === 'assistant').at(-1)?.content };
    };
  };
  const run = await conversation();
  // Another install borrowing this one's account, asking afresh each time.
  const borrowed = () => borrowedCustody({ socketPath: lendSocket, secret: SECRET }).accessToken();
  const lendAnswer = () => get(lendSocket, lendPath('anthropic'), `Bearer ${SECRET}`);
  return { clock, state, api, run, conversation, borrowed, lendAnswer, refresh, lendSocket };
}

const get = (socketPath, path, authorization) => new Promise((resolve, reject) => {
  http.request({ socketPath, path, headers: { authorization } }, response => {
    let text = ''; response.on('data', chunk => { text += chunk; }); response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(text) }));
  }).on('error', reject).end();
});

test('an install with claude routes still lends its own account, and its own calls go through the routes in order, one being its own lend socket', async t => {
  const f = await lendingInstall(t);
  assert.equal(await f.borrowed(), token('home'), 'the lend socket serves the install\'s own account, not a route\'s');
  assert.equal((await f.run()).reply, 'Answered on main', 'its own calls go to the first route');
  assert.deepEqual(f.state.asked, ['main']);
  f.api.limited.set('main', null);
  assert.equal((await f.run()).reply, 'Answered on home', 'then to its own account, the route named for its lend socket');
  assert.deepEqual(f.api.calls, ['main', 'main', 'home']);
});

test('falling back past the first route, on a 429 or a 503, does not stop the lending', async t => {
  const limited = await lendingInstall(t);
  limited.api.limited.set('main', null);
  assert.equal((await limited.run()).reply, 'Answered on home');
  assert.equal(await limited.borrowed(), token('home'));

  const signedOut = await lendingInstall(t);
  signedOut.state.signedOut.add('main');
  assert.equal((await signedOut.run()).reply, 'Answered on home');
  assert.deepEqual(signedOut.api.calls, ['home']);
  assert.equal(await signedOut.borrowed(), token('home'));
});

test('lending still needs a sign-in of its own, and routes still never go with borrowing', async t => {
  const cwd = await privateDir('claude-routes-refused-');
  const base = { storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    claudeLend: { socketPath: join(cwd, 'lend.sock'), secret: SECRET } };
  const callbacks = { authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) };
  const routesOnly = await createServer({ ...base, claudeRoutes: { routes: `main=${join(cwd, 'main.sock')}`, secret: SECRET } }, callbacks);
  assert.deepEqual(routesOnly.readiness(), { ready: false, reason: 'claude_lending_invalid' }, 'no sign-in of its own to lend');
  await routesOnly.close();
  const borrowing = await createServer({ ...base, claudeSubscription: { file: join(cwd, 'claude-subscription.json'), vaultKey: VAULT_KEY, environment: 'test' },
    claudeRoutes: { routes: `main=${join(cwd, 'main.sock')}`, secret: SECRET }, claudeBorrow: { socketPath: join(cwd, 'other.sock'), secret: SECRET } }, callbacks);
  assert.deepEqual(borrowing.readiness(), { ready: false, reason: 'claude_routes_ambiguous' });
  await borrowing.close();
  assert.throws(() => productionModels({ claudeSubscription: { file: '/x/c.json', vaultKey: VAULT_KEY, environment: 'test' },
    claudeRoutes: { routes: 'main=/a.sock', secret: SECRET }, claudeBorrow: { socketPath: '/b.sock', secret: SECRET } }), /claude_routes_ambiguous/);
});

test('one refresher: lends and the install\'s own calls at the token\'s end share one refresh, and all get the new token', async t => {
  const f = await lendingInstall(t, { order: ['home', 'main'], expiresIn: 120 });
  const runs = await Promise.all([f.conversation(), f.conversation(), f.conversation()]);
  const [lent, answered] = await Promise.all([
    Promise.all(Array.from({ length: 6 }, () => f.borrowed())),
    Promise.all(runs.map(run => run()))]);
  assert.equal(f.refresh.count, 1, 'exactly one refresh');
  assert.equal(f.refresh.refreshed, 'sk-ant-ort01-home-padding');
  assert.deepEqual(new Set(lent), new Set([token('homenew')]));
  assert.deepEqual(answered.map(turn => turn.reply), Array(3).fill('Answered on homenew'));
  assert.deepEqual(new Set(f.api.calls), new Set(['homenew']));
});

test('no loop: a route that is the install\'s own lend socket uses its grant directly, never through that socket', async t => {
  const f = await lendingInstall(t, { order: ['home', 'main'], server: false });
  assert.equal((await f.run()).reply, 'Answered on home', 'answered on its own account with nothing listening on its lend socket');
  assert.deepEqual(f.api.calls, ['home']);
  assert.deepEqual(f.state.asked, [], 'and no other account asked');
});

test('a failed refresh: borrowers get 503, and own calls move to the next route by its socket alone', async t => {
  const f = await lendingInstall(t, { order: ['home', 'main'], expiresIn: 120 });
  f.refresh.fails = true;
  assert.deepEqual(await f.lendAnswer(), { status: 503, body: { error: 'subscription_unavailable', lender: 'home' } });
  assert.equal((await f.run()).reply, 'Answered on main');
  assert.deepEqual(f.api.calls, ['main']);
  assert.deepEqual(f.state.asked, ['main'], 'main was only asked on its socket');
  assert.ok(f.refresh.count >= 1);
  assert.equal(f.refresh.refreshed, 'sk-ant-ort01-home-padding', 'only the install\'s own grant was ever refreshed');
  assert.deepEqual(await f.lendAnswer(), { status: 503, body: { error: 'subscription_unavailable', lender: 'home' } });
});
