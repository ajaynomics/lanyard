import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, access, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { launch, client, eventually, privateDir } from './processes.mjs';
import { fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
const query = '?actorId=alice&workspaceId=one';
async function setup() {
  const cwd = await privateDir('omakase-process-');
  return { cwd, storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'synthetic-rails-token-456', responses: [message('hello')] };
}

test('A24 real processes: overlap refused, independent store, kernel crash release', async t => {
  const config = await setup();
  const owner = await launch(config, config.cwd, '-owner'); t.after(() => owner.stop());
  assert.equal(owner.readiness.ready, true);
  const second = await launch(config, config.cwd, '-second'); t.after(() => second.stop());
  assert.deepEqual(second.readiness, { ready: false, reason: 'store_already_owned' });
  const independent = await launch({ ...config, storePath: join(config.cwd, 'independent.sqlite') }, config.cwd, '-independent');
  t.after(() => independent.stop());
  assert.equal(independent.readiness.ready, true);
  await owner.stop('SIGKILL');
  const recovered = await launch(config, config.cwd, '-recovered'); t.after(() => recovered.stop());
  assert.equal(recovered.readiness.ready, true);
});

test('A10 real SIGKILL while a call waits for a person: the wait reattaches and the doorbell finishes the run', async t => {
  const config = await setup();
  config.responses = [message(call('ask', { question: 'Which?' }), { stopReason: 'toolUse' }), message('answered')];
  const owner = await launch(config, config.cwd, '-ask'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  const { body: sub } = await api(`${path}/submissions`, { requestId: 'ask', content: 'ask', definition: definition() });
  const before = await eventually(async () => {
    const snapshot = (await api(path + query)).body;
    return snapshot.pendingInputs?.[0] && snapshot;
  });
  const request = before.pendingInputs[0];
  await owner.stop('SIGKILL');
  const recovered = await launch({ ...config, responses: [message('answered')] }, config.cwd, '-resumed'); t.after(() => recovered.stop());
  const resumed = client(recovered, config);
  const after = (await resumed(path + query)).body;
  assert.deepEqual(after.pendingInputs.map(r => r.id), [request.id]);
  const asked = (await readFile(join(config.cwd, 'invocations.jsonl'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  const key = `${asked[0].taskId}:${asked[0].callId}`;
  await writeFile(join(config.cwd, 'decisions.jsonl'), JSON.stringify({ key, result: { selections: ['two'] } }) + '\n');
  assert.equal((await resumed(`${path}/wakes`, { key })).status, 200);
  const final = await eventually(async () => {
    const snapshot = (await resumed(path + query)).body; return snapshot.status === 'done' && snapshot;
  });
  assert.ok(sub.id);
  assert.ok(final.entries.some(e => e.content === 'answered'));
  assert.equal('state' in final || 'inspection' in final || 'submission' in final, false);
  assert.equal(final.entries.filter(e => e.role === 'toolResult').length, 1);
  assert.equal(final.pendingInputs.length, 0);
});

test('A06 unsafe native bash interrupted by SIGKILL is not replayed', async t => {
  const config = { ...await setup(), execution: 'trusted-local-single-tenant' };
  config.responses = [message(call('bash', { command: 'printf once >> count; printf "%s" "$$" > shell.pid; touch started; sleep 30' }), { stopReason: 'toolUse' }), message('recovered')];
  const owner = await launch(config, config.cwd, '-unsafe'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  const home = join(config.cwd, 'conversations', String(conversation.id));
  await api(`${path}/submissions`, { requestId: 'unsafe', content: 'unsafe fixture', definition: definition({ computer: LOCAL_COMPUTER }) });
  await eventually(async () => { try { await access(join(home, 'started')); return true; } catch { return false; } });
  const shellPid = Number(await readFile(join(home, 'shell.pid'), 'utf8'));
  t.after(() => { try { process.kill(-shellPid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; } });
  await owner.stop('SIGKILL');
  const resumed = await launch({ ...config, responses: [message('recovered')] }, config.cwd, '-unsafe-resume'); t.after(() => resumed.stop());
  const resumedApi = client(resumed, config);
  const final = await eventually(async () => { const s = (await resumedApi(path + query)).body; return s.status === 'done' && s; });
  assert.equal(await readFile(join(home, 'count'), 'utf8'), 'once');
  const inspection = await resumed.inspect(conversation.id);
  assert.match(JSON.stringify(inspection.entries.filter(e => e.kind === 'pi.tool-result')), /interrupted/i);
});

test('A16 real SIGKILL during a nested codemode bash call: script replays, unsafe nested call is not rerun', async t => {
  const config = { ...await setup(), execution: 'trusted-local-single-tenant' };
  const code = 'let r; try { r = await tools.bash({command:"printf once >> count; printf %s $$ > shell.pid; touch started; sleep 30"}); } catch (e) { r = "nested:" + e.message; } text(JSON.stringify({ r }));';
  config.responses = [message(call('codemode', { code }), { stopReason: 'toolUse' }), message('recovered')];
  const owner = await launch(config, config.cwd, '-codemode'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  const home = join(config.cwd, 'conversations', String(conversation.id));
  await api(`${path}/submissions`, { requestId: 'codemode', content: 'codemode fixture', definition: definition({ computer: LOCAL_COMPUTER }) });
  await eventually(async () => { try { await access(join(home, 'started')); return true; } catch { return false; } });
  const shellPid = Number(await readFile(join(home, 'shell.pid'), 'utf8'));
  t.after(() => { try { process.kill(-shellPid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; } });
  await owner.stop('SIGKILL');
  const resumed = await launch({ ...config, responses: [message('recovered')] }, config.cwd, '-codemode-resume'); t.after(() => resumed.stop());
  const resumedApi = client(resumed, config);
  const final = await eventually(async () => { const s = (await resumedApi(path + query)).body; return s.status === 'done' && s; });
  assert.equal(await readFile(join(home, 'count'), 'utf8'), 'once');
  const results = final.entries.filter(e => e.role === 'toolResult');
  assert.equal(results.length, 1);
  assert.equal(results[0].toolName, 'codemode');
  assert.match(results[0].content, /nested:/);
  assert.equal((await resumed.inspect(conversation.id)).liveTasks, 0);
});

test('A04 default production mode: no file/shell tools reach the model over the real process', async t => {
  const config = await setup();
  config.responses = [message(call('bash', { command: 'touch escaped' }), { stopReason: 'toolUse' }), message('refused')];
  const owner = await launch(config, config.cwd, '-default'); t.after(() => owner.stop());
  const api = client(owner, config);
  const { body: conversation } = await api('/v1/conversations', { requestId: 'create' });
  const path = `/v1/conversations/${conversation.id}`;
  await api(`${path}/submissions`, { requestId: 'escape', content: 'try a shell' });
  const final = await eventually(async () => { const s = (await api(path + query)).body; return ['done', 'error'].includes(s.status) && s; });
  const result = final.entries.find(e => e.role === 'toolResult');
  assert.equal(result.isError, true);
  await assert.rejects(access(join(config.cwd, 'escaped')));
});
