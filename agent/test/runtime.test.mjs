import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, productionModels, LOCAL_ROUTE } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { App, Definitions } from '../state.mjs';
import { railsStandIn, definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
import { reply as localReply } from '../local-model.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

async function fixture(t, responses = [message('scripted greeting')], overrides = {}) {
  const cwd = await privateDir('omakase-native-');
  const provider = scriptedProvider(responses);
  const config = { storePath: join(cwd, 'state.sqlite'), ...overrides };
  const rails = railsStandIn();
  const deps = { ...provider, authorize: async scope => ({ ...scope, allowed: scope.actorId === 'alice' && scope.workspaceId === 'one', cwd }),
    invoke: rails.invoke, ...overrides.deps };
  delete config.deps;
  const runtime = await createRuntime(config, deps);
  t.after(() => runtime.close());
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create-1' });
  return { runtime, config, deps, cwd, scope, id, provider, rails };
}
async function wait(runtime, sub) { return (await runtime.harness.submission(sub.id, ctx)).wait(ctx); }
async function until(fn) {
  const end = Date.now() + 5000;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('fixture_deadline');
}

test('the production catalogue offers every model of a provider whose credential is present; local only on request', () => {
  assert.throws(() => productionModels({}), /provider_credential_missing/);
  const anthropic = productionModels({ anthropicApiKey: 'synthetic-not-a-real-key' });
  assert.deepEqual(anthropic.models.getProviders().map(p => p.id), ['anthropic']);
  assert.deepEqual(anthropic.routes, anthropic.models.getProviders()[0].getModels().map(model => ({ provider: 'anthropic', modelId: model.id })));
  assert.ok(anthropic.routes.some(route => route.modelId === 'claude-sonnet-5'));
  const both = productionModels({ anthropicApiKey: 'synthetic-key-one', openaiApiKey: 'synthetic-key-two' });
  assert.deepEqual(new Set(both.routes.map(route => route.provider)), new Set(['anthropic', 'openai']));
  assert.ok(both.routes.some(route => route.provider === 'openai' && route.modelId === 'gpt-6.1-sol'));
  const local = productionModels({ modelMode: 'local' });
  assert.deepEqual(local.routes, [LOCAL_ROUTE]);
  assert.throws(() => productionModels({ modelMode: 'free' }), /invalid_model_mode/);
});

test('the local stand-in model streams an honest echo and maps plain commands to offered tools only', () => {
  const offered = [{ role: 'system', content: '', toolsAdded: [{ name: 'remember_note' }, { name: 'ask_person' }] }];
  const said = text => localReply([...offered, { role: 'user', content: text }]);
  assert.match(said('hello').content[0].text, /not an AI/);
  const { id: _id, ...remembered } = said('remember dentist: Tuesday 3pm').content.at(-1);
  assert.deepEqual(remembered, { type: 'toolCall', name: 'remember_note', arguments: { key: 'dentist', body: 'Tuesday 3pm' } });
  assert.match(said('time').content[0].text, /does not have the current_time tool/);
  assert.match(said('run ls').content[0].text, /no computer/);
  const { id: _call, ...ran } = localReply([{ role: 'system', content: '', toolsAdded: [{ name: 'bash' }] }, { role: 'user', content: 'run ls -la' }]).content.at(-1);
  assert.deepEqual(ran, { type: 'toolCall', name: 'bash', arguments: { command: 'ls -la' } });
  assert.match(localReply([...offered, { role: 'toolResult', toolName: 'ask_person', content: [{ type: 'text', text: '{"selections":["Tea"]}' }] }]).content[0].text, /Tea/);
});

test('real Durable SQLite admission, conflicts, scope and actual usage', async t => {
  const f = await fixture(t);
  assert.equal((await f.runtime.create({ ...f.scope, requestId: 'create-1' })).id, f.id);
  const input = { ...f.scope, requestId: 'hello', content: 'hello' };
  const first = await f.runtime.submit(f.id, input);
  assert.equal((await f.runtime.submit(f.id, input)).id, first.id);
  assert.equal((await wait(f.runtime, first)).status, 'done');
  await assert.rejects(f.runtime.submit(f.id, { ...input, content: 'different' }), /request_conflict/);
  await assert.rejects(f.runtime.snapshot(f.id, { ...f.scope, actorId: 'bob' }), /not_found/);
  const snapshot = await f.runtime.snapshot(f.id, f.scope);
  assert.deepEqual(Object.keys(snapshot).sort(), ['compaction', 'compactionFailed', 'entries', 'failure', 'id', 'notesFile', 'pendingInputs', 'status', 'usage']);
  assert.equal(snapshot.failure, null);
  assert.ok(snapshot.entries.some(e => e.role === 'assistant' && e.content === 'scripted greeting'));
  assert.equal(f.provider.faux.state.callCount, 1);
});

test('native coding schemas/results, minimal shell environment and failures', async t => {
  const f = await fixture(t, [message([call('write', { path: 'a.txt', content: 'old\n' })], { stopReason: 'toolUse' }),
    message([call('edit', { path: 'a.txt', edits: [{ oldText: 'old', newText: 'new' }] })], { stopReason: 'toolUse' }),
    message([call('bash', { command: 'printf "%s" "${SIDECAR_TOKEN-unset}"' })], { stopReason: 'toolUse' }), message('done')],
    { execution: 'trusted-local-single-tenant' });
  const result = await f.runtime.submit(f.id, { ...f.scope, requestId: 'code', content: 'code fixture', definition: definition({ computer: LOCAL_COMPUTER }) });
  assert.equal((await wait(f.runtime, result)).status, 'done');
  // Each conversation works in its own directory under the bot's computer.
  assert.equal(await readFile(join(f.cwd, 'conversations', String(f.id), 'a.txt'), 'utf8'), 'new\n');
  const tools = f.runtime.registry.snapshot().tools().filter(row => ['read', 'write', 'edit', 'bash'].includes(row.tool.name)).map(row => row.tool);
  assert.deepEqual(tools.map(t => t.name).sort(), ['bash', 'edit', 'read', 'write']);
  assert.ok(tools.every(t => t.replay !== 'safe'));
  assert.equal(tools.find(t => t.name === 'edit').parameters.properties.edits.items.properties.oldText.type, 'string');
  const context = await (await f.runtime.harness.conversation(f.id, ctx)).context(ctx);
  assert.ok(JSON.stringify(context.entries).includes('unset'));
});

test('a definition configures the conversation; every call goes to Rails, signed and named by task and call', async t => {
  const f = await fixture(t, [message(call('note', { key: 'k' }), { stopReason: 'toolUse' }), message('saved')]);
  const bot = definition({ instructions: 'Fixture persona instructions.' });
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'note', content: 'save it', definition: bot });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
  const agent = await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx);
  assert.equal(agent.instructions, 'Fixture persona instructions.');
  assert.ok(agent.extensions.some(e => e.name === `bot.${bot.digest}`));
  assert.deepEqual(f.rails.calls.map(c => [c.tool, c.arguments, c.conversationId, c.actorId]), [['note', { key: 'k' }, String(f.id), 'alice']]);
  const stored = await f.runtime.harness.snapshot(Definitions, ctx);
  assert.equal(stored.conversations[f.id], bot.digest);
  const snapshot = await f.runtime.snapshot(f.id, f.scope);
  assert.ok(snapshot.entries.some(e => e.role === 'toolResult' && e.content.includes('"ok":true')));
});

