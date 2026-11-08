import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { billingHeader, shapePayload, subscriptionCustody, CLAUDE_CODE_VERSION } from '../claude-subscription.mjs';
import { anthropicOAuthProtocol } from '../anthropic-oauth.mjs';
import { SubscriptionCredentials, fileStorage } from '../subscription-credentials.mjs';
import { productionModels } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';

const VAULT_KEY = 'a'.repeat(64);

test('the billing block follows the pi-anthropic-auth recipe (vectors from an earlier copy of it)', () => {
  assert.equal(billingHeader('Remember that my dentist is on Tuesday'),
    'x-anthropic-billing-header: cc_version=2.1.280.9dc; cc_entrypoint=sdk-cli; cch=96f4b;');
  assert.equal(billingHeader('hi'), 'x-anthropic-billing-header: cc_version=2.1.280.d7b; cc_entrypoint=sdk-cli; cch=8f434;');
  assert.equal(billingHeader(''), undefined);
});

test('the block goes first in the system prompt, once, from the first user text', () => {
  const payload = { model: 'm', stream: true, system: [{ type: 'text', text: 'You are Claude Code.' }],
    messages: [{ role: 'user', content: [{ type: 'image' }, { type: 'text', text: 'hi' }] }, { role: 'user', content: 'later' }] };
  const shaped = shapePayload(payload);
  assert.deepEqual(shaped.system.map(block => block.text), [billingHeader('hi'), 'You are Claude Code.']);
  assert.equal(shapePayload(shaped), shaped, 'already shaped');
  assert.deepEqual(shapePayload({ ...payload, messages: [] }), { ...payload, messages: [] }, 'no user text, no block');
});

test('a subscription and an API key for Claude are never both configured, and the custody settings are checked', () => {
  const good = { file: '/x/c.json', vaultKey: VAULT_KEY, environment: 'staging' };
  assert.throws(() => productionModels({ claudeSubscription: good, anthropicApiKey: 'k' }), /anthropic_credential_ambiguous/);
  for (const bad of [{ ...good, file: 'c.json' }, { ...good, vaultKey: 'short' }, { ...good, environment: '' }])
    assert.throws(() => productionModels({ claudeSubscription: bad }), /claude_subscription_invalid/);
  // A different provider's key is not ambiguous.
  assert.deepEqual(productionModels({ claudeSubscription: good, openaiApiKey: 'k' }).models.getProviders().map(p => p.id), ['openai', 'anthropic', 'anthropic-api']);
});

// Sealed in the format the custody used before the ChatGPT grant joined it,
// with the synthetic vault key 'a' * 64: a deploy must still open it.
const SEALED_BEFORE = { 'subscription:oauth:v1:["acme-assistants","test","acme"]': { format: 1, iv: 'se9MH0MO96fqub0r',
  ciphertext: 'XlLIW5xEsMyXKso2X+6Uywvljy830omfi7zUUU7Jin9QtZbvzluX2ZHNtRXLenpdFHKCuNdqY177bPIo9J10NqgQ12dUZt1OG3mq8T2BSwAr1H5ZXDuuIW0HJTBVApSJf0+eMCYZQlf4QrYvMR1LanXnIPWRQ8GKNH5nsiWuVvBcut21uJEiZ4n1j+KjkYPIfoRYcQVpEsTLoxcPjEXqyeSutBWiGTvFtLuYTat4wf/hDITCw7bmgFWFg9mVjxWNtvdTYtnUC9G3D9dGPg2aIg==' } };

