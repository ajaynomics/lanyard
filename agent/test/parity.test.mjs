// Pi 1.5.0 parity: whole-history snapshots and SSE, native compaction, bounded
// provider retries, run failures surfaced to Rails, and deferred MCP tools found
// with tool_search. Scripted model and local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { writeFile, access } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { obj } from '@earendil-works/pi-schema';
import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { createRuntime } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { App } from '../state.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir, launch, client } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const query = '?actorId=alice&workspaceId=one';
const toolUse = (name, args) => message(call(name, args), { stopReason: 'toolUse' });
// A harmless tool for long tool-round scripts.
const inspector = defineExtension({ name: 'fixture.inspect', tools: [defineTool({ name: 'fx_inspect', description: 'Inspect',
  parameters: obj({}), replay: 'safe', execute: async () => ({ output: [{ type: 'text', text: 'inspected' }] }) })] });
const deps = (cwd, provider, extra = {}) => ({ ...provider, authorize: async requested => ({ ...requested,
  allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }), invoke: async () => ({ status: 'done', result: {} }),
  extensions: [inspector], ...extra });
async function setup(t, responses, config = {}, options = {}) {
  const cwd = await privateDir('omakase-parity-');
  const provider = scriptedProvider(responses, options.provider);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, deps(cwd, provider, options.deps));
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId, content = requestId) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run };
}
const exists = async path => { try { await access(path); return true; } catch { return false; } };

// ---- item 5: no silent truncation ---------------------------------------------------------------

const ROUNDS = 70; // 1 user + 70 tool rounds (2 entries each) + 1 answer: 142 entries, past the 100-entry view window
const longScript = () => [...Array.from({ length: ROUNDS }, () => toolUse('fx_inspect', {})), message('long answer')];

test('a long conversation keeps its whole history in the snapshot and in every SSE frame', async t => {
  const cwd = await privateDir('omakase-parity-long-');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123',
    railsToken: 'different-rails-token', limits: { maxRequests: 200 } }, deps(cwd, scriptedProvider(longScript())));
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const base = `http://127.0.0.1:${port}`;
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const post = async (path, body) => (await fetch(base + path, { method: 'POST', headers, body: JSON.stringify({ ...scope, ...body }) })).json();
  const { id } = await post('/v1/conversations', { requestId: 'create' });
  // Watch from the start, so the stream lives through the window's overflow splices.
  const controller = new AbortController();
  t.after(() => controller.abort());
  const stream = await fetch(`${base}/v1/conversations/${id}/events${query}`, { headers, signal: controller.signal });
  const frames = [];
  const reading = (async () => {
    const reader = stream.body.getReader(), decoder = new TextDecoder();
    let buffer = '';
    for (;;) {
      const { value, done } = await reader.read().catch(() => ({ done: true }));
      if (done) return;
      buffer += decoder.decode(value, { stream: true });
      for (let at = buffer.indexOf('\n\n'); at >= 0; at = buffer.indexOf('\n\n')) {
        const frame = buffer.slice(0, at); buffer = buffer.slice(at + 2);
        const data = frame.split('\n').find(line => line.startsWith('data: '));
        if (data) frames.push(JSON.parse(data.slice(6)));
      }
    }
  })();
  await post(`/v1/conversations/${id}/submissions`, { requestId: 'long', content: 'the first message' });
  const last = await eventually(async () => frames.at(-1)?.status === 'done' && frames.at(-1), 30000);
  const snapshot = await (await fetch(`${base}/v1/conversations/${id}${query}`, { headers })).json();
  const expected = snapshot.entries.length;
  assert.ok(expected >= 1 + 2 * ROUNDS + 1, `${expected} entries`);
  assert.deepEqual(last.entries, snapshot.entries);
  assert.equal(snapshot.entries[0].role, 'user');
  assert.equal(snapshot.entries[0].content, 'the first message');
  assert.equal(snapshot.entries.at(-1).content, 'long answer');
  assert.equal(new Set(snapshot.entries.map(e => e.id)).size, expected);
  assert.equal(snapshot.entries.filter(e => e.toolName === 'fx_inspect').length, ROUNDS);
  // No frame ever dropped the start of the history.
  assert.ok(frames.every(f => f.entries.length === 0 || f.entries[0].content === 'the first message'));
  // A late subscriber's first frame is complete too.
  const late = await fetch(`${base}/v1/conversations/${id}/events${query}`, { headers, signal: controller.signal });
  const text = new TextDecoder().decode((await late.body.getReader().read()).value);
  assert.deepEqual(JSON.parse(text.slice(text.indexOf('data: ') + 6).split('\n')[0]).entries, snapshot.entries);
  controller.abort();
  await reading;
});

