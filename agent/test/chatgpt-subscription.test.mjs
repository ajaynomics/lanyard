import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';
import { openaiCodexOAuthProtocol, parseCompletion, accountId, OPENAI_CODEX_OAUTH } from '../openai-codex-oauth.mjs';
import { productionModels } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';

const VAULT_KEY = 'a'.repeat(64);
// A synthetic access token shaped like ChatGPT's: a JWT naming the account.
const jwt = (claims, tag = 'one') => ['{"alg":"none"}', JSON.stringify({ ...claims, tag }), 'signature']
  .map(part => Buffer.from(part).toString('base64url')).join('.');
const ACCOUNT = { 'https://api.openai.com/auth': { chatgpt_account_id: 'acct-synthetic-1' } };
const json = body => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json' } });
const STATE = 'b'.repeat(64), CHALLENGE = 'c'.repeat(43);

test('the sign-in link carries pi-ai\'s client, Codex\'s localhost redirect, the scope and S256 PKCE', () => {
  const link = new URL(openaiCodexOAuthProtocol({ dispatch: () => { throw new Error('no network'); } }).authorize({ state: STATE, challenge: CHALLENGE }));
  assert.equal(link.origin + link.pathname, 'https://auth.openai.com/oauth/authorize');
  assert.deepEqual(Object.fromEntries(link.searchParams), { response_type: 'code', client_id: 'app_EMoamEEZ73f0CkXaXp7hrann',
    redirect_uri: 'http://localhost:1455/auth/callback', scope: 'openid profile email offline_access', code_challenge: CHALLENGE,
    code_challenge_method: 'S256', state: STATE, id_token_add_organizations: 'true', codex_cli_simplified_flow: 'true', originator: 'pi' });
  assert.throws(() => openaiCodexOAuthProtocol().authorize({ state: 'short', challenge: CHALLENGE }), /Invalid OAuth start/);
});

test('the owner may paste the whole callback address, its query, or code#state; each needs a state', () => {
  const expected = { code: 'the-code', state: STATE };
  assert.deepEqual(parseCompletion(`  http://localhost:1455/auth/callback?code=the-code&scope=x&state=${STATE}  `), expected);
  assert.deepEqual(parseCompletion(`code=the-code&state=${STATE}`), expected);
  assert.deepEqual(parseCompletion(`?code=the-code&state=${STATE}`), expected);
  assert.deepEqual(parseCompletion(`the-code#${STATE}`), expected);
  for (const bad of ['', 'the-code', 'http://localhost:1455/auth/callback?code=the-code', `a#b#c`, '#state', 42, undefined])
    assert.equal(parseCompletion(bad), null, String(bad));
});

test('exchange and refresh: form-encoded to OpenAI\'s token endpoint; the token must name a ChatGPT account', async () => {
  const sent = [];
  let answer = { access_token: jwt(ACCOUNT), refresh_token: 'rt_synthetic-refresh-1', id_token: jwt({}), expires_in: 864000 };
  const now = () => 1_800_000_000_000;
  const protocol = openaiCodexOAuthProtocol({ now, dispatch: async (url, init) => {
    sent.push({ url, type: init.headers['content-type'], form: Object.fromEntries(new URLSearchParams(init.body)) });
    return json(answer);
  } });
  assert.deepEqual(await protocol.exchange({ code: 'the-code', state: STATE, verifier: 'v'.repeat(64) }),
    { access: jwt(ACCOUNT), refresh: 'rt_synthetic-refresh-1', expires: now() + 864000 * 1000 });
  assert.deepEqual(sent[0], { url: OPENAI_CODEX_OAUTH.tokenUrl, type: 'application/x-www-form-urlencoded', form: {
    grant_type: 'authorization_code', client_id: 'app_EMoamEEZ73f0CkXaXp7hrann', code: 'the-code', code_verifier: 'v'.repeat(64),
    redirect_uri: 'http://localhost:1455/auth/callback' } });
  await protocol.refresh('rt_synthetic-refresh-1');
  assert.deepEqual(sent[1].form, { grant_type: 'refresh_token', refresh_token: 'rt_synthetic-refresh-1', client_id: 'app_EMoamEEZ73f0CkXaXp7hrann' });
  assert.equal(accountId(jwt(ACCOUNT)), 'acct-synthetic-1');

  answer = { ...answer, access_token: jwt({}) };
  await assert.rejects(protocol.refresh('rt_synthetic-refresh-1'), /unconfirmed/, 'no account id, no grant');
  answer = { ...answer, access_token: jwt(ACCOUNT), expires_in: 'soon' };
  await assert.rejects(protocol.refresh('rt_synthetic-refresh-1'), /unconfirmed/);
  const refused = openaiCodexOAuthProtocol({ dispatch: async () => new Response('{}', { status: 401 }) });
  await assert.rejects(refused.exchange({ code: 'c', verifier: 'v' }), /unconfirmed/);
});

