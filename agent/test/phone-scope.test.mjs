import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { access, readFile } from 'node:fs/promises';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { getCurrentSystemPrompt, getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { AssistantEntry, ToolTask } from '@earendil-works/pi-durable';
import { createServer } from '../server.mjs';
import { digest } from '../state.mjs';
import { definition, FIXTURE_TOOLS, LOCAL_COMPUTER, railsStandIn } from './rails-stand-in.mjs';
import { client, eventually, launch, privateDir } from './processes.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';

const noArgs = { type: 'object', properties: {} };
const tools = [...FIXTURE_TOOLS,
  { name: 'current_time', description: 'Read the time', parameters: noArgs },
  { name: 'send_text', description: 'Send a text', parameters: noArgs }];
const agent = definition({ tools });
const use = (name, args = {}) => message(call(name, args), { stopReason: 'toolUse' });
const offered = context => getCurrentTools(context.messages).map(tool => tool.name);
const contains = (context, text) => context.messages.some(m => m.role === 'user' && JSON.stringify(m.content).includes(text));
const scope = '?actorId=alice&workspaceId=one';

async function setup(t, responses, around = (rails, invocation) => rails.invoke(invocation)) {
  const cwd = await privateDir('phone-scope-');
  const config = { storePath: join(cwd, 'store.sqlite'), sidecarToken: 'synthetic-phone-route-token',
    execution: 'trusted-local-single-tenant', limits: { recheckMs: 25 } };
  const rails = railsStandIn();
  const app = await createServer(config, { ...scriptedProvider(responses),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: invocation => around(rails, invocation) });
  t.after(() => app.close());
  assert.equal(app.readiness().ready, true);
  const { port } = await app.listen(0);
  const api = client({ url: `http://127.0.0.1:${port}` }, config);
  const { body: { id } } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${id}`;
  const harness = app.runtime.harness;
  const conversation = () => harness.conversation(id, ctx);
  return { rails, api, path, harness, conversation, computer: join(cwd, String(id)),
    submit: (route, requestId, extra = {}) => api(`${path}/${route}`, { requestId, content: requestId, ...extra }),
    snapshot: async () => (await api(path + scope)).body,
    entries: async () => (await (await conversation()).entries({ order: 'ascending' }, 100, undefined, ctx)).items };
}

const phoneRoute = 'phone-submissions', normal = 'submissions';

test('a real in-flight phone run blocks an outward call despite an ordinary steer; the next run may call it', async t => {
  const entered = Promise.withResolvers(), gate = Promise.withResolvers();
  t.after(gate.resolve);
  const requests = [];
  const withComputer = definition({ tools, computer: { ...LOCAL_COMPUTER, notesFile: true } });
  const f = await setup(t, [async context => {
    requests.push(offered(context));
    entered.resolve();
    assert.match(getCurrentSystemPrompt(context.messages), /helpers and computer tools are unavailable/);
    await gate.promise;
    return use('current_time');
  }, context => {
    requests.push(offered(context));
    assert.ok(contains(context, 'human-steer'), 'steer actually joined the phone run');
    return message([call('send_text', {}), call('ask', { question: 'phone must not ask' })], { stopReason: 'toolUse' });
  }, message('phone done'), context => {
    requests.push(offered(context));
    return use('ask', { question: 'normal may ask' });
  }, message('normal done')]);
  assert.equal((await f.submit(phoneRoute, 'phone first', { whenBusy: 'reject', definition: withComputer, phone: false })).status, 202);
  await entered.promise;
  assert.equal((await f.submit(normal, 'human-steer', { whenBusy: 'steer', fromPerson: true, definition: withComputer })).status, 202);
  gate.resolve();
  const during = await eventually(async () => {
    const view = await f.snapshot();
    return (view.status === 'done' || view.status === 'error' || view.pendingInputs.length) && view;
  });
  const phoneCalls = f.rails.calls.map(({ tool, phone }) => ({ tool, phone }));
  t.diagnostic(`phone callbacks=${JSON.stringify(phoneCalls)}; pending approvals=${during.pendingInputs.length}; offered=${JSON.stringify(requests)}`);
  if (!phoneCalls.length) t.diagnostic(JSON.stringify((await f.entries()).filter(entry => entry.kind === 'pi.tool-result')));
  assert.equal(during.pendingInputs.length, 0, 'phone tool cannot start an approval');
  assert.deepEqual(phoneCalls, [{ tool: 'current_time', phone: true }]);
  assert.equal(during.status, 'done');
  assert.deepEqual(requests, [['current_time'], ['current_time']]);
  const raw = await f.entries();
  assert.equal(raw.find(entry => entry.data?.requestId === 'phone first').data.phone, true);
  assert.equal(raw.find(entry => entry.data?.requestId === 'human-steer').data.phone, undefined);
  assert.equal(raw.filter(entry => entry.kind === 'pi.tool-result' && JSON.stringify(entry).includes('phone_read_only')).length, 2);
  await assert.rejects(access(f.computer), { code: 'ENOENT' }, 'generation and reads did not start the computer');

  assert.equal((await f.submit(normal, 'normal next', { phone: true })).status, 202);
  await eventually(async () => (await f.snapshot()).pendingInputs[0]);
  const last = f.rails.calls.at(-1);
  assert.equal(last.tool, 'ask');
  assert.equal(Object.hasOwn(last, 'phone'), false, 'generic route cannot set the marker');
  assert.ok(requests[2].includes('ask') && requests[2].includes('send_text'));
  const [key] = f.rails.keys();
  f.rails.decide(key, { yes: true });
  assert.equal((await f.api(`${f.path}/wakes`, { key })).status, 200);
  t.diagnostic('ordinary next run invoked and could complete the same outward tool');
  await eventually(async () => (await f.snapshot()).status === 'done');
});

test('a phone is rejected or queued, never steered into an ordinary outward call', async t => {
  const entered = Promise.withResolvers(), gate = Promise.withResolvers();
  t.after(gate.resolve);
  const f = await setup(t, [use('note', { key: 'ordinary write' }), context => {
    assert.equal(contains(context, 'phone queued'), false, 'no preview reached the ordinary run');
    return message('ordinary done');
  }, context => {
    assert.ok(contains(context, 'ordinary queued'));
    assert.ok(contains(context, 'phone queued'));
    assert.deepEqual(offered(context), ['current_time']);
    return use('current_time');
  }, message('batch done')], async (rails, invocation) => {
    const result = await rails.invoke(invocation);
    if (invocation.tool === 'note') { entered.resolve(); await gate.promise; }
    return result;
  });
  assert.equal((await f.submit(normal, 'start', { definition: agent })).status, 202);
  await entered.promise;
  assert.equal((await f.submit(phoneRoute, 'phone busy', { whenBusy: 'reject' })).body.error, 'conversation_busy');
  for (const extra of [{}, { whenBusy: 'steer' }, { whenBusy: 'followUp', fromPerson: true }])
    assert.equal((await f.submit(phoneRoute, 'invalid', extra)).status, 422);
  assert.equal((await f.submit(normal, 'ordinary queued', { whenBusy: 'followUp', fromPerson: true })).body.status, 'queued');
  const input = { whenBusy: 'followUp' };
  const phone = await f.submit(phoneRoute, 'phone queued', input);
  assert.equal(phone.body.status, 'queued');
  assert.equal((await f.submit(phoneRoute, 'phone queued', { ...input, phone: false })).body.id, phone.body.id);
  assert.equal((await f.submit(normal, 'phone queued', { ...input, phone: true })).body.error, 'request_conflict');
  assert.deepEqual(await f.api(`${f.path}/queued/${phone.body.id}`, { whenBusy: 'steer', first: true }, 'PATCH'),
    { status: 200, body: { changed: false } });
  gate.resolve();
  await eventually(async () => (await f.snapshot()).status === 'done');
  assert.deepEqual(f.rails.calls.map(({ tool, phone }) => [tool, phone]), [['note', undefined], ['current_time', true]]);
});

test('a phone follow-up does not hand back an ordinary approval; an ordinary follow-up still can', async t => {
  const f = await setup(t, [use('ask', { question: 'ordinary approval' }), message('ordinary done'), message('batch done')]);
  assert.equal((await f.submit(normal, 'ordinary', { definition: agent })).status, 202);
  await eventually(async () => (await f.snapshot()).pendingInputs[0]);
  assert.equal((await f.submit(phoneRoute, 'phone queued', { whenBusy: 'followUp' })).body.status, 'queued');
  const count = f.rails.calls.length;
  await eventually(() => f.rails.calls.length >= count + 2 || f.rails.handedBack.size);
  assert.equal(f.rails.handedBack.size, 0, 'phone follow-up cannot hand back the card');
  assert.equal((await f.snapshot()).status, 'waiting');
  assert.equal((await f.submit(normal, 'ordinary queued', { whenBusy: 'followUp', fromPerson: true })).body.status, 'queued');
  await eventually(() => f.rails.handedBack.size === 1);
  await eventually(async () => (await f.snapshot()).status === 'done');
  t.diagnostic('phone caused zero hand-backs across two callback rechecks; ordinary follow-up handed back the card');
});

test('a phone read replay after SIGKILL keeps its exact callback and cannot turn into an outward call', async t => {
  const cwd = await privateDir('phone-replay-');
  const config = { cwd, storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-phone-route-token' };
  const invocations = async () => (await readFile(join(cwd, 'invocations.jsonl'), 'utf8').catch(error => {
    if (error.code === 'ENOENT') return '';
    throw error;
  })).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const first = await launch({ ...config, blockInvocation: 'current_time', responses: [use('current_time')] }, cwd, '-phone');
  t.after(() => first.stop());
  assert.equal(first.readiness.ready, true);
  const api = client(first, config);
  const { body: { id } } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${id}`;
  assert.equal((await api(`${path}/${phoneRoute}`, { requestId: 'phone', content: 'read', whenBusy: 'reject', definition: agent })).status, 202);
  const initial = await eventually(async () => (await invocations())[0]);
  await first.stop('SIGKILL');
  const recovered = await launch({ ...config, responses: [use('ask', { question: 'outward after replay' }), message('recovered')] }, cwd, '-replay');
  t.after(() => recovered.stop());
  assert.equal(recovered.readiness.ready, true);
  const resumed = client(recovered, config);
  const final = await eventually(async () => {
    const view = (await resumed(path + scope)).body;
    return ['done', 'error', 'waiting'].includes(view.status) && view;
  });
  assert.equal(final.status, 'done');
  assert.deepEqual(final.pendingInputs, []);
  assert.deepEqual(await invocations(), [initial, initial]);
  const { digest: signed, ...body } = initial;
  assert.equal(body.phone, true);
  assert.equal(signed, digest(body));
  assert.match(JSON.stringify((await recovered.inspect(id)).entries), /phone_read_only/);
  t.diagnostic('the replayed read sent the identical signed phone callback; zero outward callbacks or approvals after restart');
});

