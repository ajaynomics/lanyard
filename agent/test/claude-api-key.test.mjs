// Claude through a pasted Anthropic API key (claude-api-key.mjs): the owner
// console's routes, custody beside the subscriptions' grants, and the request
// pi-ai builds for the key. Every key here is made up; Anthropic is stood in
// for inside the process.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { validApiKey, apiKeyCustody, API_KEY_PROVIDER } from '../claude-api-key.mjs';
import { anthropicOAuthProtocol } from '../anthropic-oauth.mjs';
import { SubscriptionCredentials, fileStorage } from '../subscription-credentials.mjs';
import { productionModels, failureReason } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';

const VAULT_KEY = 'a'.repeat(64);
const KEY = 'sk-ant-usr01-made-up-for-tests-only-wxyz';
const OTHER_KEY = 'sk-ant-api03-also-made-up-for-tests-9876';

test('any sk-ant- key but a subscription token, printable, no whitespace, bounded', () => {
  for (const good of [KEY, OTHER_KEY, `sk-ant-${'x'.repeat(505)}`]) assert.equal(validApiKey(good), true, good.slice(0, 16));
  for (const bad of [undefined, 42, '', 'sk-ant-short', `sk-ant-${'x'.repeat(506)}`, 'sk-ant-oat01-made-up-subscription-token',
    'sk-ant-ort01-made-up-refresh-token-0000', 'sk-proj-made-up-openai-key-000000', `${KEY} `, 'sk-ant-usr01-made up-with-space',
    'sk-ant-usr01-made-up-é-not-ascii-0000']) assert.equal(validApiKey(bad), false, String(bad));
});

// Anthropic's two endpoints the key touches: the free model list (verdict
// settable per test) and Messages, which records what it was sent.
function anthropicStandIn(t) {
  const seen = { checks: [], messages: [], verdict: 200 };
  const passThrough = globalThis.fetch;
  const sse = events => events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('');
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (url.hostname === '127.0.0.1') return passThrough(input, init);
    if (url.href === 'https://api.anthropic.com/v1/models') {
      seen.checks.push({ method: init.method, headers: new Headers(init.headers) });
      if (seen.verdict === 'offline') throw new TypeError('fetch failed');
      return new Response(JSON.stringify(seen.verdict === 200 ? { data: [] } : { type: 'error' }), { status: seen.verdict });
    }
    if (url.href.startsWith('https://api.anthropic.com/v1/messages')) {
      const body = JSON.parse(init.body ?? (await input.text?.()) ?? '{}');
      seen.messages.push({ headers: new Headers(init.headers ?? input.headers), body });
      const usage = { input_tokens: 3, output_tokens: 1 };
      return new Response(sse([
        ['message_start', { type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: body.model, content: [], stop_reason: null, usage } }],
        ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
        ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Hello' } }],
        ['content_block_stop', { type: 'content_block_stop', index: 0 }],
        ['message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn' }, usage }],
        ['message_stop', { type: 'message_stop' }]
      ]), { headers: { 'content-type': 'text/event-stream' } });
    }
    throw new Error(`unexpected request to ${url.href}`);
  };
  t.after(() => { globalThis.fetch = passThrough; });
  return seen;
}

