// Command connectors: POST /v1/conversations/:id/connectors/:name/rpc runs a
// stdio MCP server (stdio-mcp-server.mjs) on the agent's computer, a local
// folder or a stand-in Sprite through the real bridge and relay, and passes
// one JSON-RPC message to it.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { realpath, mkdir } from 'node:fs/promises';
import { createServer } from '../server.mjs';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { privateDir } from './processes.mjs';
import { railsStandIn } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';

const SIDECAR_TOKEN = 'sidecar-token-0123456789';
const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), 'stdio-mcp-server.mjs');
const ENTRY = { command: process.execPath, args: [FIXTURE], env: { GREETING: 'hello' }, cwd: null };

async function setup(t, config = {}) {
  const cwd = await privateDir('omakase-connectors-');
  const app = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: SIDECAR_TOKEN, railsToken: 'rails-token-0123456789', ...config }, {
    ...scriptedProvider([message('hi')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke,
    onComputerLog: () => {}, connectorTimings: { callMs: 5000, idleMs: 60000 } });
  const { port } = await app.listen(0);
  t.after(() => app.close());
  const { id } = await app.runtime.create({ actorId: 'alice', workspaceId: 'one', requestId: 'create' });
  let next = 1;
  const rpc = async ({ computer = { provider: 'local' }, entry = ENTRY, method = 'tools/call', params = { name: 'where', arguments: {} },
    token = SIDECAR_TOKEN, actorId = 'alice', name = 'fixture' } = {}) => {
    const response = await fetch(`http://127.0.0.1:${port}/v1/conversations/${id}/connectors/${name}/rpc`, { method: 'POST',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ actorId, workspaceId: 'one', computer, entry, message: { jsonrpc: '2.0', id: `r${next}`, method, params } }) });
    const body = await response.json();
    return { status: response.status, body, id: `r${next++}` };
  };
  const where = async options => {
    const { body } = await rpc(options);
    assert.equal(body.message.error, undefined, JSON.stringify(body));
    return JSON.parse(body.message.result.content[0].text);
  };
  return { app, cwd, id, rpc, where };
}

test('on the local computer: started once in the agent folder, reused, restarted after it dies and when its entry changes', async t => {
  const f = await setup(t, { execution: 'trusted-local-single-tenant' });

  assert.equal((await f.rpc({ token: 'wrong-token-0123456789' })).status, 401);
  assert.equal((await f.rpc({ actorId: 'mallory' })).status, 404);
  assert.equal((await f.rpc({ entry: { command: '' } })).status, 422);
  assert.equal((await f.rpc({ computer: { provider: 'sprites', name: 'ss-b6' } })).status, 422, 'no Sprites here');

  const listed = await f.rpc({ method: 'tools/list', params: {} });
  assert.equal(listed.status, 200);
  assert.equal(listed.body.message.id, listed.id, 'the reply comes back under Rails\' id');
  assert.deepEqual(listed.body.message.result.tools.map(tool => tool.name), ['where', 'crash']);

  const first = await f.where();
  const folder = join(await realpath(f.cwd), String(f.id));
  assert.equal(first.cwd, folder);
  assert.equal(first.home, folder);
  assert.equal(first.greeting, 'hello');
  assert.equal((await f.where()).pid, first.pid, 'one process, reused (it refuses a second initialize)');

  const crashed = await f.rpc({ params: { name: 'crash', arguments: {} } });
  assert.equal(crashed.status, 200);
  assert.match(crashed.body.message.error.message, /exited: boom: the fixture crashed/);
  const restarted = await f.where();
  assert.notEqual(restarted.pid, first.pid, 'started again on the next call');

  const changed = await f.where({ entry: { ...ENTRY, env: { GREETING: 'bonjour' } } });
  assert.notEqual(changed.pid, restarted.pid, 'a changed entry replaces the process');
  assert.equal(changed.greeting, 'bonjour');
  assert.equal((await f.where({ entry: { ...ENTRY, env: { GREETING: 'bonjour' } }, name: 'other' })).greeting, 'bonjour', 'each connector has its own');

  const missing = await f.rpc({ entry: { command: join(f.cwd, 'no-such-command') } });
  assert.match(missing.body.message.error.message, /exited: .*ENOENT/);
});

test('without a local computer the sidecar refuses one', async t => {
  const f = await setup(t);
  assert.deepEqual((await f.rpc()).body, { error: 'computer_unavailable' });
});

function spritesEnv(t, values) {
  const saved = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  t.after(() => { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
}

test('on a Sprite: the relay runs it in the agent\'s home folder, reuses it, and starts it again after the Sprite stops', async t => {
  const root = await privateDir('omakase-connectors-sprites-');
  const api = await spritesStandIn(root);
  t.after(() => api.close());
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_KEEPALIVE_MS: '100' });
  const f = await setup(t, { sprites: { token: api.token, image: api.image } });
  const computer = { provider: 'sprites', name: 'ss-b6' };
  const name = `ss-b6-c${f.id}`;
  await mkdir(join(api.homeOf(name), 'work'), { recursive: true });

  const first = await f.where({ computer, entry: { ...ENTRY, cwd: 'work' } });
  assert.equal(first.home, api.homeOf(name));
  assert.equal(first.cwd, join(await realpath(api.homeOf(name)), 'work'));
  assert.equal(first.greeting, 'hello');
  assert.equal((await f.where({ computer, entry: { ...ENTRY, cwd: 'work' } })).pid, first.pid);

  const crashed = await f.rpc({ computer, entry: { ...ENTRY, cwd: 'work' }, params: { name: 'crash', arguments: {} } });
  assert.match(crashed.body.message.error.message, /exited: boom: the fixture crashed/, 'the relay sends the end of stderr');

  await api.stop(name);
  const woken = await f.where({ computer, entry: { ...ENTRY, cwd: 'work' } });
  assert.notEqual(woken.pid, first.pid);
  assert.equal(api.sprites.get(name).state, 'running', 'the Sprite was started again');
});