test('a definition must name itself by its digest, use an offered model, and shadow no sidecar tool', async t => {
  const f = await fixture(t);
  const submit = (requestId, value) => f.runtime.submit(f.id, { ...f.scope, requestId, content: 'x', definition: value });
  await assert.rejects(submit('a', { ...definition(), digest: '0'.repeat(64) }), /definition_digest_mismatch/);
  await assert.rejects(submit('b', definition({ model: 'anthropic/claude-opus-5-5' })), /model_unavailable/);
  await assert.rejects(submit('c', definition({ tools: [{ name: 'bash', description: 'x', parameters: { type: 'object' } }] })), /invalid_tools/);
  await assert.rejects(submit('d', definition({ tools: [{ name: 'Bad Name', description: 'x', parameters: { type: 'object' } }] })), /invalid_tools/);
  await assert.rejects(submit('e', { ...definition(), extra: true }), /invalid_definition/);
  await assert.rejects(submit('f', definition({ capabilities: ['codemode', 'extensions'] })), /invalid_capabilities/);
  await assert.rejects(submit('g', definition({ capabilities: ['codemode', 'codemode'] })), /invalid_capabilities/);
});

test('a conversation gets only the capabilities its bot names', async t => {
  const f = await fixture(t, [message('one'), message('two')]);
  const extensionsAfter = async (requestId, capabilities) => {
    await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId, content: 'x', definition: definition({ capabilities }) }));
    return (await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx)).tools.map(tool => tool.name);
  };
  assert.ok((await extensionsAfter('on', ['codemode'])).includes('codemode'));
  assert.equal((await extensionsAfter('off', [])).includes('codemode'), false);
});

