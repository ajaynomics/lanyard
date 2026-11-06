import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { obj, num, str } from '@earendil-works/pi-schema';
import { defineExtension, defineTool, defineTask } from '@earendil-works/pi-durable';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, shellIsolationAvailable, liveTaskGraph } from '../runtime.mjs';
import { App } from '../state.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { eventually, privateDir } from './processes.mjs';
const scope = { actorId: 'alice', workspaceId: 'one' };
async function setup(t, responses, config = {}, deps = {}) {
  const cwd = await privateDir('omakase-advanced-');
  const provider = scriptedProvider(responses);
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...provider,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }),
    invoke: rails.invoke, ...deps });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (requestId = 'request', bot) => {
    const submitted = await runtime.submit(id, { ...scope, requestId, content: 'manufactured fixture', ...(bot ? { definition: bot } : {}) });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, run, rails };
}

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
    { ...scriptedProvider([]), authorize: async () => ({}), invoke: async () => ({ status: 'done', result: {} }) }), /unapproved_resource/);
  await assert.rejects(createRuntime({ storePath: join(directory, 'skill-outside.sqlite'), resourceRoots: [directory],
    skills: [{ name: 'outside', description: 'Outside', path: join(outside, 'SECRET.md') }] },
  { ...scriptedProvider([]), authorize: async () => ({}), invoke: async () => ({ status: 'done', result: {} }) }), /unapproved_resource/);
});

test('A21 cancellation releases human waits, persists and retry does not cancel newly admitted work', async t => {
  const f = await setup(t, [message(call('ask', { question: 'Q' }), { stopReason: 'toolUse' }), message('new work')]);
  const pending = f.run('request', definition());
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

test('A15/A21 cancellation settles the owned tree: background task and a human wait; stays cancelled on reopen', async t => {
  const f = await setup(t, [message(call('fx_background', {}), { stopReason: 'toolUse' }),
    message(call('ask', { question: 'Q' }), { stopReason: 'toolUse' })],
  {}, { extensions: [spawner] });
  const pending = f.run('request', definition());
  await eventually(async () => Object.values((await f.runtime.harness.snapshot(App, f.id, ctx))?.requests ?? {}).some(r => r.status === 'pending'));
  const live = async () => Object.values((await liveTaskGraph(f.runtime.harness, ctx)).tasks);
  const before = await live();
  assert.ok(before.some(n => n.kind === 'fixture.background' && n.background));
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel-tree' });
  assert.equal((await pending).status, 'unanswered');
  assert.deepEqual(await live(), []);
  for (const node of before) assert.equal((await f.runtime.harness.getTask(node.id, ctx)).state.status, 'terminal');
  const doc = await f.runtime.harness.snapshot(App, f.id, ctx);
  assert.ok(Object.values(doc.requests).every(r => r.status === 'cancelled'));
  // Idempotent retry, then reopen: nothing restarts.
  await f.runtime.cancel(f.id, { ...scope, requestId: 'cancel-tree' });
  await f.runtime.close();
  const reopened = await createRuntime({ storePath: join(f.cwd, 'state.sqlite') }, { ...scriptedProvider([]),
    authorize: async requested => ({ ...requested, allowed: true, cwd: f.cwd }), invoke: async () => ({ status: 'done', result: {} }), extensions: [spawner] });
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
    { ...scriptedProvider([]), authorize: async () => ({}), invoke: async () => ({ status: 'done', result: {} }) }), /unapproved_resource/);
});

test('A27 isolated shell network: a tool shell has no route off the host, or readiness fails closed', async t => {
  const config = { execution: 'trusted-local-single-tenant', shellNetwork: 'isolated' };
  if (!shellIsolationAvailable()) {
    const cwd = await privateDir('omakase-isolation-');
    await assert.rejects(createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, { ...scriptedProvider([]),
      authorize: async () => ({}), invoke: async () => ({ status: 'done', result: {} }) }), /shell_isolation_unavailable/);
    return;
  }
  const f = await setup(t, [message(call('bash', { command: '(exec 3<>/dev/tcp/192.0.2.1/80) 2>&1 && echo CONNECTED || echo BLOCKED' }), { stopReason: 'toolUse' }), message('done')], config);
  assert.equal((await f.run()).status, 'done');
  const result = (await f.runtime.snapshot(f.id, scope)).entries.find(e => e.role === 'toolResult');
  assert.match(result.content, /BLOCKED/);
  assert.doesNotMatch(result.content, /CONNECTED/);
});
