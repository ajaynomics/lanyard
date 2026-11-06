import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { billingHeader, shapePayload, fileCredentials } from '../claude-subscription.mjs';
import { productionModels } from '../runtime.mjs';
import { privateDir } from './processes.mjs';

test('the billing block follows the pi-anthropic-auth recipe (vectors from an earlier app\'s copy of it)', () => {
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

test('the credential file: absent is signed out; writes are whole and private; only anthropic, only OAuth', async () => {
  const path = join(await privateDir('omakase-claude-'), 'claude-subscription.json');
  const store = fileCredentials(path);
  assert.equal(await store.read('anthropic'), undefined);
  assert.deepEqual(await store.list(), []);
  const credential = { type: 'oauth', access: 'sk-ant-oat01-one', refresh: 'r1', expires: 1 };
  assert.deepEqual(await store.modify('anthropic', async current => (assert.equal(current, undefined), credential)), credential);
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  assert.deepEqual(await store.read('anthropic'), credential);
  assert.deepEqual(await store.list(), [{ providerId: 'anthropic', type: 'oauth' }]);
  assert.equal(await store.read('openai'), undefined);
  await assert.rejects(store.modify('openai', async () => credential), /credential_mutation_disabled/);
  await assert.rejects(store.modify('anthropic', async () => ({ type: 'api_key', key: 'k' })), /claude_subscription_oauth_only/);
  await writeFile(path, '{not json');
  await assert.rejects(store.read('anthropic'), /claude_subscription_unreadable/);
});

test('a subscription and an API key for Claude are never both configured, and the file path is absolute', () => {
  assert.throws(() => productionModels({ claudeSubscriptionFile: '/x/c.json', anthropicApiKey: 'k' }), /anthropic_credential_ambiguous/);
  assert.throws(() => productionModels({ claudeSubscriptionFile: 'c.json' }), /claude_subscription_file_invalid/);
  assert.throws(() => productionModels({ claudeSubscriptionFile: '/x/c.json', openaiApiKey: 'k' }), /claude_subscription_excludes_openai/);
});

// Anthropic's two endpoints, stood in for inside this process: the token
// endpoint answers a refresh, the Messages endpoint records what it was sent
// and streams a one-word reply.
function anthropicStandIn() {
  const seen = { refreshes: [], messages: [] };
  const sse = events => events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('');
  const fetch = async (input, init = {}) => {
    const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
    const body = JSON.parse(init.body ?? (await input.text?.()) ?? '{}');
    if (url.href === 'https://platform.claude.com/v1/oauth/token') {
      seen.refreshes.push(body);
      return new Response(JSON.stringify({ access_token: 'sk-ant-oat01-fresh-token', refresh_token: 'r2', expires_in: 3600 }), { headers: { 'content-type': 'application/json' } });
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
  return { seen, fetch };
}

test('through the subscription: an expired token is refreshed and saved, the request carries the bearer, Claude Code identity and the billing block', async t => {
  const path = join(await privateDir('omakase-claude-run-'), 'claude-subscription.json');
  await writeFile(path, JSON.stringify({ type: 'oauth', access: 'sk-ant-oat01-stale', refresh: 'r1', expires: Date.now() - 1000 }), { mode: 0o600 });
  const anthropic = anthropicStandIn();
  const saved = globalThis.fetch;
  globalThis.fetch = anthropic.fetch;
  t.after(() => { globalThis.fetch = saved; });

  const { models, routes } = productionModels({ claudeSubscriptionFile: path });
  assert.deepEqual(routes.map(route => route.provider), ['anthropic', 'anthropic', 'anthropic']);
  const model = models.getModel('anthropic', 'claude-sonnet-5-5');
  const reply = await models.completeSimple(model, { systemPrompt: 'You are Avery.', messages: [{ role: 'user', content: 'Remember that my dentist is on Tuesday', timestamp: 1 }] });
  assert.equal(reply.stopReason, 'stop', reply.errorMessage);
  assert.deepEqual(reply.content.map(part => part.text), ['Hello']);

  assert.deepEqual(anthropic.seen.refreshes.map(body => [body.grant_type, body.refresh_token]), [['refresh_token', 'r1']]);
  const stored = JSON.parse(await readFile(path, 'utf8'));
  assert.equal(stored.access, 'sk-ant-oat01-fresh-token');
  assert.equal(stored.refresh, 'r2');
  const [sent] = anthropic.seen.messages;
  assert.equal(sent.headers.get('authorization'), 'Bearer sk-ant-oat01-fresh-token');
  assert.equal(sent.headers.get('x-api-key'), null);
  assert.match(sent.headers.get('anthropic-beta'), /oauth-2025-04-20/);
  assert.deepEqual(sent.body.system.map(block => block.text), [
    billingHeader('Remember that my dentist is on Tuesday'),
    "You are Claude Code, Anthropic's official CLI for Claude.",
    'You are Avery.'
  ]);
});

test('signed out: a run fails plainly and nothing is sent', async t => {
  const path = join(await privateDir('omakase-claude-out-'), 'claude-subscription.json');
  const anthropic = anthropicStandIn();
  const saved = globalThis.fetch;
  globalThis.fetch = anthropic.fetch;
  t.after(() => { globalThis.fetch = saved; });
  const { models } = productionModels({ claudeSubscriptionFile: path });
  const reply = await models.completeSimple(models.getModel('anthropic', 'claude-sonnet-5-5'), { messages: [{ role: 'user', content: 'hi', timestamp: 1 }] });
  assert.equal(reply.stopReason, 'error');
  assert.equal(anthropic.seen.messages.length + anthropic.seen.refreshes.length, 0);
});
