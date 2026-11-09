// The sidecar's built-in capabilities: helpers and web
// search. Scripted model, a Rails stand-in and stubbed provider responses
// (recorded shapes) only: no request leaves the process.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { createRuntime } from '../runtime.mjs';
import { UsageDoc } from '@earendil-works/pi-durable';
import { App } from '../state.mjs';
import { HELPER_INSTRUCTIONS } from '../subagent.mjs';
import { SEARCH_MODEL, searchCodex, answerWithSources } from '../web-search.mjs';
import { CLAUDE_CODE_VERSION } from '../claude-subscription.mjs';
import { nonLocalAttempts } from './local-only.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const toolUse = (name, args, id) => message(call(name, args, { id }), { stopReason: 'toolUse' });
async function fixture(t, responses, { deps = {}, ...config } = {}) {
  const cwd = await privateDir('omakase-capabilities-');
  const provider = deps.models ? {} : scriptedProvider(responses);
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...provider,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    invoke: rails.invoke, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  return { runtime, id, rails, provider, cwd };
}
const wait = async (runtime, sub) => (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
async function until(fn, ms = 5000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('fixture_deadline');
}

test('a helper runs the task in a child conversation and its answer is the call result; its calls reach Rails as the root', async t => {
  const frames = [], seen = {};
  const f = await fixture(t, [
    toolUse('subagent', { task: 'Save the note, then ask.' }, 'toolu_h'),
    context => {
      seen.instructions = JSON.stringify(context);
      seen.tools = getCurrentTools(context.messages).map(tool => tool.name);
      seen.task = JSON.stringify(context.messages);
      return toolUse('note', { key: 'k' }, 'toolu_n');
    },
    toolUse('ask', { question: 'Tea?' }, 'toolu_a'),
    message('The helper saved it; the person wants tea.'),
    message('All done.')
  ], { limits: { frameIntervalMs: 20 }, deps: { frame: async data => { frames.push(data); } } });
  const sub = await f.runtime.submit(f.id, { ...scope, requestId: 'help', content: 'get help', definition: definition({ instructions: 'Fixture persona.' }) });

  // The child's question waits like any call, under the root; the root's doorbell finds it.
  await until(async () => f.rails.keys().length === 1);
  assert.equal((await f.runtime.snapshot(f.id, scope)).status, 'waiting');
  // Long enough for the helper's running call to reach a frame.
  await until(async () => frames.some(frame => frame.tools.some(tool => tool.callId === 'toolu_h/toolu_a')));
  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['Tea'] });
  assert.deepEqual(await f.runtime.wake(f.id, { ...scope, key }), { rung: true });
  assert.equal((await wait(f.runtime, sub)).status, 'done');

  assert.deepEqual(f.rails.calls.map(c => [c.tool, c.conversationId, c.callId]),
    [['note', String(f.id), 'toolu_h/toolu_n'], ['ask', String(f.id), 'toolu_h/toolu_a'], ['ask', String(f.id), 'toolu_h/toolu_a']]);
  // The parent's model, instructions and tools, without helpers of its own.
  assert.match(seen.instructions, /Fixture persona\./);
  assert.ok(seen.instructions.includes(HELPER_INSTRUCTIONS));
  assert.ok(seen.tools.includes('note') && seen.tools.includes('codemode'));
  assert.equal(seen.tools.includes('subagent'), false);
  assert.match(seen.task, /Save the note, then ask\./);

  const { entries } = await f.runtime.entries(f.id, scope);
  const result = entries.find(e => e.role === 'toolResult');
  assert.equal(result.toolName, 'subagent');
  assert.equal(result.content, 'The helper saved it; the person wants tea.');
  assert.equal(entries.at(-1).content, 'All done.');
  // The root's run bound counts the helper's model requests too.
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 5);
  // The helper's running calls show under its line in the root's frames.
  await until(async () => frames.at(-1)?.busy === false);
  const helperTools = frames.flatMap(frame => frame.tools).filter(tool => tool.callId.startsWith('toolu_h/'));
  assert.ok(helperTools.some(tool => tool.callId === 'toolu_h/toolu_a' && tool.name === 'ask'), JSON.stringify(helperTools));
  assert.ok(frames.flatMap(frame => frame.tools).some(tool => tool.callId === 'toolu_h' && tool.name === 'subagent'));
  // A running call's line says what it was given; the helper's own, how many calls it has made.
  assert.ok(helperTools.some(tool => tool.callId === 'toolu_h/toolu_a' && tool.arguments?.question === 'Tea?'), JSON.stringify(helperTools));
  assert.ok(frames.flatMap(frame => frame.tools).some(tool => tool.callId === 'toolu_h' && tool.count === 2));
  // Its result keeps every call, settled, with what went in and what came back.
  assert.deepEqual(result.calls.map(c => [c.callId, c.name, c.status, c.arguments]),
    [['toolu_n', 'note', 'done', { key: 'k' }], ['toolu_a', 'ask', 'done', { question: 'Tea?' }]]);
  assert.match(result.calls[1].output, /Tea/);
  assert.equal(result.callCount, 2);
});