// ---- item 7: native compaction ------------------------------------------------------------------

// Durable estimates the transcript at about 4 characters a token; the scripted
// provider refuses a transcript longer than its window, as a provider does.
const WINDOW = 4000;
const INPUTS = 20;
const filler = n => `${n} `.repeat(330).slice(0, 1000); // about 250 tokens per input
const compactionModel = { model: { contextWindow: WINDOW, maxTokens: 500 } };
const chars = messages => JSON.stringify(messages.filter(m => m.role !== 'system')).length;
const compactingModel = calls => context => {
  if (JSON.stringify(context.messages).includes('context summarization assistant')) { calls.summaries++; return message('SUMMARY: the person sent numbered filler.'); }
  if (chars(context.messages) > WINDOW * 4) { calls.overflows++; return message('', { stopReason: 'error', errorMessage: 'prompt is too long: context_length_exceeded' }); }
  calls.answers++;
  return message(`answer ${calls.answers}`);
};

test('a long scripted conversation compacts natively instead of overflowing; history stays visible', async t => {
  const calls = { summaries: 0, overflows: 0, answers: 0 };
  const f = await setup(t, Array.from({ length: 3 * INPUTS }, () => compactingModel(calls)),
    { compaction: { reserveTokens: 1000, keepRecentTokens: 1000, backgroundTokens: 0 } }, { provider: compactionModel });
  for (let n = 1; n <= INPUTS; n++) assert.equal((await f.run(`input-${n}`, filler(n))).status, 'done', `input ${n}`);
  assert.ok(calls.summaries >= 1, 'compacted');
  assert.equal(calls.overflows, 0);
  assert.equal(calls.answers, INPUTS);
  const conversation = await f.runtime.harness.conversation(f.id, ctx);
  const history = (await conversation.entries({ order: 'ascending' }, 1000, undefined, ctx)).items;
  assert.ok(history.some(e => e.kind === 'pi.compaction'));
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'done');
  assert.ok(view.entries.some(e => e.role === 'summary' && /SUMMARY/.test(e.content)));
  // Every input stays in the Rails view; the model works from the compacted context.
  assert.equal(view.entries.filter(e => e.role === 'user').length, INPUTS);
  assert.ok(chars((await conversation.context(ctx)).messages) < WINDOW * 4);
});

test('without compaction the same conversation overflows and fails', async t => {
  const calls = { summaries: 0, overflows: 0, answers: 0 };
  const f = await setup(t, Array.from({ length: 3 * INPUTS }, () => compactingModel(calls)), { compaction: { enabled: false } }, { provider: compactionModel });
  const statuses = [];
  for (let n = 1; n <= INPUTS; n++) statuses.push((await f.run(`input-${n}`, filler(n))).status);
  assert.ok(statuses.includes('unanswered'));
  assert.equal(calls.summaries, 0);
  assert.ok(calls.overflows >= 1);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'error');
  assert.deepEqual(view.failure, { reason: 'model_error' });
});

