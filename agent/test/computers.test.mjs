import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { connect } from 'node:net';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { validComputer, offeredComputers, spritesComputers } from '../computers.mjs';
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
test('a sprite computer: created once with the image, relay secret and limits; files and shell in the conversation directory; idle disconnect; a stopped sprite is started again', async t => {
  const root = await privateDir('omakase-sprites-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_IDLE_MS: '400' });
  const computers = spritesComputers({ token: api.token, image: api.image, onLog: () => {} });
  t.after(async () => { computers.close(); await api.close(); });

  const env = await computers.env('ss-bot-7', 12, ctx);
  const home = api.homeOf('ss-bot-7');
  assert.equal(env.cwd, `${home}/conversations/12`);
  assert.equal((await env.writeFile('hello.txt', 'from the bot\n', ctx)).ok, true);
  assert.equal(await readFile(join(home, 'conversations/12/hello.txt'), 'utf8'), 'from the bot\n');
  let output = '';
  const ran = await env.exec('printf "%s:%s|" "$(pwd)" "$(cat hello.txt)"; printf "%s" "${SPRITES_TOKEN-unset}" >&2', { onOutput: text => { output += text; } }, ctx);
  assert.equal(ran.ok, true);
  assert.equal(ran.value.exitCode, 0);
  // The Sprite's shell runs in the conversation's directory and sees none of the sidecar's environment.
  // stdout and stderr are separate streams, so either may arrive first.
  assert.equal(output.replace('unset', ''), `${home}/conversations/12:from the bot|`);
  assert.ok(output.startsWith('unset') || output.endsWith('unset'), output);

  const created = api.sprites.get('ss-bot-7').created;
  assert.equal(created.image, api.image);
  assert.deepEqual(Object.keys(created.env).sort(), ['PORT', 'SPRITE_RELAY_SECRET']);
  assert.match(created.env.SPRITE_RELAY_SECRET, /^[0-9a-f]{64}$/);
  assert.ok(!JSON.stringify(created).includes(api.token), 'the token never reaches the sprite');
  assert.equal(created.mem_mib, 1024);
  assert.equal(created.idle_stop_after, '30m');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 1);

  // Idle: the bridge disconnects, so nothing of ours keeps the Sprite awake.
  assert.ok(await eventually(() => api.connections() === 0), 'disconnects when idle');
  // The socket closes just before the bridge exits; let pi-env see the exit.
  await new Promise(resolve => setTimeout(resolve, 300));
  // The platform stops it later; the next request starts it again, files kept.
  await api.stop('ss-bot-7');
  const again = await computers.env('ss-bot-7', 13, ctx);
  assert.equal((await again.readTextFile(`${home}/conversations/12/hello.txt`, ctx)).value, 'from the bot\n');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 1, 'created once');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites/ss-bot-7/start').length, 1, 'started again');
});

test('the relay closes a connection without the secret before any daemon starts', async t => {
  const root = await privateDir('omakase-sprites-relay-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_IDLE_MS: '400' });
  const computers = spritesComputers({ token: api.token, image: api.image, onLog: () => {} });
  t.after(async () => { computers.close(); await api.close(); });
  await computers.env('ss-bot-9', 1, ctx);
  const { port } = api.sprites.get('ss-bot-9');
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
    await assert.rejects(computers.env('ss-bot-8', 1, ctx));
    computers.close();
  }
  await api.close();
  assert.equal(api.sprites.size, 0);
});

test('a bot whose definition names a sprite runs its shell there, in the conversation directory, and nowhere on this machine', async t => {
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
    definition: definition({ computer: { provider: 'sprites', name: 'ss-bot-3' } }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const home = api.homeOf('ss-bot-3');
  assert.equal(await readFile(join(home, 'conversations', String(id), 'where.txt'), 'utf8'), `${home}/conversations/${id}\n`);
  await assert.rejects(readFile(join(cwd, 'conversations', String(id), 'where.txt')));
  // A local computer is not offered here.
  await assert.rejects(runtime.submit(id, { ...scope, requestId: 'local', content: 'x', definition: definition({ computer: { provider: 'local' } }) }), /computer_unavailable/);
});

test('a Sprite\'s notes file is read on the Sprite, from the bot\'s folder there', async t => {
  const root = await privateDir('omakase-sprites-notes-');
  const api = await spritesStandIn(root);
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const cwd = await privateDir('omakase-sprites-notes-bot-');
  // A file of the same name on this machine is not the bot's.
  await writeFile(join(cwd, 'AGENTS.md'), 'From this machine.\n');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token, image: api.image } }, {
    ...scriptedProvider([message('hello')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  t.after(async () => { await runtime.close(); await api.close(); });
  await mkdir(api.homeOf('ss-bot-4'), { recursive: true });
  await writeFile(join(api.homeOf('ss-bot-4'), 'AGENTS.md'), 'From the Sprite.\n');
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const sub = await runtime.submit(id, { ...scope, requestId: 'hello', content: 'hello',
    definition: definition({ computer: { provider: 'sprites', name: 'ss-bot-4', notesFile: true } }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const system = JSON.stringify((await (await runtime.harness.conversation(id, ctx)).context(ctx)).messages.filter(m => m.role === 'system'));
  assert.match(system, /# Notes file \(AGENTS\.md\)\\n\\nFrom the Sprite\./);
  assert.doesNotMatch(system, /From this machine/);
  assert.deepEqual((await runtime.snapshot(id, scope)).notesFile, { bytes: 17 });
});