test('a helper call that failed is kept as failed, and none is left running', async t => {
  const f = await fixture(t, [toolUse('subagent', { task: 'Try it.' }, 'toolu_h'), toolUse('no_such_tool', { x: 1 }, 'toolu_x'),
    message('It failed.'), message('Done.')]);
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'fail', content: 'x', definition: definition() }));
  const { entries } = await f.runtime.entries(f.id, scope);
  const result = entries.find(e => e.role === 'toolResult' && e.toolName === 'subagent');
  assert.deepEqual(result.calls.map(c => [c.callId, c.name, c.status]), [['toolu_x', 'no_such_tool', 'failed']]);
  assert.ok(result.calls[0].output.length > 0);
});

test('the helper runs within the parent run\'s request bound', async t => {
  const f = await fixture(t, [toolUse('subagent', { task: 'Loop.' }, 'toolu_h'), toolUse('note', { key: 'a' }, 'n1'),
    toolUse('note', { key: 'b' }, 'n2'), message('never')], { limits: { maxRequests: 3, maxRetries: 0 } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'bound', content: 'x', definition: definition() }));
  const { entries } = await f.runtime.entries(f.id, scope);
  const result = entries.find(e => e.role === 'toolResult' && e.toolName === 'subagent');
  assert.equal(result.isError, true);
  assert.match(result.content, /stopped without an answer/);
  assert.equal(f.rails.calls.length, 2);
});

test('an agent without helpers has no subagent tool', async t => {
  const f = await fixture(t, [message('one')]);
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'x', content: 'x', definition: definition({ capabilities: ['codemode'] }) }));
  const tools = (await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx)).tools.map(tool => tool.name);
  assert.equal(tools.includes('subagent'), false);
});

// ---- web search ---------------------------------------------------------------------------------

const sse = events => new Response(events.map(event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join(''),
  { status: 200, headers: { 'content-type': 'text/event-stream' } });
const RAILS_POST = 'https://rubyonrails.org/2026/11/rails-8-2';
// What Anthropic streams for one search, as recorded from the Messages API (contents shortened).
const anthropicSearch = () => sse([
  { type: 'message_start', message: { id: 'msg_1', type: 'message', role: 'assistant', model: SEARCH_MODEL, content: [],
    usage: { input_tokens: 1200, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 3 } } },
  { type: 'content_block_start', index: 0, content_block: { type: 'server_tool_use', id: 'srvtoolu_1', name: 'web_search', input: {} } },
  { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: '{"query":"rails 8.2"}' } },
  { type: 'content_block_stop', index: 0 },
  { type: 'content_block_start', index: 1, content_block: { type: 'web_search_tool_result', tool_use_id: 'srvtoolu_1', content: [
    { type: 'web_search_result', title: 'Rails 8.2 released', url: RAILS_POST, encrypted_content: 'opaque', page_age: null },
    { type: 'web_search_result', title: 'Other', url: 'https://example.com/other', encrypted_content: 'opaque', page_age: null }] } },
  { type: 'content_block_stop', index: 1 },
  { type: 'content_block_start', index: 2, content_block: { type: 'text', text: '', citations: [] } },
  { type: 'content_block_delta', index: 2, delta: { type: 'citations_delta', citation: { type: 'web_search_result_location',
    cited_text: 'Rails 8.2 is out', url: RAILS_POST, title: 'Rails 8.2 released', encrypted_index: 'opaque' } } },
  { type: 'content_block_delta', index: 2, delta: { type: 'text_delta', text: 'Rails 8.2 is out.' } },
  { type: 'content_block_stop', index: 2 },
  { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 40, server_tool_use: { web_search_requests: 1 } } },
  { type: 'message_stop' }]);

