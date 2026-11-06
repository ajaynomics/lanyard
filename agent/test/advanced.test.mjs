import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { obj, num, str } from '@earendil-works/pi-schema';
import { defineExtension, defineTool, defineTask } from '@earendil-works/pi-durable';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, shellIsolationAvailable, liveTaskGraph } from '../runtime.mjs';
import { App, digest } from '../state.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';
const scope = { actorId: 'alice', workspaceId: 'one' };
async function setup(t, responses, config = {}, deps = {}) {
  const cwd = await privateDir('omakase-advanced-');
  const provider = scriptedProvider(responses);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...provider,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    railsEffect: async effect => ({ noteId: 1, ...effect.arguments }), ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId = 'request') => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content: 'manufactured fixture' });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run };
}

test('A12 exact argument session grants are bounded; changed args reask; denial has no effect', async t => {
  const effects = [];
  const note = body => message(call('rails_note', { key: 'fixture', body }), { stopReason: 'toolUse' });
  const f = await setup(t, [note('same'), note('same'), note('changed'), message('done')], {}, {
    railsEffect: async effect => {
      const { digest: hash, ...payload } = effect;
      assert.equal(hash, digest(payload));
      effects.push(payload);
      return { noteId: effects.length, ...effect.arguments };
    }
  });
  const pending = f.run();
  const first = await eventually(async () => (await f.runtime.snapshot(f.id, scope)).pendingInputs[0]);
  assert.equal(first.tool, 'rails_note');
  await assert.rejects(f.runtime.answer(f.id, first.id, { ...scope, answer: { decision: 'once', digest: 'wrong' } }), /invalid_approval/);
  await f.runtime.answer(f.id, first.id, { ...scope, answer: { decision: 'approve', scope: 'session', uses: 2, digest: first.digest } });
  const next = await eventually(async () => {
    const requests = (await f.runtime.snapshot(f.id, scope)).pendingInputs;
    return requests.find(r => r.id !== first.id);
  });
  assert.equal(effects.length, 2);
  assert.equal(next.arguments.body, 'changed');
  await f.runtime.answer(f.id, next.id, { ...scope, answer: { decision: 'deny', digest: next.digest } });
  assert.equal((await pending).status, 'done');
  assert.equal(effects.length, 2);
  const conversation = await f.runtime.harness.conversation(f.id, ctx);
  const entries = await conversation.entries({ order: 'descending' }, 1, undefined, ctx);
  const fork = await conversation.fork(entries.items[0].id, { ownership: { kind: 'ownerless' } }, ctx);
  const forkDoc = await f.runtime.harness.snapshot(App, fork.id, ctx);
  assert.deepEqual(forkDoc.grants, {});
  assert.equal(forkDoc.actorId, null);
});

const structured = defineExtension({ name: 'fixture.structured', tools: [
  defineTool({ name: 'fx_add', description: 'Add two numbers', parameters: obj({ a: num(), b: num() }),
    structuredOutputSchema: obj({ sum: num() }), replay: 'safe',
    execute: async args => ({ output: [{ type: 'text', text: String(args.a + args.b) }], structuredOutput: { sum: args.a + args.b } }) }),
  defineTool({ name: 'fx_fail', description: 'Always fails', parameters: obj({}), replay: 'safe',
    execute: async () => { throw new Error('fixture_nested_failure'); } })] });
// Codemode's published result is a status preamble followed by the script output.
const scriptOutput = content => { assert.match(content, /^Script completed\n/); return JSON.parse(content.slice(content.indexOf('Output:\n') + 8)); };
const codemodeResults = async f => (await f.runtime.snapshot(f.id, scope)).entries.filter(e => e.role === 'toolResult' && e.toolName === 'codemode');

