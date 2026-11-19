import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createServer as createHttpServer } from 'node:http';
import { connect, createServer as createTcpServer } from 'node:net';
import { join, dirname } from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { validComputer, offeredComputers, spritesComputers, spriteName, wakeSprite, screenScript, parseSize } from '../computers.mjs';
import { fillSignIn } from '../sign-in.mjs';
import { desktop } from '../desktop.mjs';
import { failureReason } from '../runtime.mjs';
import { getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { privateDir } from './processes.mjs';
import { createRuntime } from '../runtime.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';

const BRIDGE = join(dirname(fileURLToPath(import.meta.url)), '..', 'sprites-bridge.mjs');

const eventually = async (check, ms = 5000) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (await check()) return true; await new Promise(r => setTimeout(r, 25)); }
  return false;
};

test('a computer is none, local, or a named sprite; anything else is refused', () => {
  assert.equal(validComputer(null), null);
  assert.equal(validComputer(undefined), null);
  assert.deepEqual(validComputer({ provider: 'local' }), { provider: 'local' });
  assert.deepEqual(validComputer({ provider: 'sprites', name: 'ss-bot-1' }), { provider: 'sprites', name: 'ss-bot-1' });
  // Whether the notes file is read: a boolean, or not said (not read).
  assert.deepEqual(validComputer({ provider: 'local', notesFile: true }), { provider: 'local', notesFile: true });
  assert.deepEqual(validComputer({ provider: 'sprites', name: 'ss-bot-1', notesFile: false }), { provider: 'sprites', name: 'ss-bot-1', notesFile: false });
  for (const bad of [{ provider: 'local', name: 'x' }, { provider: 'sprites' }, { provider: 'sprites', name: 'Bad Name' },
    { provider: 'sprites', name: '../x' }, { provider: 'docker' }, [], 'local', true, { provider: 'local', notesFile: 'yes' },
    { provider: 'local', notesFile: 1 }, { provider: 'sprites', name: 'ss-bot-1', notesFile: null }]) assert.equal(validComputer(bad), undefined, JSON.stringify(bad));
  // A folder on a machine over SSH: a host, a Unix user and an absolute folder, nothing else.
  const ssh = { provider: 'ssh', host: 'homeserver', user: 'jordan', folder: '/home/jordan/work', keyring: 'person-1' };
  assert.deepEqual(validComputer({ ...ssh, notesFile: true }), { ...ssh, notesFile: true });
  assert.deepEqual(validComputer({ ...ssh, keyring: 'agent-7' }), { ...ssh, keyring: 'agent-7' }, "an agent's own keyring");
  for (const bad of [{ ...ssh, folder: 'work' }, { ...ssh, folder: '/home/jordan/../root' }, { ...ssh, user: 'Root Admin' },
    { ...ssh, host: '-oProxyCommand=x' }, { ...ssh, host: 'a b' }, { ...ssh, port: 22 }, { ...ssh, folder: '/x\nrm -rf /' },
    { provider: 'ssh', host: 'homeserver', user: 'jordan' }, { ...ssh, keyring: undefined }, { ...ssh, keyring: '../x' }]) assert.equal(validComputer(bad), undefined, JSON.stringify(bad));
  // A Sprite's size, when Rails sets one other than the install's default: whole CPUs, MiB of memory and of disk.
  const size = { cpus: 4, memoryMib: 8192, diskMib: 16384 };
  assert.deepEqual(validComputer({ provider: 'sprites', name: 'ss-bot-1', size }), { provider: 'sprites', name: 'ss-bot-1', size });
  for (const bad of [{ ...size, cpus: 0 }, { ...size, memoryMib: 1.5 }, { ...size, diskMib: '8192' }, { cpus: 4, memoryMib: 8192 },
    { ...size, gpus: 1 }, null, [4, 8192, 16384], { ...size, memoryMib: 2 ** 40 }])
    assert.equal(validComputer({ provider: 'sprites', name: 'ss-bot-1', size: bad }), undefined, JSON.stringify(bad));
  assert.equal(validComputer({ provider: 'local', size }), undefined, 'only a Sprite has a size');
  assert.deepEqual(parseSize('4,8192,16384'), size);
  for (const bad of ['4,8192', '0,8192,16384', '4,8192,16384,1', 'a,b,c', '']) assert.equal(parseSize(bad), undefined, bad);
});

