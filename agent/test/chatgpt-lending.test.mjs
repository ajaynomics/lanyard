import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { join } from 'node:path';
import { lendingServer, lendPath } from '../subscription-lending.mjs';
import { borrowedChatgptCustody, chatgptSignInToken, BORROWED_CHATGPT_PROVIDER } from '../chatgpt-lending.mjs';
import { productionModels } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';

const SECRET = 's'.repeat(40);
// A synthetic "Sign in with ChatGPT" access token: not an API key's sk-.
const TOKEN = 'synthetic-chatgpt-sign-in-token';
const VAULT = { file: '/x/c.json', vaultKey: 'a'.repeat(64), environment: 'staging' };

function get(socketPath, path, authorization) {
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath, path, headers: authorization ? { authorization } : {} }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
    });
    request.on('error', reject);
    request.end();
  });
}

// A lender of its own grant, stood in for: Pi's lender answers the same way.
async function lend(t, { access = TOKEN, provider = BORROWED_CHATGPT_PROVIDER } = {}) {
  const socketPath = join(await privateDir('chatgpt-lend-'), 'lend.sock');
  const custody = { accessToken: async () => { if (!access) throw new Error('signed out'); return access; },
    status: async () => ({ expiresAt: new Date(Date.now() + 3600_000).toISOString() }) };
  const lender = lendingServer({ socketPath, secret: SECRET, custody, lender: 'pi agents', provider });
  await lender.listen();
  t.after(() => lender.close());
  return socketPath;
}

test('each provider lends on its own route; Claude keeps /v1/lend/anthropic', async t => {
  assert.equal(lendPath('anthropic'), '/v1/lend/anthropic');
  const socketPath = await lend(t);
  assert.deepEqual((await get(socketPath, '/v1/lend/openai-chatgpt', `Bearer ${SECRET}`)).body.access, TOKEN);
  assert.equal((await get(socketPath, '/v1/lend/anthropic', `Bearer ${SECRET}`)).status, 404);
  assert.equal((await get(socketPath, '/v1/lend/openai-chatgpt')).status, 401);
});

test('the borrower asks for its own route, keeps nothing that is an API key, and signs in or out nowhere', async t => {
  assert.equal(chatgptSignInToken(TOKEN), true);
  assert.equal(chatgptSignInToken('sk-synthetic-api-key'), false);
  const borrower = borrowedChatgptCustody({ socketPath: await lend(t), secret: SECRET });
  assert.equal(await borrower.accessToken(), TOKEN);
  assert.deepEqual(await borrower.status().then(({ connected, borrowed, lender }) => ({ connected, borrowed, lender })),
    { connected: true, borrowed: true, lender: 'pi agents' });
  for (const step of ['start', 'finish', 'disconnect']) assert.equal((await borrower[step]()).data.error, 'subscription_borrowed');

  const apiKey = borrowedChatgptCustody({ socketPath: await lend(t, { access: 'sk-synthetic-api-key' }), secret: SECRET });
  await assert.rejects(apiKey.accessToken(), /no fallback/);
  assert.equal((await apiKey.status()).connected, false);
  const claudeOnly = borrowedChatgptCustody({ socketPath: await lend(t, { provider: 'anthropic' }), secret: SECRET });
  assert.equal((await claudeOnly.status()).connected, false, 'a lender of Claude alone lends no ChatGPT');
  const signedOut = borrowedChatgptCustody({ socketPath: await lend(t, { access: null }), secret: SECRET });
  assert.equal((await signedOut.status()).connected, false);
});

test('borrowing ChatGPT is its own provider, checked like Claude\'s, and never beside the Codex sign-in', () => {
  const { subscriptions, routes } = productionModels({ chatgptBorrow: { socketPath: '/x/lend.sock', secret: SECRET }, claudeSubscription: VAULT });
  assert.equal(subscriptions[BORROWED_CHATGPT_PROVIDER].borrowed, true);
  const offered = routes.filter(route => route.provider === BORROWED_CHATGPT_PROVIDER).map(route => route.modelId);
  for (const id of ['gpt-6.2-sol', 'gpt-6.2-astra', 'gpt-6.1-sol', 'gpt-6-astra', 'gpt-6.1-terra', 'gpt-6-luna']) assert.ok(offered.includes(id), id);
  assert.ok(!routes.some(route => route.provider === 'openai'), 'no API key, no openai routes');
  assert.throws(() => productionModels({ chatgptBorrow: { socketPath: 'lend.sock', secret: SECRET } }), /chatgpt_lending_invalid/);
  assert.throws(() => productionModels({ chatgptBorrow: { socketPath: '/x/lend.sock', secret: 'short' } }), /chatgpt_lending_invalid/);
  assert.throws(() => productionModels({ chatgptBorrow: { socketPath: '/x/lend.sock', secret: SECRET }, chatgptSubscription: VAULT }),
    /chatgpt_credential_ambiguous/);
});

// api.openai.com's Responses API, stood in for inside this process.
function responsesStandIn(t) {
  const seen = [];
  const passThrough = globalThis.fetch;
  const sse = events => events.map(data => `data: ${JSON.stringify(data)}\n\n`).join('');
  globalThis.fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    if (url.hostname === '127.0.0.1') return passThrough(input, init);
    if (url.href !== 'https://api.openai.com/v1/responses') throw new Error(`unexpected request to ${url.href}`);
    const headers = new Headers(init.headers ?? input.headers);
    seen.push({ headers, body: JSON.parse(typeof init.body === 'string' ? init.body : await new Response(init.body ?? input.body).text()) });
    const item = { type: 'message', id: 'msg_1', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: 'Hello', annotations: [] }] };
    return new Response(sse([
      { type: 'response.created', response: { id: 'resp_1', status: 'in_progress' } },
      { type: 'response.output_item.added', output_index: 0, item: { ...item, status: 'in_progress', content: [] } },
      { type: 'response.output_text.delta', output_index: 0, content_index: 0, delta: 'Hello' },
      { type: 'response.output_item.done', output_index: 0, item },
      { type: 'response.completed', response: { id: 'resp_1', status: 'completed', output: [item],
        usage: { input_tokens: 3, output_tokens: 1, total_tokens: 4, input_tokens_details: { cached_tokens: 0 } } } }
    ]), { headers: { 'content-type': 'text/event-stream' } });
  };
  t.after(() => { globalThis.fetch = passThrough; });
  return seen;
}