test('A16 actual native codemode composes structured tools; no models helper or recursive scripts', async t => {
  const compose = 'const x = await tools.fx_add({a:1,b:2}); const y = await tools.fx_add({a:x.sum,b:10}); let err; ' +
    'try { await tools.fx_fail({}); } catch (e) { err = String(e.message); } ' +
    'text(JSON.stringify({ sum: y.sum, err, models: typeof models, recursive: "codemode" in tools, workflow: "workflow" in tools, bash: "bash" in tools }));';
  const f = await setup(t, [message(call('codemode', { code: compose }), { stopReason: 'toolUse' }),
    message(call('codemode', { code: 'const = ;' }), { stopReason: 'toolUse' }),
    message(call('codemode', { code: '// @options: {"timeout_ms": 100}\nwhile (true) {}' }), { stopReason: 'toolUse' }),
    message(call('codemode', { code: '// @options: {"max_output_tokens": 20}\ntext("y".repeat(20000));' }), { stopReason: 'toolUse' }),
    message('done')], {}, { extensions: [structured] });
  assert.equal(f.runtime.registry.snapshot().tools().some(row => row.tool.name.startsWith('pi.codemode.')), false);
  assert.equal((await f.run()).status, 'done');
  const [composed, malformed, timedOut, bounded] = await codemodeResults(f);
  const value = scriptOutput(composed.content);
  assert.equal(value.sum, 13);
  assert.match(value.err, /fixture_nested_failure/);
  assert.equal(value.models, 'undefined');
  assert.equal(value.recursive, false);
  assert.equal(value.workflow, false);
  assert.equal(value.bash, false);
  assert.equal(composed.isError, undefined);
  assert.equal(malformed.isError, true);
  assert.equal(timedOut.isError, true);
  assert.match(timedOut.content, /time/i);
  assert.ok(bounded.content.length < 2000, `bounded output ${bounded.content.length}`);
  // Nested calls are actual Durable tool tasks with their own records.
  const conversation = await f.runtime.harness.conversation(f.id, ctx);
  const entries = (await conversation.entries({ order: 'ascending' }, 1000, undefined, ctx)).items;
  const details = entries.filter(e => e.kind === 'pi.tool-result').map(e => e.model?.[0]?.details).find(d => d?.calls);
  assert.deepEqual(details.calls.map(c => [c.name, c.status]), [['fx_add', 'ok'], ['fx_add', 'ok'], ['fx_fail', 'error']]);
});

test('A16 trusted mode: codemode composes structured bash results', async t => {
  const code = 'const a = await tools.bash({command:"printf fixture"}); const b = await tools.bash({command:"exit 7"}); text(JSON.stringify({ a: a.output, b: b.exitCode }));';
  const f = await setup(t, [message(call('codemode', { code }), { stopReason: 'toolUse' }), message('done')], { execution: 'trusted-local-single-tenant' });
  assert.equal((await f.run()).status, 'done');
  const [result] = await codemodeResults(f);
  assert.deepEqual(scriptOutput(result.content), { a: 'fixture', b: 7 });
});

test('A14 staged native owned tasks pass actual persisted output downstream', async t => {
  let downstreamContext;
  const f = await setup(t, [message(call('workflow', { stages: [['stage one'], ['stage two']] }), { stopReason: 'toolUse' }),
    message('actual stage one output'), context => { downstreamContext = context; return message('stage two received result'); }, message('workflow done')]);
  const settled = await f.run();
  assert.equal(settled.status, 'done');
  assert.match(JSON.stringify(downstreamContext), /actual stage one output/);
  const app = await f.runtime.harness.snapshot(App, f.id, ctx);
  const workflowId = Object.values(app.workflows)[0];
  const task = await f.runtime.harness.getTask(workflowId, ctx);
  assert.equal(task.state.outcome.status, 'completed');
  assert.equal(task.state.outcome.result.length, 2);
  const children = await f.runtime.harness.commit(tx => tx.scanConversations({ ownerConversationId: f.id }, 10), ctx);
  assert.equal(children.items.length, 2);
  for (const child of children.items) {
    const childDoc = await f.runtime.harness.snapshot(App, child.id, ctx);
    assert.equal(childDoc.workspaceId, 'one');
    assert.deepEqual(childDoc.grants, {});
    const agent = await (await f.runtime.harness.conversation(child.id, ctx)).agent(ctx);
    assert.equal(agent.model.provider, 'fixture');
    assert.equal(agent.tools.some(t => t.name === 'workflow'), false);
  }
});

