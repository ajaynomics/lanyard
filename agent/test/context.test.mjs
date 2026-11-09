// PARITY.md round 2: summarising at about 262k tokens, /compact, the
// history as pi's session file, and the agent's notes file. Scripted models and
// local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { writeFile, symlink, mkdir } from 'node:fs/promises';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { LiveDoc } from '@earendil-works/pi-durable';
import { createRuntime, compactionOverride, compactAtOf, failureReason, entryView, DEFAULT_COMPACTION, COMPACT_AT_TOKENS } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { sessionFile } from '../session-file.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall } from './scripted-provider.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { eventually, privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
const SUMMARISER = 'context summarization assistant';
const summarising = context => JSON.stringify(context.messages).includes(SUMMARISER);

async function setup(t, responses, { config = {}, model, deps = {} } = {}) {
  const cwd = await privateDir('omakase-context-');
  const provider = scriptedProvider(responses, model ? { model } : {});
  const frames = [];
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), limits: { maxRetries: 0, frameIntervalMs: 5 }, ...config }, {
    ...provider, authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    invoke: async () => ({ status: 'done', result: {} }), frame: async payload => { frames.push(payload); }, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId, content = requestId, extra = {}) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content, ...extra });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run, frames };
}

// ---- 15: compaction at about 262k ----------------------------------------------------------------

test('a large window blocks at 262,144 tokens; a background summary starts about 229k; a small window keeps Durable\'s reserve', () => {
  const blockAt = window => window - (compactionOverride(window, DEFAULT_COMPACTION)?.reserveTokens ?? DEFAULT_COMPACTION.reserveTokens);
  assert.equal(COMPACT_AT_TOKENS, 262144);
  assert.deepEqual(compactionOverride(1048576, DEFAULT_COMPACTION), { reserveTokens: 786432 });
  assert.equal(blockAt(1048576), 262144);
  assert.equal(blockAt(1048576) - DEFAULT_COMPACTION.backgroundTokens, 229376);
  assert.deepEqual(compactionOverride(400000, DEFAULT_COMPACTION), { reserveTokens: 137856 });
  assert.equal(compactionOverride(200000, DEFAULT_COMPACTION), undefined);
  assert.equal(blockAt(200000), 183616);
  // pi-ai's Claude 5.5 windows are 1,000,000 tokens.
  assert.deepEqual(compactionOverride(1000000, DEFAULT_COMPACTION), { reserveTokens: 737856 });
  assert.deepEqual([1048576, 400000, 200000].map(window => compactAtOf(window, DEFAULT_COMPACTION)), [262144, 262144, 183616]);
  assert.equal(compactAtOf(1048576, { ...DEFAULT_COMPACTION, enabled: false }), null);
  assert.equal(compactAtOf(1048576, DEFAULT_COMPACTION, 100000), 100000);
});

test('the harness runs each route\'s override, and GET /v1/models says where each model summarises', async t => {
  const f = await setup(t, [], { model: { contextWindow: 1048576 } });
  assert.deepEqual(f.runtime.compaction.modelOverrides, { 'fixture/scripted': { reserveTokens: 786432 } });
  assert.equal(f.runtime.compaction.backgroundTokens, 32768);
  assert.equal(f.runtime.catalogue().models[0].compactAt, 262144);
  const small = await setup(t, [], { model: { contextWindow: 200000 } });
  assert.deepEqual(small.runtime.compaction.modelOverrides, {});
  assert.equal(small.runtime.catalogue().models[0].compactAt, 183616);
  await assert.rejects(setup(t, [], { config: { compactAtTokens: 12.5 } }), /invalid_compact_at/);
});

test('every Claude route the sidecar serves, subscription and API key alike, blocks at 262k', async t => {
  const cwd = await privateDir('omakase-context-routes-');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    claudeSubscription: { file: join(cwd, 'claude.json'), vaultKey: 'a'.repeat(64), environment: 'test' } },
  { authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { modelOverrides } = server.runtime.compaction;
  for (const provider of ['anthropic', 'anthropic-api']) {
    assert.deepEqual(modelOverrides[`${provider}/claude-opus-5-5`], { reserveTokens: 737856 }, provider);
    assert.deepEqual(modelOverrides[`${provider}/claude-sonnet-5-5`], { reserveTokens: 737856 }, provider);
    assert.equal(modelOverrides[`${provider}/claude-haiku-4-5`], undefined, provider);
  }
  const views = Object.fromEntries(server.runtime.catalogue().models.map(model => [model.id, model.compactAt]));
  assert.equal(views['anthropic-api/claude-opus-5-5'], 262144);
  assert.equal(views['anthropic/claude-haiku-4-5'], 183616);
});