test('any thinking level pi-ai knows is accepted, and the conversation runs at the nearest one its model supports', async t => {
  const f = await fixture(t, [message('one')]);
  const submit = (requestId, thinkingLevel) => f.runtime.submit(f.id, { ...f.scope, requestId, content: 'x', definition: definition({ thinkingLevel }) });
  await assert.rejects(submit('extreme', 'extreme'), /invalid_thinking_level/);
  // The scripted model reasons, with pi-ai's standard levels: off to high.
  await wait(f.runtime, await submit('max', 'max'));
  assert.equal((await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx)).thinkingLevel, 'high');
});

test("one bot's tools never reach another bot's conversation; a new definition replaces the old from the next request", async t => {
  const f = await fixture(t, [message('one'), message('two'), message('three')]);
  const first = definition();
  await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'one', content: 'x', definition: first }));
  const { id: other } = await f.runtime.create({ ...f.scope, requestId: 'create-2' });
  const otherAgent = await (await f.runtime.harness.conversation(other, ctx)).agent(ctx);
  assert.equal(otherAgent.extensions.some(e => e.name.startsWith('bot.')), false);
  const second = definition({ tools: [], instructions: 'Changed.' });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'two', content: 'y', definition: second }));
  const agent = await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx);
  assert.deepEqual(agent.extensions.filter(e => e.name.startsWith('bot.')).map(e => e.name), [`bot.${second.digest}`]);
  assert.equal(agent.instructions, 'Changed.');
  // A restart reinstalls what conversations still run and drops the rest.
  await f.runtime.close();
  const reopened = await createRuntime(f.config, { ...f.deps, ...scriptedProvider([message('again')]) });
  t.after(() => reopened.close());
  assert.ok(reopened.registry.snapshot().extension(`bot.${second.digest}`));
  assert.equal(reopened.registry.snapshot().extension(`bot.${first.digest}`), undefined);
});

test('a waiting call survives a reopen; the doorbell re-asks Rails, whose decision becomes the result', async t => {
  const f = await fixture(t, [message(call('ask', { question: 'Tea?' }), { stopReason: 'toolUse' }), message('answered')]);
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'ask', content: 'ask', definition: definition() });
  const waiting = await until(async () => (await f.runtime.snapshot(f.id, f.scope)).pendingInputs[0]);
  assert.deepEqual(Object.keys(waiting).sort(), ['expiresAt', 'id', 'kind']);
  assert.equal((await f.runtime.snapshot(f.id, f.scope)).status, 'waiting');
  const [key] = f.rails.keys();
  await f.runtime.close();
  const rails = railsStandIn();
  const resumed = await createRuntime(f.config, { ...f.deps, invoke: rails.invoke, ...scriptedProvider([message('answered')]) });
  t.after(() => resumed.close());
  // The replayed call asked Rails again; Rails had not decided, so it waits.
  await until(async () => rails.calls.length === 1);
  rails.decide(key, { selections: ['Tea'] });
  await assert.rejects(resumed.wake(f.id, { actorId: 'bob', workspaceId: 'one', key }), /not_found/);
  assert.deepEqual(await resumed.wake(f.id, { ...f.scope, key }), { rung: true });
  assert.equal((await wait(resumed, sub)).status, 'done');
  assert.equal(rails.calls.length, 2);
  const snapshot = await resumed.snapshot(f.id, f.scope);
  assert.ok(snapshot.entries.some(e => e.role === 'toolResult' && e.content.includes('Tea')));
  assert.equal(snapshot.pendingInputs.length, 0);
});