test('the console\'s key routes: checked with Anthropic before it is kept, sealed beside the grants, shown only as a hint, removed by version', async t => {
  const anthropic = anthropicStandIn(t);
  const cwd = await privateDir('omakase-api-key-console-');
  const file = join(cwd, 'claude-subscription.json');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    claudeSubscription: { file, vaultKey: VAULT_KEY, environment: 'test' } },
  { authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  assert.deepEqual(server.readiness(), { ready: true }, 'no key is not a reason to be unready');
  const { port } = await server.listen(0);
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const call = async (method, path, payload) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/subscriptions/anthropic-api${path}`,
      { method, headers, ...(payload ? { body: JSON.stringify(payload) } : {}) });
    return { status: response.status, data: await response.json() };
  };
  const sealed = async () => JSON.parse(await readFile(file, 'utf8').catch(() => '{}'));

  assert.equal((await fetch(`http://127.0.0.1:${port}/v1/subscriptions/anthropic-api`)).status, 401);
  assert.deepEqual(await call('GET', ''), { status: 200, data: { configured: true, connected: false, version: 0, hint: null } });
  assert.equal((await call('POST', '/key', { version: 0, key: KEY })).status, 404, 'set with PUT, remove with DELETE');

  const models = await (await fetch(`http://127.0.0.1:${port}/v1/models`, { headers })).json();
  assert.ok(models.models.some(model => model.id === 'anthropic-api/claude-opus-5-5'), 'offered before a key is set');
  assert.ok(models.models.some(model => model.id === 'anthropic/claude-opus-5-5'), 'beside the subscription');

  assert.deepEqual(await call('PUT', '/key', { version: 0, key: 'sk-ant-oat01-made-up-subscription-token' }),
    { status: 422, data: { error: 'invalid_api_key' } });
  assert.equal(anthropic.checks.length, 0, 'a key of the wrong shape never reaches Anthropic');

  anthropic.verdict = 401;
  assert.deepEqual(await call('PUT', '/key', { version: 0, key: KEY }), { status: 422, data: { error: 'invalid_api_key' } });
  anthropic.verdict = 'offline';
  assert.deepEqual(await call('PUT', '/key', { version: 0, key: KEY }), { status: 503, data: { error: 'api_key_unverified' } });
  anthropic.verdict = 500;
  assert.deepEqual(await call('PUT', '/key', { version: 0, key: KEY }), { status: 503, data: { error: 'api_key_unverified' } });
  assert.deepEqual(await sealed(), {}, 'a refused or unchecked key is not kept');
  const [check] = anthropic.checks;
  assert.equal(check.method, 'GET');
  assert.equal(check.headers.get('x-api-key'), KEY);
  assert.equal(check.headers.get('anthropic-version'), '2023-06-01');
  assert.equal(check.headers.get('authorization'), null);

  anthropic.verdict = 200;
  const stale = await call('PUT', '/key', { version: 3, key: KEY });
  assert.deepEqual([stale.status, stale.data.error], [412, 'subscription_changed']);
  const saved = await call('PUT', '/key', { version: 0, key: KEY });
  assert.deepEqual(saved, { status: 200, data: { configured: true, connected: true, version: 1, hint: 'wxyz' } });
  assert.deepEqual(await call('GET', ''), saved);
  const raw = await readFile(file, 'utf8');
  assert.equal(raw.includes('sk-ant-'), false, 'never in the clear');
  assert.deepEqual(Object.keys(JSON.parse(raw)), ['api-key:v1:["durable-assistants","test","durable-assistants","anthropic-api"]']);
  const subscription = await fetch(`http://127.0.0.1:${port}/v1/subscriptions/anthropic`, { headers });
  assert.equal((await subscription.json()).connected, false, 'the Claude subscription is a separate thing');
  const elsewhere = apiKeyCustody({ file, vaultKey: VAULT_KEY, environment: 'production' });
  assert.equal((await elsewhere.status()).connected, false, 'another environment never sees this key');
  const otherInstall = apiKeyCustody({ file, vaultKey: VAULT_KEY, environment: 'test', application: 'another-install' });
  assert.equal((await otherInstall.status()).connected, false, 'another install never sees this key');
  await assert.rejects(apiKeyCustody({ file, vaultKey: 'b'.repeat(64), environment: 'test' }).status(), /custody unavailable/);

  assert.equal((await call('DELETE', '/key', { version: 0 })).status, 412);
  assert.deepEqual(await call('DELETE', '/key', { version: 1 }), { status: 200, data: { configured: true, connected: false, version: 2, hint: null } });
  await assert.rejects(apiKeyCustody({ file, vaultKey: VAULT_KEY, environment: 'test' }).key(), /not set/);
});

test('a server with no subscription file has no place for a key', async t => {
  const cwd = await privateDir('omakase-api-key-none-');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    openaiApiKey: 'synthetic-openai-key' },
  { authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const response = await fetch(`http://127.0.0.1:${port}/v1/subscriptions/anthropic-api`, { headers: { authorization: 'Bearer synthetic-sidecar-token-123' } });
  assert.deepEqual([response.status, await response.json()], [404, { error: 'subscription_not_configured' }]);
});

// Sealed by the custody before the API key joined it, with the synthetic
// vault key 'a' * 64 (claude-subscription.test.mjs has the same record).
const SEALED_BEFORE = { 'subscription:oauth:v1:["acme-assistants","test","acme"]': { format: 1, iv: 'se9MH0MO96fqub0r',
  ciphertext: 'XlLIW5xEsMyXKso2X+6Uywvljy830omfi7zUUU7Jin9QtZbvzluX2ZHNtRXLenpdFHKCuNdqY177bPIo9J10NqgQ12dUZt1OG3mq8T2BSwAr1H5ZXDuuIW0HJTBVApSJf0+eMCYZQlf4QrYvMR1LanXnIPWRQ8GKNH5nsiWuVvBcut21uJEiZ4n1j+KjkYPIfoRYcQVpEsTLoxcPjEXqyeSutBWiGTvFtLuYTat4wf/hDITCw7bmgFWFg9mVjxWNtvdTYtnUC9G3D9dGPg2aIg==' } };