test('an invalid compaction setting refuses to start', async t => {
  const cwd = await privateDir('omakase-parity-compaction-');
  for (const compaction of [{ enabled: 'yes' }, { reserveTokens: -1 }, { unknown: 1 }]) {
    await assert.rejects(createRuntime({ storePath: join(cwd, `${Object.keys(compaction)[0]}.sqlite`), compaction },
      deps(cwd, scriptedProvider([]))), /invalid_compaction/);
  }
});

// ---- item 8: bounded retries and run failures ---------------------------------------------------

const transient = () => message('', { stopReason: 'error', errorMessage: '503 service temporarily unavailable (overloaded)' });

test('a retryable provider error is retried within the bound; each attempt reserves a request', async t => {
  const f = await setup(t, [transient(), transient(), message('recovered')], { limits: { retryBaseDelayMs: 5 } });
  assert.equal((await f.run('retry')).status, 'done');
  assert.equal(f.provider.faux.state.callCount, 3);
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 3);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'done');
  assert.equal(view.failure, null);
});

test('retries stop at maxRetries and the run failure reaches the snapshot; permanent errors are not retried', async t => {
  const f = await setup(t, [transient(), transient(), transient(), message('never')], { limits: { maxRetries: 1, retryBaseDelayMs: 5 } });
  assert.equal((await f.run('exhaust')).status, 'unanswered');
  assert.equal(f.provider.faux.state.callCount, 2);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.equal(view.status, 'error');
  assert.deepEqual(view.failure, { reason: 'model_error' });
  const permanent = await setup(t, [message('', { stopReason: 'error', errorMessage: 'manufactured invalid request' }), message('never')],
    { limits: { retryBaseDelayMs: 5 } });
  assert.equal((await permanent.run('permanent')).status, 'unanswered');
  assert.equal(permanent.provider.faux.state.callCount, 1);
  // The next run clears the failure.
  permanent.provider.faux.setResponses([message('fine')]);
  assert.equal((await permanent.run('next')).status, 'done');
  assert.equal((await permanent.runtime.snapshot(permanent.id, scope)).failure, null);
});