// The size Rails sends is what a new Sprite is made with; one already made keeps its own.
test('a sprite computer with a size is made with it, and a start keeps the size it was made with', async t => {
  const root = await privateDir('omakase-sprites-size-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_IDLE_MS: '400' });
  const computers = spritesComputers({ token: api.token, image: api.image, onLog: () => {} });
  t.after(async () => { computers.close(); await api.close(); });

  await computers.env('ss-b9-c1', { cpus: 4, memoryMib: 8192, diskMib: 16384 });
  const { vcpu, mem_mib, disk_mib } = api.sprites.get('ss-b9-c1').created;
  assert.deepEqual({ vcpu, mem_mib, disk_mib }, { vcpu: 4, mem_mib: 8192, disk_mib: 16384 });

  await wakeSprite('ss-b9-c2');
  const plain = api.sprites.get('ss-b9-c2').created;
  assert.deepEqual([plain.vcpu, plain.mem_mib, plain.disk_mib], [2, 2048, 8192], 'without a size, today\'s');

  await api.stop('ss-b9-c2');
  await wakeSprite('ss-b9-c2', { cpus: 1, memoryMib: 1024, diskMib: 8192 });
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 2, 'started, not made again');
  assert.equal(api.sprites.get('ss-b9-c2').mem_mib, 2048);
});

test('the sidecar offers local only in trusted mode, and sprites only with a token and an image', () => {
  assert.deepEqual({ ...offeredComputers({ execution: 'none' }) }, { local: false, sprites: false, ssh: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'trusted-local-single-tenant' }) }, { local: true, sprites: false, ssh: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: '', image: 'i' } }) }, { local: false, sprites: false, ssh: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: 't' } }) }, { local: false, sprites: false, ssh: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: 't', image: 'i' } }) }, { local: false, sprites: true, ssh: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', ssh: { dir: '/rails/storage/agent/ssh' } }) }, { local: false, sprites: false, ssh: true });
  assert.throws(() => spritesComputers({}), /sprites_token_required/);
  assert.throws(() => spritesComputers({ token: 't' }), /sprites_image_required/);
});

// Points the bridge (a child process) at the stand-in for one test.
function spritesEnv(t, values) {
  const saved = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  t.after(() => { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
}

// The real bridge, the real relay and pi-env daemon, and pi-env's
// RemoteExecutionEnv, against a loopback stand-in of the Sprites API.
test('a sprite computer: created once with the image, relay secret and settings; files and shell in its home folder; idle disconnect; a stopped sprite is started again', async t => {
  const root = await privateDir('omakase-sprites-');
  // The spawner holds these by mistake: what it starts gets a fixed environment, so never them.
  const api = await spritesStandIn(root, { spawnerEnv: { SPRITE_RELAY_SECRET: 'f'.repeat(64), PI_DESKTOP_TOKEN: 'e'.repeat(64) } });
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_IDLE_MS: '400' });
  const computers = spritesComputers({ token: api.token, image: api.image, onLog: () => {} });
  t.after(async () => { computers.close(); await api.close(); });

  const env = await computers.env('ss-b7-c12');
  const home = api.homeOf('ss-b7-c12');
  assert.equal(env.cwd, home);
  assert.equal((await env.writeFile('hello.txt', 'from the agent\n', ctx)).ok, true);
  assert.equal(await readFile(join(home, 'hello.txt'), 'utf8'), 'from the agent\n');
  let output = '';
  const ran = await env.exec('printf "%s:%s|" "$(pwd)" "$(cat hello.txt)"; printf "%s%s%s" "${SPRITES_TOKEN-unset}" "${SPRITE_RELAY_SECRET-}" "${PI_DESKTOP_TOKEN-}" >&2', { onOutput: text => { output += text; } }, ctx);
  assert.equal(ran.ok, true);
  assert.equal(ran.value.exitCode, 0);
  // The Sprite's shell runs in its home folder and sees none of the sidecar's
  // environment, nor the relay's secret, nor the desktop's bearer.
  // stdout and stderr are separate streams, so either may arrive first.
  assert.equal(output.replace('unset', ''), `${home}:from the agent|`);
  assert.ok(output.startsWith('unset') || output.endsWith('unset'), output);

  // The create settings cannot be changed later, so they are pinned here.
  const created = api.sprites.get('ss-b7-c12').created;
  const { env: guest, ...settings } = created;
  assert.deepEqual(settings, { name: 'ss-b7-c12', image: api.image, port: 8080, vcpu: 2, mem_mib: 2048, disk_mib: 8192,
    idle_stop_after: '1h', idle_destroy_after: '0' });
  assert.deepEqual(Object.keys(guest).sort(), ['PORT', 'SPRITE_RELAY_SECRET']);
  assert.match(guest.SPRITE_RELAY_SECRET, /^[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(created).includes(api.token), 'the token never reaches the sprite');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 1);

  // Idle: the bridge disconnects, so nothing of ours keeps the Sprite awake.
  assert.ok(await eventually(() => api.connections() === 0), 'disconnects when idle');
  // The socket closes just before the bridge exits; let pi-env see the exit.
  await new Promise(resolve => setTimeout(resolve, 300));
  // The platform stops it later; the next request starts it again, files kept.
  await api.stop('ss-b7-c12');
  const again = await computers.env('ss-b7-c12');
  assert.equal((await again.readTextFile(`${home}/hello.txt`, ctx)).value, 'from the agent\n');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 1, 'created once');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites/ss-b7-c12/start').length, 1, 'started again');
});