test('A17 explicit approved resources, skills advertised and loaded on demand, native extension, no HOME scan', async t => {
  const directory = await privateDir('omakase-resource-');
  const outside = await privateDir('omakase-resource-outside-');
  await writeFile(join(directory, 'AGENTS.md'), 'Approved immutable instructions');
  await writeFile(join(directory, 'SKILL.md'), 'Manufactured skill body');
  await writeFile(join(outside, 'SECRET.md'), 'Outside the approved roots');
  const contexts = [];
  const appTool = defineTool({ name: 'fixture_tool', description: 'Fixture tool', parameters: obj({}),
    execute: async () => ({ output: [{ type: 'text', text: 'extension result' }] }) });
  const record = response => value => { contexts.push(value); return response; };
  const f = await setup(t, [record(message(call('skill', { name: 'fixture_skill' }), { stopReason: 'toolUse' })),
    record(message(call('skill', { name: 'not_a_skill' }), { stopReason: 'toolUse' })),
    record(message(call('fixture_tool', {}), { stopReason: 'toolUse' })), record(message('done'))],
    { resourceRoots: [directory], instructions: [join(directory, 'AGENTS.md')],
      skills: [{ name: 'fixture_skill', description: 'Fixture description', path: join(directory, 'SKILL.md') }] },
    { extensions: [defineExtension({ name: 'fixture.extension', tools: [appTool] })] });
  assert.equal((await f.run()).status, 'done');
  const system = JSON.stringify(contexts[0].messages.filter(m => m.role === 'system'));
  assert.match(system, /Approved immutable instructions/);
  // Like regular Pi: name and description in the prompt, never the body.
  assert.match(system, /fixture_skill: Fixture description/);
  assert.doesNotMatch(JSON.stringify(contexts[0]), /Manufactured skill body/);
  const results = (await f.runtime.snapshot(f.id, scope)).entries.filter(e => e.role === 'toolResult');
  assert.deepEqual(results.map(r => [r.toolName, r.isError === true]), [['skill', false], ['skill', true], ['fixture_tool', false]]);
  assert.equal(results[0].content, 'Manufactured skill body');
  assert.match(JSON.stringify(contexts[1]), /Manufactured skill body/);
  assert.doesNotMatch(results[1].content, /Outside|Manufactured/);
  // Only a configured skill is readable, and only while its path stays under a root.
  await rm(join(directory, 'SKILL.md'));
  await symlink(join(outside, 'SECRET.md'), join(directory, 'SKILL.md'));
  f.provider.faux.setResponses([message(call('skill', { name: 'fixture_skill' }), { stopReason: 'toolUse' }), message('after swap')]);
  assert.equal((await f.run('after-swap')).status, 'done');
  const after = (await f.runtime.snapshot(f.id, scope)).entries.filter(e => e.role === 'toolResult').at(-1);
  assert.equal(after.isError, true);
  assert.doesNotMatch(after.content, /Outside the approved roots/);
  await assert.rejects(createRuntime({ storePath: join(directory, 'unapproved.sqlite'), resourceRoots: [directory], instructions: ['/etc/hostname'] },
    { ...scriptedProvider([]), authorize: async () => ({}), railsEffect: async () => ({}) }), /unapproved_resource/);
  await assert.rejects(createRuntime({ storePath: join(directory, 'skill-outside.sqlite'), resourceRoots: [directory],
    skills: [{ name: 'outside', description: 'Outside', path: join(outside, 'SECRET.md') }] },
  { ...scriptedProvider([]), authorize: async () => ({}), railsEffect: async () => ({}) }), /unapproved_resource/);
});

test('A07 native search transport retains citations and OpenAI route; provider failures are tool errors', async t => {
  const received = [];
  const f = await setup(t, [message(call('web_search', { query: 'manufactured', urls: ['https://example.invalid/context'] }), { stopReason: 'toolUse' }), message('done')], {}, {
    searchTransport: async (args, options) => { received.push(args); assert.ok(options.signal);
      return { results: [], citations: ['https://example.invalid/citation'] }; }
  });
  assert.equal((await f.run()).status, 'done');
  assert.equal(received[0].provider, 'openai');
  assert.deepEqual(received[0].urls, ['https://example.invalid/context']);
  assert.match(JSON.stringify((await f.runtime.snapshot(f.id, scope)).entries), /https:\/\/example.invalid\/citation/);
});