test('a standalone tool task with no generation run keeps ordinary authority', async t => {
  const f = await setup(t, [message('ready')]);
  assert.equal((await f.submit(normal, 'setup', { definition: agent })).status, 202);
  await eventually(async () => (await f.snapshot()).status === 'done');
  const conversation = await f.conversation();
  const assistant = use('note', { key: 'standalone' });
  const task = await conversation.commit(async tx => {
    const entry = await tx.appendEntry(AssistantEntry, conversation.id, { model: [assistant] });
    return tx.createTask(ToolTask, { kind: 'model', assistant: entry.id, callId: assistant.content[0].id },
      { ownership: { kind: 'conversation' }, conversationId: conversation.id });
  }, ctx);
  assert.equal((await f.harness.waitForTask(task, ctx)).state.outcome.status, 'completed');
  assert.deepEqual(f.rails.calls.map(({ tool, phone }) => [tool, phone]), [['note', undefined]]);
});

test('continuing a failed phone run keeps its original phone scope', async t => {
  const f = await setup(t, [message('', { stopReason: 'error', errorMessage: 'synthetic failure' }), context => {
    assert.ok(contains(context, 'phone failed'));
    assert.deepEqual(offered(context), ['current_time']);
    return use('ask', { question: 'outward after continue' });
  }, message('continued')]);
  assert.equal((await f.submit(phoneRoute, 'phone failed', { whenBusy: 'reject', definition: agent })).status, 202);
  await eventually(async () => (await f.snapshot()).status === 'error');
  const resumed = await (await f.conversation()).submit({ type: 'continue', requestId: 'resume' }, ctx);
  assert.equal((await resumed.wait(ctx)).status, 'done');
  assert.deepEqual(f.rails.calls, []);
  assert.match(JSON.stringify(await f.entries()), /phone_read_only/);
});
