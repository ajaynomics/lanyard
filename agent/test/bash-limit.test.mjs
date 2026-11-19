import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { createRuntime } from '../runtime.mjs';
import { railsStandIn, definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { privateDir } from './processes.mjs';

// The real case: a pipeline under the shell, and something it sent to the
// background, both still running when the limit comes. Killing only the shell
// would leave them behind.
const RUNAWAY = 'echo $$ > shell.pid; echo before-limit; sleep 30 & echo $! > sleep.pid; sleep 30 | cat';

// Every process of this machine in process group `group`; zombies are dead.
async function inGroup(group) {
  const found = [];
  for (const pid of await readdir('/proc').catch(() => [])) {
    if (!/^\d+$/.test(pid)) continue;
    const stat = await readFile(`/proc/${pid}/stat`, 'utf8').catch(() => '');
    const [state, , pgrp] = stat.slice(stat.lastIndexOf(')') + 2).split(' ');
    if (Number(pgrp) === group && state !== 'Z') found.push(Number(pid));
  }
  return found;
}
async function alive(pid) {
  const stat = await readFile(`/proc/${pid}/stat`, 'utf8').catch(() => '');
  return stat !== '' && stat.slice(stat.lastIndexOf(')') + 2)[0] !== 'Z';
}
async function gone(check) {
  const end = Date.now() + 3000;
  while (Date.now() < end) { if (await check()) return true; await new Promise(r => setTimeout(r, 25)); }
  return false;
}
function spritesEnv(t, values) {
  const saved = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  t.after(() => { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
}
// Whatever a failing run left, so a red test does not leave sleeps behind.
function sweep(t, folder) {
  t.after(async () => {
    for (const file of ['shell.pid', 'sleep.pid']) {
      const pid = Number(await readFile(join(folder(), file), 'utf8').catch(() => ''));
      if (pid > 0) { try { process.kill(file === 'shell.pid' ? -pid : pid, 'SIGKILL'); } catch {} }
    }
  });
}

async function run(t, { computer, config = {}, deps = {}, args, folder }) {
  const cwd = await privateDir('omakase-bash-limit-');
  const rails = railsStandIn();
  const seen = [];
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), ...config }, {
    ...scriptedProvider([context => { seen.push(getCurrentTools(context.messages)); return message(call('bash', args), { stopReason: 'toolUse' }); },
      message('done')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: rails.invoke, ...deps });
  t.after(() => runtime.close());
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const home = folder?.(id) ?? join(cwd, String(id));
  sweep(t, () => home);
  const started = Date.now();
  const sub = await runtime.submit(id, { ...scope, requestId: 'run', content: 'search everything', definition: definition({ computer }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const result = (await runtime.entries(id, scope)).entries.find(entry => entry.role === 'toolResult');
  return { result, home, elapsed: Date.now() - started, tools: seen[0] };
}

async function assertKilled({ result, home, elapsed }, limit) {
  assert.ok(elapsed < 15000, `the command ran ${elapsed} ms`);
  assert.equal(result.isError, true, JSON.stringify(result));
  assert.match(result.content, /before-limit/, 'the output so far');
  assert.match(result.content, new RegExp(`stopped this command after ${limit}\\b`), result.content);
  const group = Number(await readFile(join(home, 'shell.pid'), 'utf8'));
  const sleep = Number(await readFile(join(home, 'sleep.pid'), 'utf8'));
  assert.ok(await gone(async () => (await inGroup(group)).length === 0), `left running in its group: ${await inGroup(group)}`);
  assert.ok(await gone(async () => !(await alive(sleep))), 'the background sleep is gone');
}

test('a bash call with no timeout gets the default limit; at it the whole process group is killed, and the agent sees why with the output so far', { timeout: 60000 }, async t => {
  const ran = await run(t, { computer: LOCAL_COMPUTER, config: { execution: 'trusted-local-single-tenant', limits: { bashTimeoutMs: 1500 } },
    args: { command: RUNAWAY } });
  await assertKilled(ran, '1.5 seconds');
});

test('on a Sprite, a model-given timeout kills the command\'s process group there, through the computer\'s daemon', { timeout: 60000 }, async t => {
  const root = await privateDir('omakase-bash-limit-sprites-');
  const api = await spritesStandIn(root);
  t.after(() => api.close());
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  const ran = await run(t, { computer: { provider: 'sprites', name: 'ss-limit' }, config: { sprites: { token: api.token, image: api.image } },
    deps: { onComputerLog: () => {} }, args: { command: RUNAWAY, timeout: 1 }, folder: id => api.homeOf(`ss-limit-c${id}`) });
  await assertKilled(ran, '1 second');
});

test('bash says its default and its cap; a longer timeout is cut to the cap, not refused', async t => {
  const { BASH_DEFAULT_TIMEOUT_SECONDS, BASH_TIMEOUT_CAP_SECONDS, bashTimeout } = await import('../bash-limit.mjs');
  assert.equal(BASH_DEFAULT_TIMEOUT_SECONDS, 600);
  assert.equal(BASH_TIMEOUT_CAP_SECONDS, 3600);
  assert.equal(bashTimeout(undefined, 600), 600);
  assert.equal(bashTimeout(45, 600), 45);
  assert.equal(bashTimeout(7200, 600), 3600);
  // What is not a number of seconds stays the tool's own refusal.
  assert.equal(bashTimeout(-1, 600), -1);

  const { tools } = await run(t, { computer: LOCAL_COMPUTER, config: { execution: 'trusted-local-single-tenant' }, args: { command: 'echo quick' } });
  const bash = tools.find(tool => tool.name === 'bash');
  assert.match(bash.description, /10 minutes/);
  assert.match(bash.description, /60 minutes/);
  assert.doesNotMatch(JSON.stringify(bash.parameters), /no default timeout/);
  await assert.rejects(createRuntime({ storePath: join(await privateDir('omakase-bash-limit-bound-'), 'state.sqlite'),
    execution: 'trusted-local-single-tenant', limits: { bashTimeoutMs: 3600001 } }, scriptedProvider([])), /invalid_bound_bashTimeoutMs/);
});