test('A21 cancellation releases human waits, persists and retry does not cancel newly admitted work', async t => {
  const f = await setup(t, [message(call('question', { tabs: [{ title: 'Q', options: [{ id: 'x', label: 'X' }] }] }), { stopReason: 'toolUse' }), message('new work')]);
  const pending = f.run();
  await eventually(async () => (await f.runtime.snapshot(f.id, scope)).pendingInputs[0]);
  await assert.rejects(f.runtime.cancel(f.id, { ...scope, actorId: 'bob', requestId: 'cancel' }), /not_found/);
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel' });
  assert.equal((await pending).status, 'unanswered');
  assert.equal((await f.runtime.snapshot(f.id, scope)).pendingInputs.length, 0);
  const second = f.run('new');
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel' });
  assert.equal((await second).status, 'done');
});

// A background task that runs until it is aborted, created by a tool the way any
// extension could: conversation-owned and excluded from ordinary aborts.
const Background = defineTask({ name: 'fixture.background', version: 1, initial: () => ({ phase: 'run' }),
  abort: (_task, rt, c) => rt.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), c),
  phases: { run: (_task, _rt, c) => new Promise((_resolve, reject) => {
    c.abortSignal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
  }) } });
const spawner = defineExtension({ name: 'fixture.spawner', tasks: [Background], tools: [defineTool({
  name: 'fx_background', description: 'Start background work', parameters: obj({}), replay: 'safe',
  execute: async (_args, api, c) => {
    const id = await api.commit(tx => tx.createTask(Background, {}, { ownership: { kind: 'conversation' }, conversationId: api.conversationId, background: true }), c);
    return { output: [{ type: 'text', text: `started ${id}` }] };
  } })] });

test('A15/A21 cancellation settles the owned tree: background task, workflow, child conversation and its human wait; stays cancelled on reopen', async t => {
  const f = await setup(t, [message(call('fx_background', {}), { stopReason: 'toolUse' }),
    message(call('workflow', { stages: [['child asks']] }), { stopReason: 'toolUse' }),
    message(call('question', { tabs: [{ title: 'Child Q', options: [{ id: 'x', label: 'X' }] }] }), { stopReason: 'toolUse' })],
  {}, { extensions: [spawner] });
  const pending = f.run();
  const childId = await eventually(async () => {
    const children = await f.runtime.harness.commit(tx => tx.scanConversations({ ownerConversationId: f.id }, 10), ctx);
    for (const child of children.items) {
      const doc = await f.runtime.harness.snapshot(App, child.id, ctx);
      if (Object.values(doc?.requests ?? {}).some(r => r.status === 'pending')) return child.id;
    }
  });
  const live = async () => Object.values((await liveTaskGraph(f.runtime.harness, ctx)).tasks);
  const before = await live();
  assert.ok(before.some(n => n.kind === 'fixture.background' && n.background));
  assert.ok(before.some(n => n.kind === 'app.workflow'));
  assert.ok(before.some(n => n.conversationId === childId));
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel-tree' });
  assert.equal((await pending).status, 'unanswered');
  assert.deepEqual(await live(), []);
  for (const node of before) assert.equal((await f.runtime.harness.getTask(node.id, ctx)).state.status, 'terminal');
  const childDoc = await f.runtime.harness.snapshot(App, childId, ctx);
  assert.ok(Object.values(childDoc.requests).every(r => r.status === 'cancelled'));
  // Idempotent retry, then reopen: nothing restarts.
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel-tree' });
  await f.runtime.close();
  const reopened = await createRuntime({ storePath: join(f.cwd, 'state.sqlite') }, { ...scriptedProvider([]),
    authorize: async requested => ({ ...requested, allowed: true, cwd: f.cwd }), railsEffect: async () => ({}), extensions: [spawner] });
  t.after(() => reopened.close());
  assert.deepEqual(Object.keys((await liveTaskGraph(reopened.harness, ctx)).tasks), []);
  assert.equal((await reopened.snapshot(f.id, scope)).status, 'cancelled');
});