async function processSetup(extra = {}) {
  const cwd = await privateDir('omakase-parity-process-');
  return { cwd, storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'synthetic-rails-token-456', ...extra };
}
async function crashDuringModelRequest(t, limits) {
  const config = await processSetup({ limits, responses: [{ fixtureHang: true }] });
  const owner = await launch(config, config.cwd, '-hang'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  await api(`${path}/submissions`, { requestId: 'hang', content: 'answer slowly' });
  await eventually(() => exists(join(config.cwd, 'model-started')));
  // Past persistWithinMs, so the running attempt is stored before the crash.
  await new Promise(resolve => setTimeout(resolve, 500));
  await owner.stop('SIGKILL');
  const resumed = await launch({ ...config, responses: [message('answered after the crash')] }, config.cwd, '-resumed');
  t.after(() => resumed.stop());
  const resumedApi = client(resumed, config);
  return eventually(async () => { const s = (await resumedApi(path + query)).body; return ['done', 'error', 'blocked'].includes(s.status) && s; }, 15000);
}

test('a crash during a model request with no retry left ends the run `interrupted`, surfaced to Rails', async t => {
  const final = await crashDuringModelRequest(t, { maxRetries: 0 });
  assert.equal(final.status, 'error');
  assert.deepEqual(final.failure, { reason: 'interrupted' });
  assert.equal(final.entries.some(e => e.content === 'answered after the crash'), false);
});

test('a crash during a model request is retried once retries are allowed', async t => {
  const final = await crashDuringModelRequest(t, { maxRetries: 1, retryBaseDelayMs: 5 });
  assert.equal(final.status, 'done');
  assert.equal(final.failure, null);
  assert.ok(final.entries.some(e => e.content === 'answered after the crash'));
});

test('work the restart limit cuts off is reported `blocked` with reason restart_limit, not retried silently', async t => {
  const config = await processSetup({ limits: { restartLimit: 1 }, fixtureExtensions: ['sleep'], responses: [toolUse('fx_sleep', {})] });
  const owner = await launch(config, config.cwd, '-loop'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  await api(`${path}/submissions`, { requestId: 'sleep', content: 'sleep' });
  await eventually(() => exists(join(config.cwd, 'sleep-starts')));
  await owner.stop('SIGKILL');
  const resumed = await launch({ ...config, responses: [] }, config.cwd, '-loop-resumed'); t.after(() => resumed.stop());
  const resumedApi = client(resumed, config);
  const final = await eventually(async () => { const s = (await resumedApi(path + query)).body; return ['done', 'error', 'blocked'].includes(s.status) && s; }, 15000);
  assert.equal(final.status, 'blocked');
  assert.deepEqual(final.failure, { reason: 'restart_limit' });
  assert.equal(final.entries.find(e => e.toolName === 'fx_sleep')?.isError, true);
  const inspection = await resumed.inspect(conversation.id);
  assert.equal(inspection.liveTasks, 0);
  // No further model request after the crash loop: the run stops, as the 1.4 park did.
  assert.equal(inspection.modelCalls, 0);
});

// ---- item 9: deferred MCP tools and tool_search -------------------------------------------------

const MCP_SERVER = `import { createInterface } from 'node:readline';
const write = value => process.stdout.write(JSON.stringify(value) + '\\n');
createInterface({ input: process.stdin }).on('line', line => {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  const reply = result => write({ jsonrpc: '2.0', id: message.id, result });
  if (message.method === 'initialize') return reply({ protocolVersion: message.params.protocolVersion,
    capabilities: { tools: {} }, serverInfo: { name: 'parity-fixture', version: '1' } });
  if (message.method === 'tools/list') return reply({ tools: [{ name: 'lookup', description: 'Look up a manufactured inventory record',
    inputSchema: { type: 'object', properties: { key: { type: 'string' } }, required: ['key'] } }] });
  if (message.method === 'tools/call') return reply({ content: [{ type: 'text', text: 'record ' + message.params.arguments.key }] });
  write({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } });
});
`;

test('deferred MCP tools are offered only after tool_search loads them; plain MCP and other scopes get no tool_search', async t => {
  const dir = await privateDir('omakase-parity-mcp-');
  await writeFile(join(dir, 'server.mjs'), MCP_SERVER);
  const server = (serverId, extra = {}) => ({ ...scope, serverId, accountId: 'acct', tools: ['lookup'],
    stdio: { command: process.execPath, args: [join(dir, 'server.mjs')] }, ...extra });
  const offered = [];
  const record = response => context => { offered.push(getCurrentTools(context.messages).map(tool => tool.name).sort()); return response; };
  const f = await setup(t, [record(toolUse('tool_search', { query: 'inventory record' })),
    record(toolUse('mcp__inv__lookup', { key: 'k1' })), record(message('found'))],
  { mcp: [server('inv', { deferTools: true }), server('other', { actorId: 'bob' })] });
  assert.equal((await f.run('find')).status, 'done');
  assert.ok(offered[0].includes('tool_search'));
  assert.equal(offered[0].includes('mcp__inv__lookup'), false);
  assert.ok(offered[1].includes('mcp__inv__lookup'));
  const results = (await f.runtime.snapshot(f.id, scope)).entries.filter(e => e.role === 'toolResult');
  assert.match(results[0].content, /mcp__inv__lookup/);
  assert.equal(results[1].content, 'record k1');
  // A conversation outside the deferred server's scope is not offered tool_search.
  const plain = await setup(t, [record(message('plain'))], { mcp: [server('inv', { actorId: 'bob', deferTools: true })] });
  assert.equal((await plain.run('plain')).status, 'done');
  assert.equal(offered.at(-1).includes('tool_search'), false);
  const none = await setup(t, [record(message('none'))]);
  assert.equal(none.runtime.registry.snapshot().tools().some(row => row.tool.name === 'tool_search'), false);
  assert.equal((await none.run('none')).status, 'done');
});