test('a sprite name is the agent\'s prefix and the conversation id, within the platform\'s limit', () => {
  assert.equal(spriteName('acme-staging-b1', 42), 'acme-staging-b1-c42');
  assert.throws(() => spriteName('x'.repeat(60), 42), /invalid_sprite_name/);
});

test('the relay closes a connection without the secret before any daemon starts', async t => {
  const root = await privateDir('omakase-sprites-relay-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_IDLE_MS: '400' });
  const computers = spritesComputers({ token: api.token, image: api.image, onLog: () => {} });
  t.after(async () => { computers.close(); await api.close(); });
  await computers.env('ss-b9-c1');
  const { port } = api.sprites.get('ss-b9-c1');
  const answer = await new Promise(resolve => {
    const socket = connect(port, '127.0.0.1', () => socket.write(`AGENT-RELAY ${'0'.repeat(64)} ${'a'.repeat(32)}\n`));
    let got = '';
    socket.on('data', data => { got += data; });
    socket.on('close', () => resolve(got));
    socket.on('error', () => {});
  });
  assert.equal(answer, '', 'no daemon sync line without the secret');
});

test('a sprite computer is refused without a valid token, or with an image the platform has not approved', async t => {
  const root = await privateDir('omakase-sprites-denied-');
  const api = await spritesStandIn(root);
  for (const [token, image] of [['wrong-token', api.image], [api.token, 'registry.example/acme/other:1']]) {
    spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: token, SPRITES_IMAGE: image });
    const computers = spritesComputers({ token, image, onLog: () => {} });
    await assert.rejects(computers.env('ss-b8-c1'));
    computers.close();
  }
  await api.close();
  assert.equal(api.sprites.size, 0);
});