test('web search on a Claude subscription asks Anthropic as Claude Code and answers with linked sources', async t => {
  const requests = [];
  const token = 'sk-ant-oat01-synthetic-not-a-token';
  const provider = scriptedProvider([toolUse('web_search', { query: 'rails 8.2' }, 'toolu_w'), message('Rails 8.2 is out.')], { provider: 'anthropic' });
  const f = await fixture(t, [], { deps: { ...provider, model: { provider: 'anthropic', modelId: 'scripted' },
    credential: async id => id === 'anthropic' ? { type: 'api_key', key: token } : undefined,
    fetch: async (url, init) => { requests.push({ url, init }); return anthropicSearch(); } } });
  const before = nonLocalAttempts();
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'search', content: 'what is new', definition: definition({ model: 'anthropic/scripted' }) }));

  assert.equal(requests.length, 1);
  const [{ url, init }] = requests;
  assert.equal(url, 'https://api.anthropic.com/v1/messages');
  assert.equal(init.headers.authorization, `Bearer ${token}`);
  assert.equal(init.headers['anthropic-beta'], 'claude-code-20250219,oauth-2025-04-20');
  assert.equal(init.headers['user-agent'], `claude-cli/${CLAUDE_CODE_VERSION}`);
  assert.equal(init.headers['x-app'], 'cli');
  const body = JSON.parse(init.body);
  assert.equal(body.model, 'claude-haiku-5-5');
  assert.deepEqual(body.tools, [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }]);
  assert.match(body.system[0].text, /^x-anthropic-billing-header:/);
  assert.equal(body.system[1].text, "You are Claude Code, Anthropic's official CLI for Claude.");
  assert.match(body.messages[0].content, /rails 8\.2/);

  const { entries } = await f.runtime.entries(f.id, scope);
  const result = entries.find(e => e.role === 'toolResult');
  assert.equal(result.toolName, 'web_search');
  assert.equal(result.content, `Rails 8.2 is out.\n\nSources:\n- [Rails 8.2 released](${RAILS_POST})`);
  // The search is a request of the run, and its spend is in the conversation's totals.
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 3);
  const usage = await f.runtime.harness.snapshot(UsageDoc, f.id, ctx);
  assert.equal(usage.tools.web_search.input, 1200);
  assert.equal(usage.tools.web_search.output, 40);
  assert.ok(usage.tools.web_search.cost.total > 0);
  assert.equal(nonLocalAttempts(), before);
});

