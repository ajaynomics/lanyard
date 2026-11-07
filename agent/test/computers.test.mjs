import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { connect } from 'node:net';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { validComputer, offeredComputers, spritesComputers, spriteName } from '../computers.mjs';
import { failureReason } from '../runtime.mjs';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { privateDir } from './processes.mjs';
import { createRuntime } from '../runtime.mjs';
import { railsStandIn, definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';

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
});

test('the sidecar offers local only in trusted mode, and sprites only with a token and an image', () => {
  assert.deepEqual({ ...offeredComputers({ execution: 'none' }) }, { local: false, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'trusted-local-single-tenant' }) }, { local: true, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: '', image: 'i' } }) }, { local: false, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: 't' } }) }, { local: false, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: 't', image: 'i' } }) }, { local: false, sprites: true });
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
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_IDLE_MS: '400' });
  const computers = spritesComputers({ token: api.token, image: api.image, onLog: () => {} });
  t.after(async () => { computers.close(); await api.close(); });

  const env = await computers.env('ss-b7-c12');
  const home = api.homeOf('ss-b7-c12');
  assert.equal(env.cwd, home);
  assert.equal((await env.writeFile('hello.txt', 'from the agent\n', ctx)).ok, true);
  assert.equal(await readFile(join(home, 'hello.txt'), 'utf8'), 'from the agent\n');
  let output = '';
  const ran = await env.exec('printf "%s:%s|" "$(pwd)" "$(cat hello.txt)"; printf "%s" "${SPRITES_TOKEN-unset}" >&2', { onOutput: text => { output += text; } }, ctx);
  assert.equal(ran.ok, true);
  assert.equal(ran.value.exitCode, 0);
  // The Sprite's shell runs in its home folder and sees none of the sidecar's environment.
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

test('a sprite name is the bot\'s prefix and the conversation id, within the platform\'s limit', () => {
  assert.equal(spriteName('avery-staging-b1', 42), 'avery-staging-b1-c42');
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
    const socket = connect(port, '127.0.0.1', () => socket.write(`AVERY-RELAY ${'0'.repeat(64)} ${'a'.repeat(32)}\n`));
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
  for (const [token, image] of [['wrong-token', api.image], [api.token, 'gitea.example.com/ajaynomics/other:1']]) {
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
  assert.deepEqual({ ...runtime.offered }, { local: false, sprites: true });
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
  // A file of the same name on this machine is not the bot's.
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