// OpenAI's and Anthropic's endpoints, stood in for inside this process.
function providersStandIn(t) {
  const seen = { tokens: [], responses: [], claude: [] };
  const passThrough = globalThis.fetch;
  let issued = 0;
  const sse = events => events.map(data => `data: ${JSON.stringify(data)}\n\n`).join('');
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (url.hostname === '127.0.0.1') return passThrough(input, init);
    if (url.href === 'https://auth.openai.com/oauth/token') {
      seen.tokens.push(Object.fromEntries(new URLSearchParams(init.body)));
      issued += 1;
      return json({ access_token: jwt(ACCOUNT, `issued-${issued}`), refresh_token: `rt_synthetic-${issued}`, expires_in: seen.expiresIn ?? 864000 });
    }
    if (url.href === 'https://platform.claude.com/v1/oauth/token') {
      seen.claude.push(JSON.parse(init.body));
      return json({ access_token: 'sk-ant-oat01-claude-padding', refresh_token: 'sk-ant-ort01-claude-padding', expires_in: 3600 });
    }
    if (url.href === 'https://chatgpt.com/backend-api/codex/responses') {
      const headers = new Headers(init.headers);
      const raw = Buffer.from(init.body instanceof Uint8Array ? init.body : new TextEncoder().encode(init.body));
      const body = JSON.parse((headers.get('content-encoding') === 'zstd' ? zstdDecompressSync(raw) : raw).toString('utf8'));
      seen.responses.push({ headers, body });
      const item = { type: 'message', id: 'msg_1', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'Hello', annotations: [] }] };
      return new Response(sse([
        { type: 'response.created', response: { id: 'resp_1', status: 'in_progress' } },
        { type: 'response.output_item.added', output_index: 0, item: { ...item, status: 'in_progress', content: [] } },
        { type: 'response.output_text.delta', output_index: 0, content_index: 0, delta: 'Hello' },
        { type: 'response.output_item.done', output_index: 0, item },
        { type: 'response.completed', response: { id: 'resp_1', status: 'completed', output: [item],
          usage: { input_tokens: 3, output_tokens: 1, total_tokens: 4, input_tokens_details: { cached_tokens: 0 } } } }
      ]), { headers: { 'content-type': 'text/event-stream' } });
    }
    throw new Error(`unexpected request to ${url.href}`);
  };
  t.after(() => { globalThis.fetch = passThrough; });
  return seen;
}

