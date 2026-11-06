import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { mkdtemp, readFile, writeFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, productionModels, DEFAULT_MODEL } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { App } from '../state.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

async function fixture(t, responses = [message('scripted greeting')], overrides = {}) {
  const cwd = await privateDir('omakase-native-');
  const provider = scriptedProvider(responses);
  const config = { storePath: join(cwd, 'state.sqlite'), ...overrides };
  const deps = { ...provider, authorize: async scope => ({ ...scope, allowed: scope.actorId === 'alice' && scope.workspaceId === 'one', cwd }),
    railsEffect: async effect => ({ noteId: 1, ...effect.arguments }) };
  const runtime = await createRuntime(config, deps);
  t.after(() => runtime.close());
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create-1' });
  return { runtime, config, deps, cwd, scope, id, provider };
}
async function wait(runtime, sub) { return (await runtime.harness.submission(sub.id, ctx)).wait(ctx); }
async function until(fn) {
  const end = Date.now() + 5000;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(r => setTimeout(r, 10)); }
  throw new Error('fixture_deadline');
}

test('approved production catalogue is OpenAI Responses with medium; no remote call', () => {
  const models = productionModels('synthetic-not-a-real-key');
  assert.deepEqual(models.getProviders().map(p => p.id), ['openai']);
  assert.equal(models.getModel('openai', DEFAULT_MODEL.modelId).api, 'openai-responses');
  assert.throws(() => productionModels(''), /invalid_openai_key/);
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
  assert.deepEqual(Object.keys(snapshot).sort(), ['entries', 'failure', 'id', 'pendingInputs', 'status', 'usage']);
  assert.equal(snapshot.failure, null);
  assert.ok(snapshot.entries.some(e => e.role === 'assistant' && e.content === 'scripted greeting'));
  assert.equal(f.provider.faux.state.callCount, 1);
});

test('native coding schemas/results, minimal shell environment and failures', async t => {
  const f = await fixture(t, [message([call('write', { path: 'a.txt', content: 'old\n' })], { stopReason: 'toolUse' }),
    message([call('edit', { path: 'a.txt', edits: [{ oldText: 'old', newText: 'new' }] })], { stopReason: 'toolUse' }),
    message([call('bash', { command: 'printf "%s" "${SIDECAR_TOKEN-unset}"' })], { stopReason: 'toolUse' }), message('done')],
    { execution: 'trusted-local-single-tenant' });
  const result = await f.runtime.submit(f.id, { ...f.scope, requestId: 'code', content: 'code fixture' });
  assert.equal((await wait(f.runtime, result)).status, 'done');
  assert.equal(await readFile(join(f.cwd, 'a.txt'), 'utf8'), 'new\n');
  const tools = f.runtime.registry.snapshot().tools().filter(row => ['read', 'write', 'edit', 'bash'].includes(row.tool.name)).map(row => row.tool);
  assert.deepEqual(tools.map(t => t.name).sort(), ['bash', 'edit', 'read', 'write']);
  assert.ok(tools.every(t => t.replay !== 'safe'));
  assert.equal(tools.find(t => t.name === 'edit').parameters.properties.edits.items.properties.oldText.type, 'string');
  const context = await (await f.runtime.harness.conversation(f.id, ctx)).context(ctx);
  assert.ok(JSON.stringify(context.entries).includes('unset'));
});

test('question persists on orderly reopen; invalid and conflicting answers denied', async t => {
  const f = await fixture(t, [message(call('question', { tabs: [{ title: 'Choose', multiple: true, custom: true,
    options: [{ id: 'one', label: 'One' }, { id: 'two', label: 'Two' }] }] }), { stopReason: 'toolUse' }), message('answered')]);
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'question', content: 'ask' });
  const req = await until(async () => Object.values((await f.runtime.harness.snapshot(App, f.id, ctx)).requests)[0]);
  await f.runtime.close();
  const resumed = await createRuntime(f.config, { ...f.deps, ...scriptedProvider([message('answered')]) });
  t.after(() => resumed.close());
  const request = Object.values((await resumed.harness.snapshot(App, f.id, ctx)).requests)[0];
  assert.equal(request.id, req.id);
  await assert.rejects(resumed.answer(f.id, req.id, { ...f.scope, answer: { selections: [['bad']] } }), /invalid_selection/);
  const answer = { selections: [['two', 'one']], text: 'custom' };
  assert.deepEqual(await resumed.answer(f.id, req.id, { ...f.scope, answer }), answer);
  assert.deepEqual(await resumed.answer(f.id, req.id, { ...f.scope, answer }), answer);
  assert.equal((await wait(resumed, sub)).status, 'done');
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

test('HTTP bearer + Rails recheck; full snapshots ignore stale high cursors', async t => {
  const cwd = await privateDir('omakase-http-');
  const provider = scriptedProvider([message('scripted greeting')]);
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...provider, authorize: async scope => ({ ...scope, allowed: true, cwd }), railsEffect: async () => ({ ok: true }) });
  t.after(() => server.close());
  const address = await server.listen(0);
  const base = `http://127.0.0.1:${address.port}`;
  assert.equal((await fetch(`${base}/up`)).status, 200);
  assert.equal((await fetch(`${base}/v1/conversations`, { method: 'POST', body: '{}' })).status, 401);
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const response = await fetch(`${base}/v1/conversations`, { method: 'POST', headers,
    body: JSON.stringify({ actorId: 'alice', workspaceId: 'one', requestId: 'create' }) });
  const { id } = await response.json();
  assert.ok(id);
  const controller = new AbortController();
  const stream = await fetch(`${base}/v1/conversations/${id}/events?actorId=alice&workspaceId=one`,
    { headers: { ...headers, 'Last-Event-ID': '9999999999' }, signal: controller.signal });
  const reader = stream.body.getReader();
  assert.match(new TextDecoder().decode((await reader.read()).value), /event: snapshot/);
  controller.abort();
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

test('snapshot DTO exposes no task/call identity, scope binding or other workspace data', async t => {
  const f = await fixture(t, [message(call('rails_note', { key: 'k', body: 'b' }), { stopReason: 'toolUse' }), message('done')]);
  const sub = await f.runtime.submit(f.id, { ...f.scope, requestId: 'note', content: 'note' });
  const snapshot = await until(async () => { const s = await f.runtime.snapshot(f.id, f.scope); return s.pendingInputs[0] && s; });
  const approval = snapshot.pendingInputs[0];
  assert.deepEqual(Object.keys(approval).sort(), ['arguments', 'digest', 'expiresAt', 'id', 'kind', 'maxUses', 'tool']);
  const text = JSON.stringify(snapshot);
  for (const leak of ['taskId', 'callId', 'actorId', 'workspaceId', 'cwd', f.cwd, 'grants', 'permittedCalls', 'byTaskId']) assert.equal(text.includes(leak), false, leak);
  await assert.rejects(f.runtime.snapshot(f.id, { actorId: 'alice', workspaceId: 'two' }), /not_found/);
  await f.runtime.answer(f.id, approval.id, { ...f.scope, answer: { decision: 'deny', digest: approval.digest } });
  assert.equal((await wait(f.runtime, sub)).status, 'done');
});

test('unix socket listen: mode 0600, bearer API over the socket, stale socket replaced only by the owner', async t => {
  const cwd = await privateDir('omakase-socket-');
  const socketPath = join(cwd, 'agent.sock');
  const deps = { ...scriptedProvider([message('over the socket')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), railsEffect: async () => ({}) };
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