test('/compact is repeatable by request id, refuses changed or overlong instructions, and passes the instructions to the summary', async t => {
  const seen = [];
  const f = await setup(t, [message('one'), message('two'), context => { seen.push(JSON.stringify(context.messages)); return message('SUMMARY: numbers'); }],
    { config: { compaction: { keepRecentTokens: 1 } } });
  for (const words of ['first', 'second']) assert.equal((await f.run(words)).status, 'done');
  const input = { ...scope, requestId: 'c-1', instructions: 'Keep the numbers' };
  const first = await f.runtime.compact(f.id, input);
  assert.deepEqual(await f.runtime.compact(f.id, input), first);
  await assert.rejects(f.runtime.compact(f.id, { ...input, instructions: 'Keep the words' }), /request_conflict/);
  await assert.rejects(f.runtime.compact(f.id, { ...input, requestId: 'c-2', instructions: 'x'.repeat(4097) }), /invalid_instructions/);
  await assert.rejects(f.runtime.compact(f.id, { ...input, actorId: 'bob' }), /not_found/);
  await eventually(async () => (await f.runtime.entries(f.id, scope)).entries.some(entry => entry.role === 'summary'));
  assert.equal(seen.length, 1);
  assert.match(seen[0], /Keep the numbers/);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.deepEqual([view.compaction, view.compactionFailed], [null, null]);
});

test('/compact asked twice at once, as a retry after a timeout would, makes one summary', async t => {
  const seen = [];
  const summary = context => { seen.push(context); return message('SUMMARY: numbers'); };
  const f = await setup(t, [message('one'), message('two'), summary, summary], { config: { compaction: { keepRecentTokens: 1 } } });
  for (const words of ['first', 'second']) assert.equal((await f.run(words)).status, 'done');
  const input = { ...scope, requestId: 'c-1' };
  const [first, again] = await Promise.all([f.runtime.compact(f.id, input), f.runtime.compact(f.id, input)]);
  assert.deepEqual(again, first);
  await eventually(async () => (await f.runtime.entries(f.id, scope)).entries.some(entry => entry.role === 'summary'));
  await new Promise(resolve => setTimeout(resolve, 200));
  assert.equal(seen.length, 1);
});

test('frames say a summary is running, then that it failed, without the provider\'s words', async t => {
  let release;
  const held = new Promise(resolve => { release = resolve; });
  const f = await setup(t, [message('one'), message('two'), async () => {
    await held;
    return message('', { stopReason: 'error', errorMessage: 'provider secret words' });
  }], { config: { compaction: { keepRecentTokens: 1 } } });
  for (const words of ['first', 'second']) assert.equal((await f.run(words)).status, 'done');
  await f.runtime.compact(f.id, { ...scope, requestId: 'c-1' });
  await eventually(() => f.frames.some(frame => frame.compaction?.trigger === 'manual'));
  assert.equal((await f.runtime.snapshot(f.id, scope)).compaction.trigger, 'manual');
  release();
  await eventually(() => f.frames.some(frame => frame.compactionFailed?.trigger === 'manual' && frame.compaction === null));
  const failed = f.frames.findLast(frame => frame.compactionFailed);
  assert.equal(failed.busy, false);
  assert.deepEqual(failed.compactionFailed, { trigger: 'manual' });
  assert.doesNotMatch(JSON.stringify(f.frames), /provider secret words/);
  assert.match((await f.runtime.harness.snapshot(LiveDoc, f.id, ctx)).compactionFailure.error, /provider secret words/);
  const view = await f.runtime.snapshot(f.id, scope);
  assert.deepEqual(view.compactionFailed, { trigger: 'manual' });
  assert.doesNotMatch(JSON.stringify(view), /provider secret words/);
  // A request that waited for a summary that failed.
  assert.equal(failureReason({ reason: 'model_error', detail: 'Compaction failed: 429 rate limited' }), 'compaction_failed');
  assert.equal(failureReason({ reason: 'model_error', detail: '429 rate limited' }), 'rate_limited');
});