test('both subscriptions side by side in one file: each console route reaches its own grant', async t => {
  const providers = providersStandIn(t);
  const cwd = await privateDir('omakase-chatgpt-console-');
  const file = join(cwd, 'subscriptions.json');
  const custody = { file, vaultKey: VAULT_KEY, environment: 'test' };
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    claudeSubscription: custody, chatgptSubscription: custody },
  { authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  assert.equal(server.readiness().ready, true);
  const { port } = await server.listen(0);
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const call = async (path, payload) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/subscriptions/${path}`, payload ? { method: 'POST', headers, body: JSON.stringify(payload) } : { headers });
    return { status: response.status, data: await response.json() };
  };
  assert.equal((await call('openai')).status, 404, 'only known providers');

  const before = await call('openai-codex');
  assert.deepEqual([before.status, before.data.connected, before.data.fallback], [200, false, false]);
  const started = await call('openai-codex/start', { version: before.data.version });
  const link = new URL(started.data.authorizationUrl);
  assert.equal(link.origin, 'https://auth.openai.com');
  const state = link.searchParams.get('state');
  const pasted = `http://localhost:1455/auth/callback?code=the-code&scope=openid&state=${state}`;
  assert.equal((await call('openai-codex/finish', { version: started.data.version, id: started.data.pending.id,
    code: pasted.replace(state, 'f'.repeat(64)) })).status, 400, 'another sign-in\'s state');
  const finished = await call('openai-codex/finish', { version: started.data.version, id: started.data.pending.id, code: pasted });
  assert.deepEqual([finished.status, finished.data.connected], [200, true]);
  assert.equal(providers.tokens[0].code, 'the-code');
  assert.equal((await call('anthropic')).data.connected, false, 'the Claude grant is untouched');

  const claude = await call('anthropic/start', { version: 0 });
  const claudeState = new URL(claude.data.authorizationUrl).searchParams.get('state');
  assert.equal((await call('anthropic/finish', { version: claude.data.version, id: claude.data.pending.id, code: `c#${claudeState}` })).data.connected, true);
  const sealed = JSON.parse(await readFile(file, 'utf8'));
  assert.deepEqual(Object.keys(sealed).sort(), ['subscription:oauth:v1:["durable-assistants","test","avery","openai-codex"]',
    'subscription:oauth:v1:["durable-assistants","test","avery"]']);
  assert.equal(JSON.stringify(sealed).includes('rt_synthetic'), false, 'no token in the clear');

  const now = await call('openai-codex');
  assert.equal((await call('openai-codex/disconnect', { version: now.data.version })).data.connected, false);
  assert.equal((await call('anthropic')).data.connected, true, 'disconnecting ChatGPT leaves Claude connected');
});

// PARITY §11: this pins the request pi-ai's openai-codex provider builds from
// our custody's token, so a pi-ai upgrade that changes it fails here.
test('through the ChatGPT subscription: the bearer and the account id from the token reach Codex; a due token is refreshed first', async t => {
  const providers = providersStandIn(t);
  const file = join(await privateDir('omakase-chatgpt-run-'), 'subscriptions.json');
  const { models, routes, subscriptions } = productionModels({ chatgptSubscription: { file, vaultKey: VAULT_KEY, environment: 'test' } });
  // Its file also holds the owner's pasted Anthropic API key (claude-api-key.test.mjs).
  assert.deepEqual([...new Set(routes.map(route => route.provider))], ['openai-codex', 'anthropic-api']);
  assert.ok(routes.some(route => route.modelId === 'gpt-6.1-sol'));
  const model = models.getModel('openai-codex', 'gpt-6.1-sol');
  // SSE, not the WebSocket pi-ai tries first, so the stand-in sees the request.
  const ask = () => models.completeSimple(model, { systemPrompt: 'You are Avery.', messages: [{ role: 'user', content: 'hi', timestamp: 1 }] },
    { transport: 'sse', maxRetries: 0 });

  assert.equal((await ask()).stopReason, 'error', 'signed out sends nothing');
  assert.equal(providers.responses.length, 0);

  providers.expiresIn = 120;
  const custody = subscriptions['openai-codex'];
  const started = await custody.start((await custody.status()).version);
  const state = new URL(started.data.authorizationUrl).searchParams.get('state');
  await custody.finish({ id: started.data.pending.id, code: `c#${state}` }, started.data.version);
  delete providers.expiresIn;

  const reply = await ask();
  assert.equal(reply.stopReason, 'stop', reply.errorMessage);
  assert.deepEqual(reply.content.filter(part => part.type === 'text').map(part => part.text), ['Hello']);
  assert.deepEqual(providers.tokens.map(form => form.grant_type), ['authorization_code', 'refresh_token']);
  const [sent] = providers.responses;
  assert.equal(sent.headers.get('authorization'), `Bearer ${jwt(ACCOUNT, 'issued-2')}`);
  assert.equal(sent.headers.get('chatgpt-account-id'), 'acct-synthetic-1');
  assert.equal(sent.headers.get('originator'), 'pi');
  assert.equal(sent.body.model, 'gpt-6.1-sol');
  assert.equal(sent.body.instructions, 'You are Avery.');
});