test('A05 a file named as an image that is not a decodable image fails clearly instead of reading as text', async t => {
  const f = await setup(t, [message(call('read', { path: 'fake.png' }), { stopReason: 'toolUse' }), message('done')], { execution: 'trusted-local-single-tenant' });
  await writeFile(join(f.cwd, 'fake.png'), 'not really a png');
  assert.equal((await f.run()).status, 'done');
  const result = (await f.runtime.snapshot(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.equal(result.isError, true);
  assert.match(result.content, /not a supported image/);
});

test('A14/A15 a workflow child question reaches the parent view and is answered there', async t => {
  const f = await setup(t, [message(call('workflow', { stages: [['child asks']] }), { stopReason: 'toolUse' }),
    message(call('question', { tabs: [{ title: 'Child Q', options: [{ id: 'x', label: 'X' }] }] }), { stopReason: 'toolUse' }),
    message('child answered'), message('parent done')]);
  const pending = f.run();
  const request = await eventually(async () => (await f.runtime.snapshot(f.id, scope)).pendingInputs[0]);
  assert.equal(request.kind, 'question');
  const parent = await f.runtime.harness.snapshot(App, f.id, ctx);
  assert.equal(Object.hasOwn(parent.requests, request.id), false);
  await assert.rejects(f.runtime.answer(f.id, request.id, { actorId: 'bob', workspaceId: 'one', answer: { selections: [['x']] } }), /not_found/);
  await f.runtime.answer(f.id, request.id, { ...scope, answer: { selections: [['x']] } });
  assert.equal((await pending).status, 'done');
  assert.equal((await f.runtime.snapshot(f.id, scope)).pendingInputs.length, 0);
});

test('A22 usage counts each model row once and never presents an unavailable price as a bill', async t => {
  const f = await setup(t, [message('one'), message('two')]);
  await f.run('first'); await f.run('second');
  const usage = (await f.runtime.snapshot(f.id, scope)).usage;
  assert.ok(usage.totalTokens > 0);
  assert.deepEqual(usage.cost, { estimatedTotal: null, basis: 'price_unavailable' });
  assert.deepEqual((await f.runtime.snapshot(f.id, scope)).usage, usage);
});

test('A17 an application extension module under an approved root installs; one outside is refused', async t => {
  const root = await privateDir('omakase-module-');
  await writeFile(join(root, 'extension.mjs'), `export default ({ defineExtension, defineTool, schema }) => defineExtension({ name: 'app.module',
    tools: [defineTool({ name: 'app_ping', description: 'Ping', parameters: schema.obj({}), execute: async () => ({ output: [{ type: 'text', text: 'pong' }] }) })] });\n`);
  const f = await setup(t, [message(call('app_ping', {}), { stopReason: 'toolUse' }), message('done')], { resourceRoots: [root], extensionModules: [join(root, 'extension.mjs')] });
  assert.equal((await f.run()).status, 'done');
  assert.ok((await f.runtime.snapshot(f.id, scope)).entries.some(e => e.toolName === 'app_ping' && e.content === 'pong'));
  const outside = await privateDir('omakase-module-outside-');
  await writeFile(join(outside, 'extension.mjs'), 'export default () => { throw new Error("must not load"); };\n');
  await assert.rejects(createRuntime({ storePath: join(outside, 'state.sqlite'), resourceRoots: [root], extensionModules: [join(outside, 'extension.mjs')] },
    { ...scriptedProvider([]), authorize: async () => ({}), railsEffect: async () => ({}) }), /unapproved_resource/);
});

test('A27 isolated shell network: a tool shell has no route off the host, or readiness fails closed', async t => {
  const config = { execution: 'trusted-local-single-tenant', shellNetwork: 'isolated' };
  if (!shellIsolationAvailable()) {
    const cwd = await privateDir('omakase-isolation-');
    await assert.rejects(createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...scriptedProvider([]),
      authorize: async () => ({}), railsEffect: async () => ({}) }), /shell_isolation_unavailable/);
    return;
  }
  const f = await setup(t, [message(call('bash', { command: '(exec 3<>/dev/tcp/192.0.2.1/80) 2>&1 && echo CONNECTED || echo BLOCKED' }), { stopReason: 'toolUse' }), message('done')], config);
  assert.equal((await f.run()).status, 'done');
  const result = (await f.runtime.snapshot(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.match(result.content, /BLOCKED/);
  assert.doesNotMatch(result.content, /CONNECTED/);
});