test('a key saved into the file of an existing Claude grant leaves that grant opening as before', async () => {
  const file = join(await privateDir('omakase-api-key-sealed-'), 'claude-subscription.json');
  await writeFile(file, JSON.stringify(SEALED_BEFORE), { mode: 0o600 });
  const keys = apiKeyCustody({ file, vaultKey: VAULT_KEY, environment: 'test', verify: async () => 'ok' });
  assert.equal((await keys.save(KEY, 0)).status, 200);
  const now = () => Date.UTC(2026, 10, 7);
  const grant = new SubscriptionCredentials({ storage: fileStorage(file), vaultKey: VAULT_KEY, enabled: true, now,
    protocol: anthropicOAuthProtocol({ dispatch: async () => { throw new Error('no network'); }, now }),
    scope: { application: 'acme-assistants', environment: 'test', principal: 'acme' } });
  assert.equal(await grant.accessToken(), 'sk-ant-oat01-sealed-before-padding');
  assert.equal(await keys.key(), KEY);
  const sealed = JSON.parse(await readFile(file, 'utf8'));
  assert.deepEqual(sealed['subscription:oauth:v1:["acme-assistants","test","acme"]'], SEALED_BEFORE['subscription:oauth:v1:["acme-assistants","test","acme"]']);
});

// Pins the request pi-ai builds for a pasted key, so an upgrade that starts
// treating it as a subscription token fails here.
test('through the key: x-api-key, pi\'s own identity, no Claude Code betas or billing block; no key sends nothing', async t => {
  const anthropic = anthropicStandIn(t);
  const file = join(await privateDir('omakase-api-key-run-'), 'claude-subscription.json');
  const { models, routes, apiKeys } = productionModels({ claudeSubscription: { file, vaultKey: VAULT_KEY, environment: 'test' } });
  assert.deepEqual([...new Set(routes.map(route => route.provider))], ['anthropic', API_KEY_PROVIDER]);
  const model = models.getModel(API_KEY_PROVIDER, 'claude-sonnet-5-5');
  assert.equal(model.provider, API_KEY_PROVIDER, 'never resolves to the subscription\'s provider');
  const ask = () => models.completeSimple(model, { systemPrompt: 'You are an assistant.', messages: [{ role: 'user', content: 'Remember that my dentist is on Tuesday', timestamp: 1 }] });

  const unset = await ask();
  assert.equal(unset.stopReason, 'error');
  assert.equal(anthropic.messages.length, 0);
  assert.equal(unset.errorMessage, 'Provider is not configured: anthropic-api', 'what failureReason reads as credential_missing');

  assert.equal((await apiKeys[API_KEY_PROVIDER].save(KEY, 0)).status, 200);
  const reply = await ask();
  assert.equal(reply.stopReason, 'stop', reply.errorMessage);
  assert.equal(reply.provider, API_KEY_PROVIDER);
  const [sent] = anthropic.messages;
  assert.equal(sent.headers.get('x-api-key'), KEY);
  assert.equal(sent.headers.get('authorization'), null);
  assert.equal(sent.headers.get('x-app'), null);
  assert.doesNotMatch(sent.headers.get('user-agent') ?? '', /claude-cli/);
  assert.doesNotMatch(sent.headers.get('anthropic-beta') ?? '', /claude-code|oauth/);
  assert.deepEqual(sent.body.system.map(block => block.text), ['You are an assistant.']);
  assert.equal(JSON.stringify(sent.body).includes('x-anthropic-billing-header'), false);
});

test('a run without the key stops as credential_missing, so the page can say where to set it', () => {
  assert.equal(failureReason({ reason: 'model_error', detail: 'Provider is not configured: anthropic-api' }), 'credential_missing');
  assert.equal(failureReason({ reason: 'model_error', detail: 'Provider is not configured: anthropic' }), 'credential_missing');
  assert.equal(failureReason({ reason: 'model_error', detail: 'overloaded' }), 'model_error');
});