test('POST /v1/conversations/:id/compactions answers 202 with the id, 409 and 422 as the contract says', async t => {
  const cwd = await privateDir('omakase-context-http-');
  const provider = scriptedProvider([message('one'), message('SUMMARY')]);
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...provider, authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const { id } = await server.runtime.create({ ...scope, requestId: 'create' });
  const post = body => fetch(`http://127.0.0.1:${port}/v1/conversations/${id}/compactions`, { method: 'POST',
    headers: { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' }, body: JSON.stringify({ ...scope, ...body }) });
  const first = await post({ requestId: 'c-1' });
  assert.equal(first.status, 202);
  const answer = await first.json();
  assert.equal(typeof answer.id, 'string');
  assert.deepEqual(await (await post({ requestId: 'c-1' })).json(), answer);
  assert.equal((await post({ requestId: 'c-1', instructions: 'other' })).status, 409);
  const long = await post({ requestId: 'c-2', instructions: 'x'.repeat(4097) });
  assert.deepEqual([long.status, await long.json()], [422, { error: 'invalid_instructions' }]);
});

test('a reply says when its request began and which model ran it, for telling a prompt cache miss', () => {
  const usage = { input: 10, output: 5, cacheRead: 9000, cacheWrite: 20, totalTokens: 9035, cost: { total: 0 } };
  const [reply] = entryView({ id: 7, kind: 'pi.assistant', model: [{ role: 'assistant', content: [{ type: 'text', text: 'Hi' }],
    provider: 'anthropic', model: 'claude-haiku-5-5', usage, stopReason: 'stop', timestamp: 1730000000000 }] });
  assert.equal(reply.at, 1730000000000);
  assert.equal(reply.model, 'anthropic/claude-haiku-5-5');
  assert.equal(reply.usage.cacheRead, 9000);
  const [person] = entryView({ id: 8, kind: 'pi.user', model: [{ role: 'user', content: 'Hello', timestamp: 1730000001000 }] });
  assert.equal(person.at, undefined);
});

// ---- 16: the history as pi's session file ---------------------------------------------------------

const PIXEL = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

test('the session file: a v3 header, the name, the instructions, the model, then one linear chain', async () => {
  const usage = { input: 10, output: 5, cacheRead: 0, cacheWrite: 0, totalTokens: 1500, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
  const entries = [
    { id: 1, kind: 'pi.system', model: [{ role: 'system', content: '', sections: { omakase: 'x' }, timestamp: 1000 }] },
    { id: 2, kind: 'pi.user', model: [{ role: 'user', content: [{ type: 'text', text: 'Look' }, { type: 'image', data: PIXEL, mimeType: 'image/png' }], timestamp: 2000 }] },
    { id: 3, kind: 'pi.assistant', model: [{ role: 'assistant', content: [
      { type: 'thinking', thinking: 'Hmm', thinkingSignature: 'opaque-signature' },
      { type: 'thinking', thinking: '', thinkingSignature: 'opaque-redacted', redacted: true },
      { type: 'toolCall', id: 'call_1', name: 'note', arguments: { key: 'k' } }], api: 'x', provider: 'fixture', model: 'scripted', usage, stopReason: 'toolUse', timestamp: 3000 }] },
    { id: 4, kind: 'pi.tool-result', model: [{ role: 'toolResult', toolCallId: 'call_1', toolName: 'note', content: [{ type: 'text', text: 'saved' }], isError: false, timestamp: 4000 }] },
    { id: 5, kind: 'pi.compaction', head: 3, model: [{ role: 'user', content: [{ type: 'text',
      text: 'The conversation history before this point was compacted into the following summary:\n\n<summary>\nThey looked at a picture.\n</summary>' }], timestamp: 5000 }] },
    { id: 6, kind: 'pi.user', model: [{ role: 'user', content: 'And now?', timestamp: 6000 }] }
  ];
  const lines = await Array.fromAsync(sessionFile(entries, { id: 'session-1', title: 'Plan a trip', instructions: 'Be brief.', model: { provider: 'fixture', modelId: 'scripted' } }));
  assert.deepEqual(lines[0], { type: 'session', version: 3, id: 'session-1', timestamp: new Date(1000).toISOString(), cwd: '.' });
  assert.deepEqual(lines.slice(1).map(line => line.type), ['session_info', 'message', 'model_change', 'message', 'message', 'message', 'compaction', 'message']);
  assert.equal(lines[1].name, 'Plan a trip');
  assert.deepEqual(lines[2].message, { role: 'system', content: 'Be brief.', timestamp: 1000 });
  assert.deepEqual([lines[3].provider, lines[3].modelId], ['fixture', 'scripted']);
  // One chain, each line's parent the line before it.
  lines.slice(1).forEach((line, index) => assert.equal(line.parentId, index === 0 ? null : lines[index].id));
  assert.equal(new Set(lines.slice(1).map(line => line.id)).size, lines.length - 1);
  const [person, reply, result, summary] = lines.slice(4);
  assert.deepEqual(person.message.content[1], { type: 'image', data: PIXEL, mimeType: 'image/png' });
  assert.deepEqual(reply.message.content, [{ type: 'thinking', thinking: 'Hmm' }, { type: 'toolCall', id: 'call_1', name: 'note', arguments: { key: 'k' } }]);
  assert.equal(reply.message.usage.totalTokens, 1500);
  assert.doesNotMatch(JSON.stringify(lines), /opaque/);
  assert.deepEqual([result.message.role, result.message.toolCallId], ['toolResult', 'call_1']);
  assert.deepEqual([summary.summary, summary.firstKeptEntryId, summary.tokensBefore], ['They looked at a picture.', reply.id, 1500]);
  assert.deepEqual(summary.systemMessage, { role: 'system', content: 'Be brief.', timestamp: 1000 });
  assert.equal(new Date(summary.timestamp).getTime(), 5000);
});

test('GET /v1/conversations/:id/export streams the history, pictures, calls and summaries included; a branch carries its parent\'s', async t => {
  const cwd = await privateDir('omakase-context-export-');
  const provider = scriptedProvider([message([fauxToolCall('note', { key: 'k' })], { stopReason: 'toolUse' }), message('Saved.'), message('Second.'),
    context => summarising(context) ? message('SUMMARY: a note was saved.') : message('Third.'), message('Fourth.')]);
  const rails = railsStandIn();
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token',
    compaction: { keepRecentTokens: 1 } },
  { ...provider, authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice', cwd }), invoke: rails.invoke });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const { runtime } = server;
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const agentDefinition = definition({ instructions: 'You keep notes.' });
  const send = async (requestId, content) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content, definition: agentDefinition });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  assert.equal((await send('one', [{ type: 'text', text: 'Note this' }, { type: 'image', data: PIXEL, mimeType: 'image/png' }])).status, 'done');
  assert.equal((await send('two', 'Again')).status, 'done');
  await runtime.compact(id, { ...scope, requestId: 'c-1' });
  await eventually(async () => (await runtime.entries(id, scope)).entries.some(entry => entry.role === 'summary'));
  const download = async (conversation, query = '&title=Notes%20%E2%9C%93', actor = 'alice') => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/conversations/${conversation}/export?actorId=${actor}&workspaceId=one${query}`,
      { headers: { authorization: 'Bearer synthetic-sidecar-token-123' } });
    return { response, lines: response.ok ? (await response.text()).trimEnd().split('\n').map(line => JSON.parse(line)) : null };
  };
  const { response, lines } = await download(id);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^application\/jsonl/);
  assert.equal(lines[0].version, 3);
  assert.equal(lines[0].cwd, '.');
  assert.equal(lines.find(line => line.type === 'session_info').name, 'Notes ✓');
  assert.equal(lines.find(line => line.message?.role === 'system').message.content, 'You keep notes.');
  assert.deepEqual(lines.find(line => line.type === 'model_change'), { ...lines.find(line => line.type === 'model_change'), provider: 'fixture', modelId: 'scripted' });
  const messages = lines.filter(line => line.type === 'message').map(line => line.message);
  assert.ok(messages.some(m => m.role === 'user' && m.content.some?.(block => block.type === 'image' && block.data === PIXEL)));
  assert.ok(messages.some(m => m.role === 'assistant' && m.content.some(block => block.type === 'toolCall' && block.name === 'note')));
  assert.ok(messages.some(m => m.role === 'toolResult' && m.toolName === 'note'));
  assert.ok(messages.filter(m => m.role === 'assistant').every(m => m.usage));
  const compaction = lines.find(line => line.type === 'compaction');
  assert.equal(compaction.summary, 'SUMMARY: a note was saved.');
  assert.ok(lines.some(line => line.id === compaction.firstKeptEntryId));
  lines.slice(2).forEach((line, index) => assert.equal(line.parentId, lines[index + 1].id));
  assert.doesNotMatch(JSON.stringify(lines), new RegExp(cwd));

  const history = (await (await runtime.harness.conversation(id, ctx)).entries({ order: 'ascending' }, 100, undefined, ctx)).items;
  const branch = await runtime.fork(id, { ...scope, requestId: 'b-1', at: history.find(entry => entry.kind === 'pi.compaction').id });
  const branched = await download(branch.id, '');
  assert.equal(branched.lines[0].parentSession, undefined);
  assert.equal(branched.lines.some(line => line.type === 'session_info'), false);
  assert.deepEqual(branched.lines.filter(line => line.type === 'message' && line.message.role === 'user').map(line => line.message.content),
    lines.filter(line => line.type === 'message' && line.message.role === 'user').map(line => line.message.content));
  assert.ok(branched.lines.some(line => line.type === 'compaction'));

  assert.equal((await download(id, '', 'bob')).response.status, 404);
});

// ---- 14: the notes file ---------------------------------------------------------------------------

async function notesSetup(t, { notesFile = true, deps = {} } = {}) {
  const f = await setup(t, Array.from({ length: 8 }, (_, n) => message(`answer ${n}`)), { config: { execution: 'trusted-local-single-tenant' }, deps });
  const agentDefinition = definition({ instructions: 'You keep notes.', computer: { provider: 'local', notesFile } });
  const instructions = async () => JSON.stringify((await (await f.runtime.harness.conversation(f.id, ctx)).context(ctx)).messages.filter(m => m.role === 'system'));
  // The agent's own folder, <agent folder>/<conversation id>, holds its notes file.
  const home = join(f.cwd, String(f.id));
  await mkdir(home, { recursive: true });
  return { ...f, home, agentDefinition, instructions, say: (requestId, extra = {}) => f.run(requestId, requestId, { definition: agentDefinition, ...extra }) };
}
// Counts the times a conversation is configured.
function countConfigures(runtime) {
  const counter = { count: 0 };
  const open = runtime.harness.conversation.bind(runtime.harness);
  runtime.harness.conversation = async (...args) => {
    const conversation = await open(...args);
    const configure = conversation?.configure.bind(conversation);
    if (conversation) conversation.configure = async (...rest) => { counter.count++; return configure(...rest); };
    return conversation;
  };
  return counter;
}

test('the notes file is read when a run starts, and an unchanged file does not reconfigure the conversation', async t => {
  const f = await notesSetup(t);
  await writeFile(join(f.home, 'AGENTS.md'), 'Maya likes window seats.\n');
  assert.equal((await f.say('one')).status, 'done');
  assert.match(await f.instructions(), /You keep notes\.\\n\\n# Notes file \(AGENTS\.md\)\\n\\nMaya likes window seats\./);
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).notesFile, { bytes: 25 });
  await eventually(() => f.frames.some(frame => !frame.busy && frame.notesFile?.bytes === 25));

  const configures = countConfigures(f.runtime);
  assert.equal((await f.say('two')).status, 'done');
  assert.equal(configures.count, 0);

  await writeFile(join(f.home, 'AGENTS.md'), 'Maya likes aisle seats now.\n');
  assert.equal((await f.say('three')).status, 'done');
  assert.equal(configures.count, 1);
  assert.match(await f.instructions(), /aisle seats/);
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).notesFile, { bytes: 28 });
});

test('a notes file over 32 KB is not read and the agent is told; no file adds nothing; off means not read', async t => {
  const big = await notesSetup(t);
  await writeFile(join(big.home, 'AGENTS.md'), `secret-${'x'.repeat(40000)}`);
  assert.equal((await big.say('one')).status, 'done');
  const told = await big.instructions();
  assert.match(told, /# Notes file \(AGENTS\.md\)/);
  assert.match(told, /40 KB, over the 32 KB that is read, so it was not read/);
  assert.doesNotMatch(told, /secret-/);
  assert.deepEqual((await big.runtime.snapshot(big.id, scope)).notesFile, { bytes: 40007 });

  const none = await notesSetup(t);
  assert.equal((await none.say('one')).status, 'done');
  assert.doesNotMatch(await none.instructions(), /Notes file/);
  assert.equal((await none.runtime.snapshot(none.id, scope)).notesFile, null);

  const off = await notesSetup(t, { notesFile: false });
  await writeFile(join(off.home, 'AGENTS.md'), 'Never read.\n');
  assert.equal((await off.say('one')).status, 'done');
  assert.doesNotMatch(await off.instructions(), /Never read|Notes file/);
  assert.equal((await off.runtime.snapshot(off.id, scope)).notesFile, null);
});

test('a notes file that is a link is not followed', async t => {
  const f = await notesSetup(t);
  await writeFile(join(f.home, 'elsewhere.md'), 'Not the notes.\n');
  await symlink(join(f.home, 'elsewhere.md'), join(f.home, 'AGENTS.md'));
  assert.equal((await f.say('one')).status, 'done');
  assert.doesNotMatch(await f.instructions(), /Not the notes/);
});