test('a Claude grant sealed before the ChatGPT subscription existed still opens', async () => {
  const file = join(await privateDir('omakase-claude-sealed-'), 'claude-subscription.json');
  await writeFile(file, JSON.stringify(SEALED_BEFORE), { mode: 0o600 });
  const now = () => Date.UTC(2026, 10, 7);
  const custody = new SubscriptionCredentials({ storage: fileStorage(file), vaultKey: VAULT_KEY, enabled: true, now,
    protocol: anthropicOAuthProtocol({ dispatch: async () => { throw new Error('no network'); }, now }),
    scope: { application: 'acme-assistants', environment: 'test', principal: 'acme' } });
  assert.equal((await custody.status()).connected, true);
  assert.equal(await custody.accessToken(), 'sk-ant-oat01-sealed-before-padding');
});

// Anthropic's two endpoints, stood in for inside this process (loopback still
// goes through): the token endpoint answers an exchange or a refresh with a
// new token pair; the Messages endpoint records what it was sent and streams a
// one-word reply.
function anthropicStandIn(t) {
  const seen = { tokens: [], messages: [] };
  const passThrough = globalThis.fetch;
  let issued = 0;
  const sse = events => events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('');
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (url.hostname === '127.0.0.1') return passThrough(input, init);
    const body = JSON.parse(init.body ?? (await input.text?.()) ?? '{}');
    if (url.href === 'https://platform.claude.com/v1/oauth/token') {
      seen.tokens.push(body);
      issued += 1;
      return new Response(JSON.stringify({ access_token: `sk-ant-oat01-issued-${issued}-padding`, refresh_token: `sk-ant-ort01-issued-${issued}-padding`,
        expires_in: seen.expiresIn ?? 3600, token_type: 'Bearer' }), { headers: { 'content-type': 'application/json' } });
    }
    if (url.href.startsWith('https://api.anthropic.com/v1/messages')) {
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

test('the owner console\'s routes: status, a fresh sign-in link, completion with code#state, a grant sealed on disk, disconnect', async t => {
  const anthropic = anthropicStandIn(t);
  const cwd = await privateDir('omakase-claude-console-');
  const file = join(cwd, 'claude-subscription.json');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    claudeSubscription: { file, vaultKey: VAULT_KEY, environment: 'test' } },
  { authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const call = async (path, payload) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/subscriptions/anthropic${path}`, payload ? { method: 'POST', headers, body: JSON.stringify(payload) } : { headers });
    return { status: response.status, data: await response.json() };
  };

  assert.equal((await fetch(`http://127.0.0.1:${port}/v1/subscriptions/anthropic`)).status, 401);
  const chatgpt = await fetch(`http://127.0.0.1:${port}/v1/subscriptions/openai-codex`, { headers });
  assert.deepEqual([chatgpt.status, await chatgpt.json()], [404, { error: 'subscription_not_configured' }]);
  const before = await call('');
  assert.equal(before.status, 200);
  assert.equal(before.data.connected, false);
  assert.equal(before.data.fallback, false);

  assert.equal((await call('/start', { version: before.data.version + 7 })).status, 412, 'a stale version changes nothing');
  const started = await call('/start', { version: before.data.version });
  assert.equal(started.status, 200);
  const link = new URL(started.data.authorizationUrl);
  assert.equal(link.origin + link.pathname, 'https://claude.ai/oauth/authorize');
  assert.equal(link.searchParams.get('code_challenge_method'), 'S256');
  const state = link.searchParams.get('state');
  assert.equal((await call('')).data.authorizationUrl, undefined, 'status never repeats the link');

  const wrong = await call('/finish', { version: started.data.version, id: started.data.pending.id, code: 'the-code#not-the-state' });
  assert.equal(wrong.status, 400);
  const finished = await call('/finish', { version: started.data.version, id: started.data.pending.id, code: `the-code#${state}` });
  assert.equal(finished.status, 200);
  assert.equal(finished.data.connected, true);
  assert.equal(anthropic.tokens[0].grant_type, 'authorization_code');
  assert.equal(anthropic.tokens[0].code, 'the-code');
  assert.match(anthropic.tokens[0].code_verifier, /^[a-f0-9]{64}$/);

  const sealed = await readFile(file, 'utf8');
  assert.equal(sealed.includes('sk-ant-'), false, 'no token in the clear');
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  const otherKey = subscriptionCustody({ file, vaultKey: 'b'.repeat(64), environment: 'test' });
  await assert.rejects(otherKey.status(), /custody unavailable/);
  const otherEnvironment = subscriptionCustody({ file, vaultKey: VAULT_KEY, environment: 'production' });
  assert.equal((await otherEnvironment.status()).connected, false, 'another environment never sees this grant');

  const gone = await call('/disconnect', { version: finished.data.version });
  assert.equal(gone.status, 200);
  assert.equal(gone.data.connected, false);
  assert.equal(gone.data.providerRevoked, false);
});

// PARITY §11: this pins the request pi-ai builds for an sk-ant-oat token, so
// a pi-ai upgrade that changes Claude Code's identity fails here.
test('through the subscription: the request carries the bearer, Claude Code\'s identity and the billing block; a due token is refreshed and kept; signed out sends nothing', async t => {
  const anthropic = anthropicStandIn(t);
  const file = join(await privateDir('omakase-claude-run-'), 'claude-subscription.json');
  const { models, routes, subscriptions: { anthropic: subscription } } = productionModels({ claudeSubscription: { file, vaultKey: VAULT_KEY, environment: 'test' } });
  // Beside it, the pasted API key's own provider (claude-api-key.test.mjs).
  assert.deepEqual([...new Set(routes.map(route => route.provider))], ['anthropic', 'anthropic-api']);
  assert.ok(routes.some(route => route.modelId === 'claude-sonnet-5-5'));
  const model = models.getModel('anthropic', 'claude-sonnet-5-5');
  const ask = () => models.completeSimple(model, { systemPrompt: 'You are an assistant.', messages: [{ role: 'user', content: 'Remember that my dentist is on Tuesday', timestamp: 1 }] });

  const signedOut = await ask();
  assert.equal(signedOut.stopReason, 'error');
  assert.equal(anthropic.messages.length, 0);

  // Connected with a token that is already due for refresh (expires within five minutes).
  anthropic.expiresIn = 120;
  const started = await subscription.start((await subscription.status()).version);
  const state = new URL(started.data.authorizationUrl).searchParams.get('state');
  await subscription.finish({ id: started.data.pending.id, code: `c#${state}` }, started.data.version);
  delete anthropic.expiresIn;

  const reply = await ask();
  assert.equal(reply.stopReason, 'stop', reply.errorMessage);
  assert.deepEqual(reply.content.map(part => part.text), ['Hello']);
  assert.deepEqual(anthropic.tokens.map(body => body.grant_type), ['authorization_code', 'refresh_token']);
  assert.equal(anthropic.tokens[1].refresh_token, 'sk-ant-ort01-issued-1-padding');
  const [sent] = anthropic.messages;
  assert.equal(sent.headers.get('authorization'), 'Bearer sk-ant-oat01-issued-2-padding');
  assert.equal(sent.headers.get('x-api-key'), null);
  assert.equal(sent.headers.get('user-agent'), `claude-cli/${CLAUDE_CODE_VERSION}`);
  assert.equal(sent.headers.get('x-app'), 'cli');
  const betas = sent.headers.get('anthropic-beta').split(',').map(beta => beta.trim());
  assert.ok(betas.includes('claude-code-20250219') && betas.includes('oauth-2025-04-20'), betas.join(','));
  assert.deepEqual(sent.body.system.map(block => block.text), [
    billingHeader('Remember that my dentist is on Tuesday'),
    "You are Claude Code, Anthropic's official CLI for Claude.",
    'You are an assistant.'
  ]);

  // The rotated pair was kept: the next request needs no refresh.
  await ask();
  assert.equal(anthropic.tokens.length, 2);
  assert.equal(anthropic.messages[1].headers.get('authorization'), 'Bearer sk-ant-oat01-issued-2-padding');
});