test('without a ring, a waiting call asks Rails again after the re-check interval', async t => {
  const f = await fixture(t, [message(call('ask', { question: 'Tea?' }), { stopReason: 'toolUse' }), message('answered')], { limits: { recheckMs: 200 } });
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'ask', content: 'ask', definition: definition() });
  await until(async () => f.rails.calls.length === 1);
  f.rails.decide(f.rails.keys()[0], { selections: ['Coffee'] });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
  assert.equal(f.rails.calls.length, 2);
});

test('entries page the committed transcript after a cursor, with tool calls and results linked by call id', async t => {
  const f = await fixture(t, [message(call('note', { key: 'k' }), { stopReason: 'toolUse' }), message('saved')]);
  await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'note', content: 'save it', definition: definition() }));
  const all = await f.runtime.entries(f.id, f.scope);
  const roles = all.entries.map(e => e.role);
  assert.deepEqual(roles.filter(r => r !== 'system'), ['user', 'assistant', 'toolResult', 'assistant']);
  const asked = all.entries.find(e => e.toolCalls);
  const result = all.entries.find(e => e.role === 'toolResult');
  assert.equal(asked.toolCalls[0].name, 'note');
  assert.equal(result.toolCallId, asked.toolCalls[0].id);
  assert.equal(all.cursor, all.entries.at(-1).entryId);
  const middle = all.entries.find(e => e.role === 'toolResult').entryId;
  const later = await f.runtime.entries(f.id, f.scope, String(middle));
  assert.ok(later.entries.every(e => e.entryId > middle));
  assert.deepEqual((await f.runtime.entries(f.id, f.scope, String(all.cursor))).entries, []);
  await assert.rejects(f.runtime.entries(f.id, f.scope, 'x'), /invalid_cursor/);
  await assert.rejects(f.runtime.entries(f.id, { actorId: 'alice', workspaceId: 'two' }), /not_found/);
});

test('code mode: one script calls Rails tools in parallel, each an ordinary ledger call, and waits for a person like any call', async t => {
  const script = [
    "const [a, b] = await Promise.all([tools.note({ key: 'a' }), tools.note({ key: 'b' })]);",
    "const answer = await tools.ask({ question: 'Keep both?' });",
    "return [a, b, answer].join(' | ');"
  ].join('\n');
  const f = await fixture(t, [message(call('codemode', { code: script }), { stopReason: 'toolUse' }), message('done')]);
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'code', content: 'save two', definition: definition() });
  // Both notes, then the question, which waits for its doorbell.
  await until(async () => f.rails.keys().length === 1);
  const notes = f.rails.calls.filter(c => c.tool === 'note');
  assert.deepEqual(notes.map(c => c.arguments.key).sort(), ['a', 'b']);
  // A script's call is named under the code mode call; each is its own task.
  assert.ok(f.rails.calls.every(c => /\/c\d+$/.test(c.callId)));
  assert.equal(new Set(f.rails.calls.map(c => `${c.taskId}:${c.callId}`)).size, 3);
  const key = f.rails.keys()[0];
  f.rails.decide(key, { selections: ['yes'] });
  await f.runtime.wake(f.id, { ...f.scope, key });
  assert.equal((await wait(f.runtime, sub)).status, 'done');

  const { entries } = await f.runtime.entries(f.id, f.scope);
  const asked = entries.find(e => e.toolCalls);
  assert.deepEqual(asked.toolCalls.map(c => [c.name, c.arguments.code]), [['codemode', script]]);
  const result = entries.find(e => e.role === 'toolResult');
  assert.equal(result.toolName, 'codemode');
  assert.match(result.content, /"key":"a".*\|.*"key":"b".*\|.*"selections":\["yes"\]/s);
});

test('while a run streams, Rails gets sequenced whole-tail frames and a sync ping per committed entry', async t => {
  const frames = [], syncs = [];
  const f = await fixture(t, [message('a streamed answer of several words')], {
    limits: { frameIntervalMs: 20 },
    deps: { frame: async data => { frames.push(data); }, sync: async data => { syncs.push(data); } } });
  await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'stream', content: 'go', definition: definition() }));
  await until(async () => frames.at(-1)?.busy === false);
  assert.ok(frames.every((frame, index) => index === 0 || frame.seq > frames[index - 1].seq));
  assert.ok(frames.every(frame => frame.conversationId === String(f.id) && frame.actorId === 'alice' && frame.workspaceId === 'one'));
  assert.equal(frames.at(-1).failure, null);
  assert.deepEqual(frames.at(-1).tools, []);
  // The last frame carries the conversation's totals; the scripted model has no prices.
  const { usage } = frames.at(-1);
  assert.ok(usage.totalTokens > 0);
  assert.deepEqual(usage.cost, { estimatedTotal: null, basis: 'price_unavailable' });
  assert.ok(syncs.length >= 1);
});