test('a borrowed token goes to api.openai.com as Pi sends a ChatGPT sign-in, and the reply is this provider\'s', async t => {
  const sent = responsesStandIn(t);
  const { models } = productionModels({ chatgptBorrow: { socketPath: await lend(t), secret: SECRET } });
  const model = models.getModel(BORROWED_CHATGPT_PROVIDER, 'gpt-6.1-sol');
  const earlier = { role: 'assistant', api: model.api, provider: BORROWED_CHATGPT_PROVIDER, model: 'gpt-6.1-sol', stopReason: 'toolUse', timestamp: 2,
    content: [{ type: 'toolCall', id: 'call_1|fc_1', name: 'look', arguments: {} }],
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
  const reply = await models.completeSimple(model, { systemPrompt: 'You are an assistant.', messages: [
    { role: 'user', content: 'hi', timestamp: 1 }, earlier,
    { role: 'toolResult', toolCallId: 'call_1|fc_1', toolName: 'look', content: [{ type: 'text', text: 'seen' }], isError: false, timestamp: 3 }
  ] }, { maxRetries: 0, maxTokens: 1000, sessionId: 'conversation-1' });

  assert.equal(reply.stopReason, 'stop', reply.errorMessage);
  assert.equal(reply.provider, BORROWED_CHATGPT_PROVIDER);
  assert.deepEqual(reply.content.filter(part => part.type === 'text').map(part => part.text), ['Hello']);
  const [{ headers, body }] = sent;
  assert.equal(headers.get('authorization'), `Bearer ${TOKEN}`);
  assert.equal(body.model, 'gpt-6.1-sol');
  // What a ChatGPT sign-in refuses is left out, as pi-ai does for its own openai sign-in.
  assert.equal(body.max_output_tokens, undefined);
  assert.equal(body.prompt_cache_retention, undefined);
  assert.equal(body.prompt_cache_key, 'conversation-1'); // gitleaks:allow (the conversation's id, not a key)
  // Its own earlier call is replayed as the same model's, not a stranger's.
  assert.deepEqual(body.input.filter(item => item.type === 'function_call').map(({ id, call_id }) => ({ id, call_id })), [{ id: 'fc_1', call_id: 'call_1' }]);
});

test('every event of a borrowed reply is this provider\'s as it arrives, not only the last', async t => {
  responsesStandIn(t);
  const { models } = productionModels({ chatgptBorrow: { socketPath: await lend(t), secret: SECRET } });
  const stream = models.streamSimple(models.getModel(BORROWED_CHATGPT_PROVIDER, 'gpt-6-luna'),
    { systemPrompt: 'You are an assistant.', messages: [{ role: 'user', content: 'hi', timestamp: 1 }] }, { maxRetries: 0 });
  const seen = new Set();
  for await (const event of stream) for (const message of [event.partial, event.message, event.error]) if (message) seen.add(message.provider);
  assert.deepEqual([...seen], [BORROWED_CHATGPT_PROVIDER]);
});

test('with the lender down, a borrowed model sends nothing and the sidecar says ChatGPT is not signed in', async t => {
  const sent = responsesStandIn(t);
  const cwd = await privateDir('chatgpt-lend-server-');
  const callbacks = { authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) };
  const app = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    chatgptBorrow: { socketPath: join(cwd, 'nobody.sock'), secret: SECRET } }, callbacks);
  t.after(() => app.close());
  assert.equal(app.readiness().ready, true);
  const { port } = await app.listen(0);
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123' };
  const answer = await (await fetch(`http://127.0.0.1:${port}/v1/models`, { headers })).json();
  assert.deepEqual(answer.signedIn, []);
  assert.ok(answer.models.some(model => model.id === 'openai-chatgpt/gpt-6.1-sol'));
  const status = await (await fetch(`http://127.0.0.1:${port}/v1/subscriptions/openai-chatgpt`, { headers })).json();
  assert.deepEqual({ connected: status.connected, borrowed: status.borrowed }, { connected: false, borrowed: true });
  assert.equal(sent.length, 0);
});

// GPT-6.2 is pi-ai's own since 1.6.0 (#273): a request on it is pi-ai's,
// with the model's id and the effort asked.
test('a borrowed sign-in runs GPT-6.2 Astra as pi-ai runs its own models', async t => {
  const sent = responsesStandIn(t);
  const { models } = productionModels({ chatgptBorrow: { socketPath: await lend(t), secret: SECRET } });
  const reply = await models.completeSimple(models.getModel(BORROWED_CHATGPT_PROVIDER, 'gpt-6.2-astra'),
    { systemPrompt: 'You are an assistant.', messages: [{ role: 'user', content: 'hi', timestamp: 1 }] },
    { maxRetries: 0, reasoning: 'high' });
  assert.equal(reply.stopReason, 'stop', reply.errorMessage);
  assert.equal(reply.provider, BORROWED_CHATGPT_PROVIDER);
  assert.equal(sent[0].body.model, 'gpt-6.2-astra');
  assert.equal(sent[0].body.reasoning.effort, 'high');
});