test('web search on the pasted Anthropic API key asks the same search as plain API traffic: x-api-key, no Claude Code', async t => {
  const requests = [];
  const key = 'sk-ant-usr01-made-up-for-tests-only-wxyz';
  const provider = scriptedProvider([toolUse('web_search', { query: 'rails 8.2' }, 'toolu_w'), message('Rails 8.2 is out.')], { provider: 'anthropic-api' });
  const f = await fixture(t, [], { deps: { ...provider, model: { provider: 'anthropic-api', modelId: 'scripted' },
    credential: async id => id === 'anthropic-api' ? { type: 'api_key', key } : undefined,
    fetch: async (url, init) => { requests.push({ url, init }); return anthropicSearch(); } } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'search', content: 'what is new', definition: definition({ model: 'anthropic-api/scripted' }) }));

  const [{ url, init }] = requests;
  assert.equal(url, 'https://api.anthropic.com/v1/messages');
  assert.equal(init.headers['x-api-key'], key);
  for (const header of ['authorization', 'anthropic-beta', 'user-agent', 'x-app']) assert.equal(init.headers[header], undefined, header);
  const body = JSON.parse(init.body);
  assert.equal(body.model, 'claude-haiku-5-5');
  assert.equal(body.system, undefined, 'no Claude Code identity or billing block');
  const result = (await f.runtime.entries(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(result.content, `Rails 8.2 is out.\n\nSources:\n- [Rails 8.2 released](${RAILS_POST})`);

  const unset = await fixture(t, [], { deps: { ...scriptedProvider([toolUse('web_search', { query: 'x' }, 'w1'), message('ok')], { provider: 'anthropic-api' }),
    model: { provider: 'anthropic-api', modelId: 'scripted' }, fetch: async () => { throw new Error('no network in tests'); } } });
  await wait(unset.runtime, await unset.runtime.submit(unset.id, { ...scope, requestId: 'a', content: 'x', definition: definition({ model: 'anthropic-api/scripted' }) }));
  const refused = (await unset.runtime.entries(unset.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(refused.content, 'Web search needs the Claude API key; it is not set.');
});

test('web search fails plainly without a credential, or on a model whose provider has no search', async t => {
  const provider = scriptedProvider([toolUse('web_search', { query: 'x' }, 'w1'), message('ok')], { provider: 'anthropic' });
  const signedOut = await fixture(t, [], { deps: { ...provider, model: { provider: 'anthropic', modelId: 'scripted' },
    fetch: async () => { throw new Error('no network in tests'); } } });
  await wait(signedOut.runtime, await signedOut.runtime.submit(signedOut.id, { ...scope, requestId: 'a', content: 'x', definition: definition({ model: 'anthropic/scripted' }) }));
  const refused = (await signedOut.runtime.entries(signedOut.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(refused.isError, true);
  assert.equal(refused.content, 'Web search needs the Claude subscription; it is not signed in.');

  const other = await fixture(t, [toolUse('web_search', { query: 'x' }, 'w1'), message('ok')]);
  await wait(other.runtime, await other.runtime.submit(other.id, { ...scope, requestId: 'b', content: 'x', definition: definition() }));
  const unavailable = (await other.runtime.entries(other.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(unavailable.content, "Web search is not available for this agent's model.");
});

test('a stalled web search ends on its own time limit, not when someone cancels', async t => {
  const provider = scriptedProvider([toolUse('web_search', { query: 'x' }, 'w1'), message('ok')], { provider: 'anthropic' });
  const f = await fixture(t, [], { limits: { requestIdleMs: 1000, maxRetries: 0 }, deps: { ...provider, model: { provider: 'anthropic', modelId: 'scripted' },
    credential: async () => ({ type: 'api_key', key: 'sk-ant-oat01-synthetic-not-a-token' }),
    // The provider never answers: only the request's signal ends it.
    fetch: (url, init) => new Promise((resolve, reject) => {
      // An abort timer does not hold the process open; a live socket would.
      const held = setInterval(() => {}, 1000);
      init.signal.addEventListener('abort', () => { clearInterval(held); reject(init.signal.reason); });
    }) } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...scope, requestId: 'a', content: 'x', definition: definition({ model: 'anthropic/scripted' }) }));
  const result = (await f.runtime.entries(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(result.content, 'Web search took too long, so it stopped.');
});

test('web search on the ChatGPT subscription asks Codex Responses with its web_search tool', async () => {
  const claims = Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: 'acct_synthetic' } })).toString('base64url');
  const token = `eyJhbGciOiJub25lIn0.${claims}.signature`;
  const requests = [];
  const fetch = async (url, init) => { requests.push({ url, init }); return sse([
    { type: 'response.created', response: { id: 'resp_1', status: 'in_progress' } },
    { type: 'response.output_item.done', item: { id: 'ws_1', type: 'web_search_call', status: 'completed',
      action: { type: 'search', query: 'rails 8.2', sources: [{ type: 'url', url: RAILS_POST }] } } },
    { type: 'response.output_text.delta', item_id: 'msg_1', delta: 'Rails 8.2 ' },
    { type: 'response.output_text.delta', item_id: 'msg_1', delta: 'is out.' },
    { type: 'response.output_item.done', item: { id: 'msg_1', type: 'message', role: 'assistant', content: [{ type: 'output_text',
      text: 'Rails 8.2 is out.', annotations: [{ type: 'url_citation', start_index: 0, end_index: 17, url: RAILS_POST, title: 'Rails 8.2 released' }] }] } },
    { type: 'response.completed', response: { id: 'resp_1', status: 'completed',
      usage: { input_tokens: 900, input_tokens_details: { cached_tokens: 100 }, output_tokens: 30, total_tokens: 930 } } }]); };
  const found = await searchCodex({ query: 'rails 8.2', token, modelId: 'gpt-6.1-sol', fetch });

  const [{ url, init }] = requests;
  assert.equal(url, 'https://chatgpt.com/backend-api/codex/responses');
  assert.equal(init.headers.authorization, `Bearer ${token}`);
  assert.equal(init.headers['chatgpt-account-id'], 'acct_synthetic');
  const body = JSON.parse(init.body);
  assert.equal(body.model, 'gpt-6.1-sol');
  assert.deepEqual(body.tools, [{ type: 'web_search' }]);
  assert.deepEqual(body.input, [{ role: 'user', content: [{ type: 'input_text', text: body.input[0].content[0].text }] }]);
  assert.equal(body.store, false);
  assert.equal(answerWithSources(found), `Rails 8.2 is out.\n\nSources:\n- [Rails 8.2 released](${RAILS_POST})`);
  assert.deepEqual([found.usage.input, found.usage.cacheRead, found.usage.output], [800, 100, 30]);
});

test('a provider usage limit leaves the sidecar as rate_limited, other model errors as model_error', async () => {
  const { failureReason } = await import('../runtime.mjs');
  assert.equal(failureReason(undefined), null);
  assert.equal(failureReason({ reason: 'model_error', detail: '429 {"type":"error","error":{"type":"rate_limit_error"}}' }), 'rate_limited');
  assert.equal(failureReason({ reason: 'model_error', detail: 'overloaded' }), 'model_error');
  assert.equal(failureReason({ reason: 'turn_limit', detail: '3 turns' }), 'turn_limit');
});