test('a running shell command reaches Rails as it prints, the tail of each call, and nested calls under their script', async t => {
  const frames = [];
  const loop = 'for i in 1 2 3; do echo line$i; sleep 0.4; done';
  const script = `return await tools.bash({ command: ${JSON.stringify(loop)} });`;
  const f = await fixture(t, [message(call('bash', { command: loop }, { id: 'toolu_b' }), { stopReason: 'toolUse' }),
    message(call('codemode', { code: script }, { id: 'toolu_s' }), { stopReason: 'toolUse' }), message('done')],
    { execution: 'trusted-local-single-tenant', limits: { frameIntervalMs: 20 }, deps: { frame: async data => { frames.push(data); } } });
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'print', content: 'go', definition: definition({ computer: LOCAL_COMPUTER }) });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
  await until(async () => frames.at(-1)?.busy === false);

  const outputs = id => frames.flatMap(frame => frame.tools.filter(tool => tool.callId === id).map(tool => tool.output)).filter(Boolean);
  for (const id of ['toolu_b', 'toolu_s/c1']) {
    const seen = outputs(id);
    // A change in the output alone sends a frame: the tail grows while the text does not.
    assert.ok(seen.includes('line1\n') && seen.some(output => output.startsWith('line1\nline2')), `${id}: ${JSON.stringify(seen)}`);
    assert.ok(seen.every((output, index) => index === 0 || output.length >= seen[index - 1].length));
  }
  const nested = frames.flatMap(frame => frame.tools).find(tool => tool.callId === 'toolu_s/c1');
  assert.equal(nested.name, 'bash');
  // A model-issued call leaves the frames once it is done: its result is an entry.
  assert.ok(frames.every(frame => frame.tools.every(tool => tool.callId !== 'toolu_b' || tool.status !== 'done')));
});

test('each reply carries what it used; the tail of a long output is at most 4 KB', async t => {
  const frames = [];
  const f = await fixture(t, [message(call('bash', { command: 'head -c 9000 /dev/zero | tr "\\0" a; sleep 0.5' }), { stopReason: 'toolUse' }), message('done')],
    { execution: 'trusted-local-single-tenant', limits: { frameIntervalMs: 20 }, deps: { frame: async data => { frames.push(data); } } });
  assert.equal((await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'long', content: 'go', definition: definition({ computer: LOCAL_COMPUTER }) }))).status, 'done');
  await until(async () => frames.at(-1)?.busy === false);
  const longest = Math.max(...frames.flatMap(frame => frame.tools.map(tool => Buffer.byteLength(tool.output))));
  assert.equal(longest, 4096);
  const { entries } = await f.runtime.entries(f.id, f.scope);
  const replies = entries.filter(entry => entry.role === 'assistant');
  assert.equal(replies.length, 2);
  for (const reply of replies) {
    assert.deepEqual(Object.keys(reply.usage).sort(), ['cacheRead', 'cacheWrite', 'cost', 'input', 'output', 'totalTokens']);
    assert.equal(reply.usage.cost, 0);
  }
  assert.ok(entries.filter(entry => entry.role !== 'assistant').every(entry => entry.usage === undefined));
});

test('hard request bound stops at provider seam, not a swallowed hook exception', async t => {
  const f = await fixture(t, Array.from({ length: 10 }, () => message(call('read', { path: 'missing' }), { stopReason: 'toolUse' })),
    { limits: { maxRequests: 2 }, execution: 'trusted-local-single-tenant' });
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'loop', content: 'loop' });
  const result = await wait(f.runtime, sub);
  assert.equal(result.status, 'unanswered');
  assert.equal(f.provider.faux.state.callCount, 2);
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 2);
});

