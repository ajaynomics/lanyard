import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, readdir } from 'node:fs/promises';
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
  for (const bad of [{ provider: 'local', name: 'x' }, { provider: 'sprites' }, { provider: 'sprites', name: 'Bad Name' },
    { provider: 'sprites', name: '../x' }, { provider: 'docker' }, [], 'local', true]) assert.equal(validComputer(bad), undefined, JSON.stringify(bad));
});

test('the sidecar offers local only in trusted mode, and sprites only with a token', () => {
  assert.deepEqual({ ...offeredComputers({ execution: 'none' }) }, { local: false, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'trusted-local-single-tenant' }) }, { local: true, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: '' } }) }, { local: false, sprites: false });
  assert.deepEqual({ ...offeredComputers({ execution: 'none', sprites: { token: 't' } }) }, { local: false, sprites: true });
  assert.throws(() => spritesComputers({}), /sprites_token_required/);
});

// The real bridge, the real pi-env daemon and pi-env's RemoteExecutionEnv,
// against a loopback stand-in that runs the Sprite's commands on this machine.
test('a sprite computer: created once, daemon uploaded and checked, files and shell in the conversation directory, idle exit lets it sleep', async t => {
  const root = await privateDir('omakase-sprites-');
  const api = await spritesStandIn(root);
  const saved = { url: process.env.SPRITES_URL, token: process.env.SPRITES_TOKEN, idle: process.env.SPRITES_IDLE_MS };
  Object.assign(process.env, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IDLE_MS: '400' });
  const logs = [];
  const computers = spritesComputers({ token: api.token, onLog: text => logs.push(text) });
  t.after(async () => {
    computers.close(); await api.close();
    for (const [key, value] of [['SPRITES_URL', saved.url], ['SPRITES_TOKEN', saved.token], ['SPRITES_IDLE_MS', saved.idle]])
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
  });

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

  assert.deepEqual([...api.sprites], ['ss-bot-7']);
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 1);
  const tools = await readdir(join(home, '.pi-env'));
  assert.equal(tools.length, 1);
  assert.match(tools[0], /^pi-env-[0-9a-f]{32}$/);

  // Idle: the bridge exits and the exec session ends, so nothing keeps the
  // Sprite awake. The next request starts a new session without re-uploading.
  assert.ok(await eventually(() => api.running() === 0), 'daemon session ends when idle');
  const again = await computers.env('ss-bot-7', 13, ctx);
  assert.equal((await again.readTextFile(`${home}/conversations/12/hello.txt`, ctx)).value, 'from the bot\n');
  assert.equal(api.log.filter(line => line.startsWith('PUT ')).length, 1, 'daemon uploaded once');
  assert.equal(api.log.filter(line => line === 'POST /v1/sprites').length, 1, 'sprite created once');
});

test('a sprite computer is refused without a valid token', async t => {
  const root = await privateDir('omakase-sprites-denied-');
  const api = await spritesStandIn(root);
  const saved = { url: process.env.SPRITES_URL, token: process.env.SPRITES_TOKEN };
  Object.assign(process.env, { SPRITES_URL: api.url, SPRITES_TOKEN: 'wrong-token' });
  const computers = spritesComputers({ token: 'wrong-token', onLog: () => {} });
  t.after(async () => {
    computers.close(); await api.close();
    for (const [key, value] of [['SPRITES_URL', saved.url], ['SPRITES_TOKEN', saved.token]])
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
  });
  await assert.rejects(computers.env('ss-bot-8', 1, ctx));
  assert.equal(api.sprites.size, 0);
});

test('a bot whose definition names a sprite runs its shell there, in the conversation directory, and nowhere on this machine', async t => {
  const root = await privateDir('omakase-sprites-runtime-');
  const api = await spritesStandIn(root);
  const saved = { url: process.env.SPRITES_URL, token: process.env.SPRITES_TOKEN };
  Object.assign(process.env, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token });
  const cwd = await privateDir('omakase-sprites-bot-');
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), sprites: { token: api.token } }, {
    ...scriptedProvider([message(call('bash', { command: 'pwd > where.txt' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: rails.invoke, onComputerLog: () => {} });
  t.after(async () => {
    await runtime.close(); await api.close();
    for (const [key, value] of [['SPRITES_URL', saved.url], ['SPRITES_TOKEN', saved.token]])
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
  });
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