test('an agent whose definition names a sprite runs its shell on its own Sprite, in its home folder, and nowhere on this machine', async t => {
  const root = await privateDir('omakase-sprites-runtime-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const cwd = await privateDir('omakase-sprites-bot-');
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token, image: api.image } }, {
    ...scriptedProvider([message(call('bash', { command: 'pwd > where.txt' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: rails.invoke, onComputerLog: () => {} });
  t.after(async () => { await runtime.close(); await api.close(); });
  assert.deepEqual({ ...runtime.offered }, { local: false, sprites: true, ssh: false });
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const sub = await runtime.submit(id, { ...scope, requestId: 'shell', content: 'where are you?',
    definition: definition({ computer: { provider: 'sprites', name: 'ss-b3' } }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const home = api.homeOf(`ss-b3-c${id}`);
  assert.equal(await readFile(join(home, 'where.txt'), 'utf8'), `${home}\n`);
  await assert.rejects(readFile(join(cwd, String(id), 'where.txt')));

  // A local computer is not offered here.
  await assert.rejects(runtime.submit(id, { ...scope, requestId: 'local', content: 'x', definition: definition({ computer: { provider: 'local' } }) }), /computer_unavailable/);
});

test('a Sprite\'s notes file is read on the Sprite, from its home folder', async t => {
  const root = await privateDir('omakase-sprites-notes-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const cwd = await privateDir('omakase-sprites-notes-bot-');
  // A file of the same name on this machine is not the agent's.
  await writeFile(join(cwd, 'AGENTS.md'), 'From this machine.\n');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token, image: api.image } }, {
    ...scriptedProvider([message('hello')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(async () => { await runtime.close(); await api.close(); });
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  await mkdir(api.homeOf(`ss-b4-c${id}`), { recursive: true });
  await writeFile(join(api.homeOf(`ss-b4-c${id}`), 'AGENTS.md'), 'From the Sprite.\n');
  const sub = await runtime.submit(id, { ...scope, requestId: 'hello', content: 'hello',
    definition: definition({ computer: { provider: 'sprites', name: 'ss-b4', notesFile: true } }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const system = JSON.stringify((await (await runtime.harness.conversation(id, ctx)).context(ctx)).messages.filter(m => m.role === 'system'));
  assert.match(system, /# Notes file \(AGENTS\.md\)\\n\\nFrom the Sprite\./);
  assert.doesNotMatch(system, /From this machine/);
  assert.deepEqual((await runtime.snapshot(id, scope)).notesFile, { bytes: 17 });
});

test('at the awake cap the run stops as computers_busy, and nothing else is put to sleep', async t => {
  const root = await privateDir('omakase-sprites-busy-');
  const api = await spritesStandIn(root, { awake: 1 });
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const cwd = await privateDir('omakase-sprites-busy-bot-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token, image: api.image }, limits: { maxRetries: 0 } }, {
    ...scriptedProvider([message('one'), message('never')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(async () => { await runtime.close(); await api.close(); });
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const say = async (requestId) => {
    const { id } = await runtime.create({ ...scope, requestId });
    const sub = await runtime.submit(id, { ...scope, requestId, content: 'hi', definition: definition({ computer: { provider: 'sprites', name: 'ss-b5' } }) });
    await (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
    return { id, snapshot: await runtime.snapshot(id, scope) };
  };
  const first = await say('first');
  assert.equal(first.snapshot.status, 'done');
  const second = await say('second');
  assert.deepEqual(second.snapshot.failure, { reason: 'computers_busy' });
  assert.equal(api.sprites.get(`ss-b5-c${first.id}`).state, 'running');
  assert.equal(failureReason({ reason: 'model_error', detail: 'computers_busy' }), 'computers_busy');
});

// An operator holds the computer, destroys its Sprite to rebuild it, and the
// agent's next message, its notes file or a command connector must not make a
// fresh one in its place: the run stops with a plain reason, and nothing is created.
test('a held computer whose Sprite is gone is not re-created by a message, the notes file or a command connector', async t => {
  const root = await privateDir('omakase-sprites-held-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const cwd = await privateDir('omakase-sprites-held-bot-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token, image: api.image }, limits: { maxRetries: 0 } }, {
    ...scriptedProvider([message(call('bash', { command: 'pwd' }), { stopReason: 'toolUse' }), message('done'), message('never')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(async () => { await runtime.close(); await api.close(); });
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const say = async (requestId, computer) => {
    const sub = await runtime.submit(id, { ...scope, requestId, content: 'hi', definition: definition({ computer }) });
    await (await runtime.harness.submission(sub.id, ctx)).wait(ctx);
    return runtime.snapshot(id, scope);
  };
  assert.equal((await say('first', { provider: 'sprites', name: 'ss-b9', notesFile: true })).status, 'done');
  const name = `ss-b9-c${id}`;
  assert.equal(api.sprites.get(name).state, 'running');
  // The operator destroys it: the platform answers 404 for it from now on.
  assert.equal((await fetch(`${api.url}/v1/sprites/${name}`, { method: 'DELETE', headers: { Authorization: `Bearer ${api.token}` } })).status, 204);
  const created = () => api.log.filter(line => line === 'POST /v1/sprites').length;
  assert.equal(created(), 1);

  const held = { provider: 'sprites', name: 'ss-b9', notesFile: true, held: true };
  const answer = await say('held', held);
  assert.equal(created(), 1, 'a message re-created the Sprite');
  assert.equal(api.sprites.has(name), false);
  assert.deepEqual(answer.failure, { reason: 'computer_held' });
  await assert.rejects(runtime.connector(id, 'files', { ...scope, computer: held, entry: { command: 'mcp-files' },
    message: { jsonrpc: '2.0', id: 1, method: 'tools/list' } }), error => error.status === 503 && error.category === 'computer_held');
  assert.equal(created(), 1, 'a command connector re-created the Sprite');
  assert.equal(api.sprites.has(name), false);
  assert.equal(failureReason({ reason: 'model_error', detail: 'computer_held' }), 'computer_held');
});

// browser_upload is a screen tool, beside desktop. Like the sidecar's other
// tools it is not one of the definition's, so an agent declaring the 64 Rails
// may (Agent::TOOL_LIMIT) still runs, and Rails may not declare one by its name.
test('the desktop and browser_upload tools are the agent\'s own on a Sprite: absent on a local computer and for its helpers', async t => {
  const root = await privateDir('omakase-sprites-desktop-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const cwd = await privateDir('omakase-sprites-desktop-bot-');
  const seen = {};
  const toolsOf = context => getCurrentTools(context.messages).map(tool => tool.name);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token, image: api.image },
    execution: 'trusted-local-single-tenant' }, {
    ...scriptedProvider([
      context => { seen.agent = toolsOf(context); return message(call('subagent', { task: 'Look.' }, { id: 'toolu_h' }), { stopReason: 'toolUse' }); },
      context => { seen.helper = toolsOf(context); return message('Looked.'); },
      message('Done.'),
      context => { seen.local = toolsOf(context); return message('Here.'); }
    ]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(async () => { await runtime.close(); await api.close(); });
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const say = async (requestId, computer) => {
    const { id } = await runtime.create({ ...scope, requestId });
    const sub = await runtime.submit(id, { ...scope, requestId, content: 'hi', definition: definition({ capabilities: ['subagents'], computer, tools: atTheLimit }) });
    assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  };
  const atTheLimit = Array.from({ length: 64 }, (_, i) => ({ name: `tool_${i}`, description: 'x', parameters: { type: 'object' } }));
  await say('sprite', { provider: 'sprites', name: 'ss-b7' });
  assert.ok(['desktop', 'browser_upload', 'visit_website'].every(name => seen.agent.includes(name)), JSON.stringify(seen.agent));
  assert.ok(atTheLimit.every(tool => seen.agent.includes(tool.name)), 'every one of the 64 tools Rails declared');
  assert.ok(seen.helper.includes('visit_website') && seen.helper.includes('bash'), JSON.stringify(seen.helper));
  assert.equal(seen.helper.includes('desktop') || seen.helper.includes('browser_upload'), false);
  await say('local', { provider: 'local' });
  assert.ok(seen.local.includes('bash'));
  assert.equal(seen.local.includes('desktop') || seen.local.includes('browser_upload'), false);

  const { id } = await runtime.create({ ...scope, requestId: 'named' });
  await assert.rejects(runtime.submit(id, { ...scope, requestId: 'named', content: 'hi',
    definition: definition({ tools: [{ name: 'browser_upload', description: 'x', parameters: { type: 'object' } }], computer: { provider: 'local' } }) }),
  /invalid_tools/, 'a Rails tool may not take its name');
});

// The desktop control server's part: answers POST /action with the bearer.
async function fakeDesk(token) {
  const seen = [];
  const server = createHttpServer(async (request, response) => {
    const parts = [];
    for await (const part of request) parts.push(part);
    seen.push({ method: request.method, url: request.url, authorization: request.headers.authorization, body: Buffer.concat(parts).toString('utf8') });
    if (request.headers.authorization !== `Bearer ${token}`) return void response.writeHead(401).end('{"ok":false,"error":"unauthorized"}');
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ ok: true, result: 'captured', width: 1280, height: 800, image_b64: Buffer.from('\x89PNG').toString('base64') }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { seen, port: server.address().port, close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections?.(); }) };
}

test('the desktop tool reaches the screen through the relay, which alone adds the bearer; nothing runs on the computer', async t => {
  const root = await privateDir('omakase-sprites-desk-');
  const bearer = 'd'.repeat(64);
  const desk = await fakeDesk(bearer);
  const api = await spritesStandIn(root, { guestEnv: { SPRITE_DESK_PORT: String(desk.port), PI_DESKTOP_TOKEN: bearer } });
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  t.after(async () => { await api.close(); await desk.close(); });
  const env = { id: 'sprites:ss-b4-c2', exec: async () => { throw new Error('the desktop ran a command on the computer'); } };

  const result = await desktop.execute({ action: 'click', x: 10, y: 20 }, { env }, ctx);
  assert.equal(result.output[0].text, 'captured (1280x800)');
  assert.equal(result.output[1].type, 'image');
  assert.deepEqual(desk.seen, [{ method: 'POST', url: '/action', authorization: `Bearer ${bearer}`, body: '{"action":"click","x":10,"y":20}' }]);

  // Without the relay's secret the desk is never reached.
  const { port } = api.sprites.get('ss-b4-c2');
  const answer = await new Promise(resolve => {
    const socket = connect(port, '127.0.0.1', () => socket.write(`AGENT-DESK ${'0'.repeat(64)}\n{"action":"screenshot"}\n`));
    let got = '';
    socket.on('data', data => { got += data; });
    socket.on('close', () => resolve(got));
    socket.on('error', () => {});
  });
  assert.equal(answer, '');
  assert.equal(desk.seen.length, 1);

  // A desk that is down is an error, not a fallback onto the computer.
  await desk.close();
  await assert.rejects(desktop.execute({ action: 'screenshot' }, { env }, ctx), /The screen is not running/);
});

// The old relay destroys an AGENT-DESK connection with the action line still
// unread, which Linux answers with a reset about half the time (b1-c18: 17 of
// 32 calls). Here it always resets, after the hello.
test('on a Sprite made before AGENT-DESK, whose relay resets the connection, the desktop tool still runs the old desk.mjs there', async t => {
  const root = await privateDir('omakase-sprites-old-desk-reset-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const old = createTcpServer(socket => {
    socket.on('error', () => {});
    socket.once('data', () => setTimeout(() => socket.resetAndDestroy(), 20));
  });
  await new Promise(resolve => old.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await api.close(); old.close(); });
  const ran = [];
  const env = { id: 'sprites:ss-b4-c4', exec: async (argv, options) => {
    ran.push(argv);
    options.onOutput(JSON.stringify({ ok: true, result: 'captured', width: 1280, height: 800, image_b64: 'iVBORw==' }), ctx, { stream: 'stdout' });
    return { ok: true, value: { exitCode: 0 } };
  } };
  await wakeSprite('ss-b4-c4');
  api.sprites.get('ss-b4-c4').port = old.address().port;
  const result = await desktop.execute({ action: 'screenshot' }, { env }, ctx);
  assert.equal(result.output[0].text, 'captured (1280x800)');
  assert.deepEqual(ran, [['node', '/opt/agent/desk.mjs', '{"action":"screenshot"}']]);

  // Only when the old way fails too is the screen not running.
  env.exec = async () => ({ ok: true, value: { exitCode: 1 } });
  await assert.rejects(desktop.execute({ action: 'screenshot' }, { env }, ctx), /The screen is not running/);
});

test('on a Sprite made before AGENT-DESK, whose relay closes it unanswered, the desktop tool runs the old desk.mjs there', async t => {
  const root = await privateDir('omakase-sprites-old-desk-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  // The old relay, as far as AGENT-DESK goes: it closes the connection.
  const old = createTcpServer(socket => socket.destroy());
  await new Promise(resolve => old.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await api.close(); old.close(); });
  const ran = [];
  const env = { id: 'sprites:ss-b4-c3', exec: async (argv, options) => {
    ran.push(argv);
    options.onOutput(JSON.stringify({ ok: true, result: 'captured', width: 1280, height: 800, image_b64: 'iVBORw==' }), ctx, { stream: 'stdout' });
    return { ok: true, value: { exitCode: 0 } };
  } };
  await wakeSprite('ss-b4-c3');
  api.sprites.get('ss-b4-c3').port = old.address().port;
  const result = await desktop.execute({ action: 'screenshot' }, { env }, ctx);
  assert.equal(result.output[0].text, 'captured (1280x800)');
  assert.deepEqual(ran, [['node', '/opt/agent/desk.mjs', '{"action":"screenshot"}']]);
});

// An operator remakes a Sprite to rebuild it; one resized by hand keeps its memory.
test('a remade sprite keeps the old one\'s memory; one whose memory is not known gets the default', async t => {
  const root = await privateDir('omakase-sprites-remake-');
  const api = await spritesStandIn(root);
  t.after(() => api.close());
  const bridge = (...args) => new Promise(resolve => execFile(process.execPath, [BRIDGE, ...args],
    { env: { PATH: process.env.PATH, SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image } },
    (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr })));

  assert.equal((await bridge('ss-b8-c1', 'wake')).code, 0);
  await api.stop('ss-b8-c1');
  api.resize('ss-b8-c1', 4096);
  const remade = await bridge('ss-b8-c1', 'remake');
  assert.equal(remade.code, 0, remade.stderr);
  assert.deepEqual(api.log.filter(line => /^(POST \/v1\/sprites|DELETE)/.test(line)), ['POST /v1/sprites', 'DELETE /v1/sprites/ss-b8-c1', 'POST /v1/sprites']);
  assert.equal(api.sprites.get('ss-b8-c1').created.mem_mib, 4096);
  assert.equal(api.sprites.get('ss-b8-c1').state, 'running');
  assert.equal(remade.stdout.trim(), 'remade with 4096 MiB');

  const unknown = await bridge('ss-b8-c2', 'remake');
  assert.equal(unknown.code, 0, unknown.stderr);
  assert.equal(api.sprites.get('ss-b8-c2').created.mem_mib, 2048);
  assert.match(unknown.stdout, /2048 MiB \(the default: the platform reported no size\)/);

  // Given the agent's size, the remade Sprite is that size, whatever the old one's.
  api.resize('ss-b8-c1', 4096);
  const sized = await bridge('ss-b8-c1', 'remake', '--size', '4,8192,16384');
  assert.equal(sized.code, 0, sized.stderr);
  const { vcpu, mem_mib, disk_mib } = api.sprites.get('ss-b8-c1').created;
  assert.deepEqual({ vcpu, mem_mib, disk_mib }, { vcpu: 4, mem_mib: 8192, disk_mib: 16384 });
  assert.equal(sized.stdout.trim(), 'remade with 4 CPUs, 8192 MiB of memory and 16384 MiB of disk, as asked');
  for (const bad of [['--size', '4,8192'], ['--size'], ['--memory', '4096']])
    assert.notEqual((await bridge('ss-b8-c1', 'remake', ...bad)).code, 0, bad.join(' '));
});

// #60: the screen's scripts run as `browser`, through the relay's
// AGENT-BROWSER and the script-only spawner, so a sign-in passes through no
// process of the agent's. Here both spawners run as this machine's user;
// which user each runs as is bin/check-computer-image's to check.
test('a screen script runs through the relay\'s AGENT-BROWSER, with only its sign-in and DevTools\' address; anything else is refused', async t => {
  const root = await privateDir('omakase-sprites-browser-');
  const script = join(root, 'script.mjs');
  await writeFile(script, 'const { AGENT_CDP, AGENT_SIGN_IN, OTHER, NODE_OPTIONS } = process.env;\n' +
    'process.stdout.write(JSON.stringify({ ok: true, filled: ["password"], url: "https://example.com/", seen: { AGENT_CDP, AGENT_SIGN_IN, OTHER, NODE_OPTIONS, args: process.argv.slice(2) } }) + "\\n");\n');
  // DevTools' port, held by this user, as cdp.mjs holds it on a Sprite.
  const devtools = createHttpServer((request, response) => response.end());
  await new Promise(resolve => devtools.listen(0, '127.0.0.1', resolve));
  const cdpToken = 'c'.repeat(64);
  const api = await spritesStandIn(root, { browserEnv: { SPRITE_SPAWN_SCRIPTS: script, SPRITE_CDP_TOKEN: cdpToken, SPRITE_CDP_PORT: String(devtools.address().port) } });
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  t.after(async () => { await api.close(); devtools.close(); });

  let out = '';
  const ran = await screenScript('ss-b6-c1', ['node', script, 'one'], { env: { AGENT_SIGN_IN: '{"password":"made-up"}', OTHER: 'x', NODE_OPTIONS: '--require=/tmp/x.js' },
    onOutput: (text, _ctx, info) => { if (info.stream === 'stdout') out += text; } });
  assert.deepEqual(ran, { ok: true, value: { exitCode: 0 } });
  assert.deepEqual(JSON.parse(out).seen, { AGENT_CDP: `http://127.0.0.1:${devtools.address().port}/${cdpToken}`, AGENT_SIGN_IN: '{"password":"made-up"}', args: ['one'] });

  // The sign-in tool goes this way, never through the agent's exec.
  const env = { id: 'sprites:ss-b6-c1', exec: async () => { throw new Error('the sign-in went through the agent\'s exec'); },
    onScreen: (argv, options, context) => screenScript('ss-b6-c1', argv.map(arg => arg === '/opt/agent/fill.mjs' ? script : arg), options, context) };
  const filled = await fillSignIn(async () => ({ host: 'example.com', username: 'maya', password: 'made-up' }), { callId: 'toolu_1' }, { signIn: 'Portal' }, { env }, {});
  assert.equal(filled.isError, undefined, JSON.stringify(filled));
  assert.match(filled.output[0].text, /^Filled the password for Portal on https:\/\/example\.com\//);

  // Anything but a listed script with node: closed, no exit line.
  for (const argv of [['sh', '-c', 'id'], ['node', '-e', 'console.log(1)'], ['node', join(root, 'other.mjs')]]) {
    const refused = await screenScript('ss-b6-c1', argv, {});
    assert.equal(refused.ok, false, JSON.stringify(argv));
  }

  // DevTools' port not held: no script runs, and the answer is a script's for no browser.
  await new Promise(resolve => devtools.close(resolve));
  out = '';
  const unheld = await screenScript('ss-b6-c1', ['node', script], { onOutput: (text, _ctx, info) => { if (info.stream === 'stdout') out += text; } });
  assert.deepEqual(unheld, { ok: true, value: { exitCode: 3 } });
  assert.equal(out, '');
});

test('a Sprite made before AGENT-BROWSER, whose relay closes it unanswered, is told apart from a connection that fails', async t => {
  const root = await privateDir('omakase-sprites-old-browser-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  // The old relay reads the hello and closes; nothing is left unread, so no reset.
  const old = createTcpServer(socket => { socket.on('error', () => {}); socket.once('data', () => socket.destroy()); });
  const broken = createTcpServer(socket => { socket.on('error', () => {}); socket.once('data', () => socket.resetAndDestroy()); });
  await new Promise(resolve => old.listen(0, '127.0.0.1', resolve));
  await new Promise(resolve => broken.listen(0, '127.0.0.1', resolve));
  t.after(async () => { await api.close(); old.close(); broken.close(); });
  await wakeSprite('ss-b6-c2');
  api.sprites.get('ss-b6-c2').port = old.address().port;
  assert.equal(await screenScript('ss-b6-c2', ['node', '/opt/agent/fill.mjs'], { env: { AGENT_SIGN_IN: '{}' } }), null);

  // There the sign-in goes the old way, through the agent's exec.
  const ran = [];
  const env = { id: 'sprites:ss-b6-c2', onScreen: (argv, options, context) => screenScript('ss-b6-c2', argv, options, context),
    exec: async (argv, options) => {
      ran.push([argv, Object.keys(options.env)]);
      options.onOutput(JSON.stringify({ ok: true, filled: ['password'], url: 'https://example.com/' }), {}, { stream: 'stdout' });
      return { ok: true, value: { exitCode: 0 } };
    } };
  const filled = await fillSignIn(async () => ({ host: 'example.com', password: 'made-up' }), { callId: 'toolu_1' }, { signIn: 'Portal' }, { env }, {});
  assert.equal(filled.isError, undefined, JSON.stringify(filled));
  assert.deepEqual(ran, [[['node', '/opt/agent/fill.mjs'], ['AGENT_SIGN_IN']]]);

  // A reset is a failure, never taken for an old relay: nothing goes the old way.
  api.sprites.get('ss-b6-c2').port = broken.address().port;
  const failed = await screenScript('ss-b6-c2', ['node', '/opt/agent/fill.mjs'], {});
  assert.equal(failed.ok, false);
  ran.length = 0;
  const refused = await fillSignIn(async () => ({ host: 'example.com', password: 'made-up' }), { callId: 'toolu_1' }, { signIn: 'Portal' }, { env }, {});
  assert.equal(refused.isError, true);
  assert.deepEqual(ran, []);
});