test('the bounds are per run: the next message after a run hit them gets a fresh budget', async t => {
  const f = await fixture(t, [message(call('read', { path: 'missing' }), { stopReason: 'toolUse' }),
    message(call('read', { path: 'missing' }), { stopReason: 'toolUse' }), message('second answer')],
    { limits: { maxRequests: 2 }, execution: 'trusted-local-single-tenant' });
  assert.equal((await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'one', content: 'loop' }))).status, 'unanswered');
  const second = await wait(f.runtime, await f.runtime.submit(f.id, { ...f.scope, requestId: 'two', content: 'again' }));
  assert.notEqual(second.status, 'unanswered');
  assert.equal(f.provider.faux.state.callCount, 3);
  assert.equal((await f.runtime.harness.snapshot(App, f.id, ctx)).bounds.requests, 1);
});

test('HTTP: bearer required, admission, and the entries route serves the committed transcript', async t => {
  const cwd = await privateDir('omakase-http-');
  const provider = scriptedProvider([message('scripted greeting')]);
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...provider, authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const address = await server.listen(0);
  const base = `http://127.0.0.1:${address.port}`;
  assert.equal((await fetch(`${base}/up`)).status, 200);
  assert.equal((await fetch(`${base}/v1/conversations`, { method: 'POST', body: '{}' })).status, 401);
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  assert.equal((await fetch(`${base}/v1/models`)).status, 401);
  const catalogue = await (await fetch(`${base}/v1/models`, { headers })).json();
  assert.deepEqual(catalogue.models.map(({ id, thinkingLevels, images }) => ({ id, thinkingLevels, images })),
    [{ id: 'fixture/scripted', thinkingLevels: ['off', 'minimal', 'low', 'medium', 'high'], images: true }]);
  assert.equal(typeof catalogue.models[0].contextWindow, 'number');
  const response = await fetch(`${base}/v1/conversations`, { method: 'POST', headers,
    body: JSON.stringify({ actorId: 'alice', workspaceId: 'one', requestId: 'create' }) });
  const { id } = await response.json();
  assert.ok(id);
  const entries = await fetch(`${base}/v1/conversations/${id}/entries?actorId=alice&workspaceId=one`, { headers });
  assert.deepEqual(await entries.json(), { entries: [], cursor: null, more: false });
  assert.equal((await fetch(`${base}/v1/conversations/${id}/events?actorId=alice&workspaceId=one`, { headers })).status, 404);
  assert.equal((await fetch(`${base}/v1/mcp-grants`, { method: 'POST', headers, body: '{}' })).status, 404);
});

test('A04 default mode omits read/write/edit/bash and the execution environment; trusted mode needs explicit opt-in', async t => {
  const f = await fixture(t, [message(call('bash', { command: 'touch escaped' }), { stopReason: 'toolUse' }), message('done')]);
  assert.equal(f.runtime.execution, 'none');
  const names = f.runtime.registry.snapshot().tools().map(row => row.tool.name);
  for (const name of ['read', 'write', 'edit', 'bash']) assert.equal(names.includes(name), false);
  const agent = await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx);
  assert.equal(agent.tools.some(tool => ['read', 'write', 'edit', 'bash'].includes(tool.name)), false);
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'escape', content: 'shell' });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
  const snapshot = await f.runtime.snapshot(f.id, f.scope);
  assert.equal(snapshot.entries.find(e => e.role === 'toolResult').isError, true);
  await assert.rejects(readFile(join(f.cwd, 'escaped')));
  for (const execution of ['trusted', 'local', true, 'TRUSTED-LOCAL-SINGLE-TENANT']) {
    await assert.rejects(createRuntime({ ...f.config, storePath: join(f.cwd, `mode-${String(execution)}.sqlite`), execution }, f.deps), /invalid_execution_mode/);
  }
  const trustedPath = join(f.cwd, 'trusted.sqlite');
  const trusted = await createRuntime({ ...f.config, storePath: trustedPath, execution: 'trusted-local-single-tenant' }, f.deps);
  t.after(() => trusted.close());
  const trustedNames = trusted.registry.snapshot().tools().map(row => row.tool.name);
  for (const name of ['read', 'write', 'edit', 'bash']) assert.ok(trustedNames.includes(name));
});

test('a bot without a computer gets no file or shell tools, even where the sidecar offers one; an unoffered computer is refused', async t => {
  const f = await fixture(t, [message(call('bash', { command: 'touch escaped' }), { stopReason: 'toolUse' }), message('done')],
    { execution: 'trusted-local-single-tenant' });
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'none', content: 'shell', definition: definition({ computer: null }) });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
  const agent = await (await f.runtime.harness.conversation(f.id, ctx)).agent(ctx);
  assert.equal(agent.tools.some(tool => ['read', 'write', 'edit', 'bash'].includes(tool.name)), false);
  assert.equal((await f.runtime.snapshot(f.id, f.scope)).entries.find(e => e.role === 'toolResult').isError, true);
  await assert.rejects(stat(join(f.cwd, 'conversations', String(f.id), 'escaped')));

  const sprite = definition({ computer: { provider: 'sprites', name: 'ss-bot-1' } });
  await assert.rejects(f.runtime.submit(f.id, { ...f.scope, requestId: 'sprite', content: 'x', definition: sprite }), /computer_unavailable/);
  await assert.rejects(f.runtime.submit(f.id, { ...f.scope, requestId: 'bad', content: 'x', definition: definition({ computer: { provider: 'docker' } }) }), /invalid_computer/);
  const plain = await fixture(t);
  await assert.rejects(plain.runtime.submit(plain.id, { ...plain.scope, requestId: 'local', content: 'x', definition: definition({ computer: LOCAL_COMPUTER }) }), /computer_unavailable/);
});

test('snapshot DTO exposes no task/call identity, scope binding or other workspace data', async t => {
  const f = await fixture(t, [message(call('ask', { question: 'Tea?' }), { stopReason: 'toolUse' }), message('done')]);
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'ask', content: 'ask', definition: definition() });
  const snapshot = await until(async () => { const s = await f.runtime.snapshot(f.id, f.scope); return s.pendingInputs[0] && s; });
  const text = JSON.stringify(snapshot);
  for (const leak of ['taskId', 'callId', 'actorId', 'workspaceId', 'cwd', f.cwd, 'rings', 'byTaskId', 'toolCallId']) assert.equal(text.includes(leak), false, leak);
  await assert.rejects(f.runtime.snapshot(f.id, { actorId: 'alice', workspaceId: 'two' }), /not_found/);
  f.rails.decide(f.rails.keys()[0], { selections: [] });
  await f.runtime.wake(f.id, { ...f.scope, key: f.rails.keys()[0] });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
});

test('unix socket listen: mode 0600, bearer API over the socket, stale socket replaced only by the owner', async t => {
  const cwd = await privateDir('omakase-socket-');
  const socketPath = join(cwd, 'agent.sock');
  const deps = { ...scriptedProvider([message('over the socket')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) };
  const config = { storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token', socketPath };
  const request = (path, body) => new Promise((resolve, reject) => {
    const req = http.request({ socketPath, path, method: body ? 'POST' : 'GET',
      headers: { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' } }, res => {
      let data = ''; res.on('data', c => { data += c; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
    });
    req.on('error', reject); req.end(body ? JSON.stringify(body) : undefined);
  });
  // A stale socket file left by a crashed owner.
  const stale = http.createServer(); await new Promise(r => stale.listen(socketPath, r));
  await new Promise(r => stale.close(r));
  await writeFile(join(cwd, 'not-a-socket'), 'x');
  const blocked = await createServer({ ...config, storePath: join(cwd, 'other.sqlite'), socketPath: join(cwd, 'not-a-socket') }, deps);
  await assert.rejects(blocked.listen(), /socket_path_occupied/);
  await blocked.close();
  const server = await createServer(config, deps);
  t.after(() => server.close());
  assert.deepEqual(await server.listen(), { socketPath });
  assert.equal((await stat(socketPath)).mode & 0o777, 0o600);
  assert.equal((await request('/up')).status, 200);
  const { body } = await request('/v1/conversations', { actorId: 'alice', workspaceId: 'one', requestId: 'socket' });
  assert.ok(body.id);
  // A second sidecar on the same store is not ready and does not take the socket.
  const rival = await createServer(config, deps);
  assert.equal(rival.readiness().reason, 'store_already_owned');
  await assert.rejects(rival.listen(), /EADDRINUSE/);
  await rival.close();
  assert.equal((await request('/up')).status, 200);
});
