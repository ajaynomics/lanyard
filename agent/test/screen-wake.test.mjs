// A Sprite stopped while idle is woken by the first screen call, and its
// relay answers seconds before the screen's browser does: before DevTools
// listens, a visit found no browser and a desktop capture took a black frame.
// After a wake the bridge waits, once and within a bound, for DevTools to
// answer, as cdp.mjs does to anyone without its token: 404.
import assert from 'node:assert/strict';
import test from 'node:test';
import { chmod, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createServer as createTcpServer } from 'node:net';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { wakeSprite, screenScript } from '../computers.mjs';
import { retainedVisit } from '../browser.mjs';
import { retainedDesktop } from '../desktop.mjs';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { privateDir } from './processes.mjs';

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const close = server => new Promise(resolve => { server.close(resolve); server.closeAllConnections?.(); });

function setEnv(t, values) {
  const saved = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  t.after(() => { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
}

// A retained screen's Sprite, made and then stopped as the platform stops one
// while idle; its DevTools answers only when told to.
async function stoppedScreen(t, name, { waitMs = 15000, spawnerEnv = {} } = {}) {
  const root = await privateDir('omakase-screen-wake-');
  const script = join(root, 'visit.mjs');
  await writeFile(script, 'process.stdout.write(JSON.stringify({ title: "Example", text: "Hello", screenshot: "AAAA" }) + "\\n");\n');
  // Retain the kernel-assigned port; closing and rebinding lets another test take it.
  let ready = false;
  const devtools = createServer((request, response) => {
    if (ready) response.writeHead(404).end('Not found');
    else request.socket.destroy();
  });
  await listen(devtools);
  t.after(() => close(devtools));
  const port = devtools.address().port;
  const bearer = 'd'.repeat(64), seen = [];
  const desk = createServer((request, response) => {
    seen.push(Date.now());
    response.end(JSON.stringify({ ok: true, result: 'captured', width: 1280, height: 800, image_b64: 'iVBORw==' }));
  });
  await listen(desk);
  const api = await spritesStandIn(root, { spawnerEnv, guestEnv: { SPRITE_DESK_PORT: String(desk.address().port), PI_DESKTOP_TOKEN: bearer },
    browserEnv: { SPRITE_SPAWN_SCRIPTS: script, SPRITE_CDP_TOKEN: 'c'.repeat(64), SPRITE_CDP_PORT: String(port) } });
  setEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image,
    SPRITES_CDP_PORT: String(port), SPRITES_SCREEN_WAIT_MS: String(waitMs) });
  t.after(async () => { await api.close(); await close(desk); });
  await wakeSprite(name);
  await api.stop(name);
  const started = async () => { while (!api.log.includes(`POST /v1/sprites/${name}/start`)) await sleep(20); };
  return {
    seen,
    relay: relayPort => { api.sprites.get(name).port = relayPort; },
    // DevTools answers `ms` after the Sprite is started; resolves with when.
    up: async ms => { await started(); await sleep(ms); ready = true; return Date.now(); },
    visit: () => retainedVisit(async () => ({ id: `sprites:${name}`,
      onScreen: (argv, options, context) => screenScript(name, argv.map(arg => arg === '/opt/agent/visit.mjs' ? script : arg), { ...options, existing: true }, context)
    })).execute({ url: 'https://example.com/' }, {}, ctx),
    capture: () => retainedDesktop(async () => name).tools[0].execute({ action: 'screenshot' }, {}, ctx)
  };
}

test('a just-woken retained screen waits for its browser\'s DevTools, then visits', async t => {
  const screen = await stoppedScreen(t, 'sw-b1-c1');
  const [visited] = await Promise.all([screen.visit(), screen.up(1500)]);
  assert.match(visited.output[0].text, /^Visited https:\/\/example\.com\/\nTitle: Example/);
});

test('a just-woken retained screen whose browser never starts fails, saying so', async t => {
  const screen = await stoppedScreen(t, 'sw-b1-c2', { waitMs: 1000 });
  await assert.rejects(screen.visit(), { message: 'The screen\'s browser did not start within 1 s.' });
});

test('a desktop capture on a just-woken screen is never a frame from before its browser', async t => {
  const screen = await stoppedScreen(t, 'sw-b1-c3', { waitMs: 1000 });
  await assert.rejects(screen.capture(), { message: 'The screen\'s browser did not start within 1 s.' });
  assert.deepEqual(screen.seen, [], 'no frame was taken');
});

test('a desktop capture on a just-woken screen waits until its browser is up', async t => {
  const screen = await stoppedScreen(t, 'sw-b1-c4');
  const [captured, upAt] = await Promise.all([screen.capture(), screen.up(1500)]);
  assert.equal(captured.output[0].text, 'captured (1280x800)');
  assert.ok(screen.seen.length === 1 && screen.seen[0] >= upAt, 'the frame was taken after DevTools was ready');
});

// A relay made before AGENT-BROWSER and AGENT-DESK reads the hello and
// closes; waiting never helps there, and making the computer again would lose
// what its browser keeps, so an operator updates its image.
test('a retained screen whose relay predates its scripts does nothing and asks for an operator', async t => {
  const screen = await stoppedScreen(t, 'sw-b1-c5');
  const old = createTcpServer(socket => { socket.on('error', () => {}); socket.once('data', () => socket.destroy()); });
  await listen(old);
  t.after(() => close(old));
  await wakeSprite('sw-b1-c5');
  screen.relay(old.address().port);
  const message = 'This computer\'s image is older than its screen tools, so nothing was done. Ask an operator to update it.';
  await assert.rejects(screen.visit(), { message });
  await assert.rejects(screen.capture(), { message });
  assert.deepEqual(screen.seen, [], 'no frame was taken');
});

// A probe the guest cannot run says nothing about the browser, so it is never
// taken for one that answered.
test('a just-woken retained screen whose readiness probe cannot run does nothing, saying so', async t => {
  const visiting = await stoppedScreen(t, 'sw-b1-c6', { spawnerEnv: { PATH: '/nonexistent' } });
  await assert.rejects(visiting.visit(), { message: NOT_CHECKED });
  const capturing = await stoppedScreen(t, 'sw-b1-c7', { spawnerEnv: { PATH: '/nonexistent' } });
  await assert.rejects(capturing.capture(), { message: NOT_CHECKED });
  assert.deepEqual(capturing.seen, [], 'no frame was taken');
});
const NOT_CHECKED = 'The screen\'s browser could not be checked (the readiness probe did not run), so nothing was done.';

// A probe that never answers (here a guest whose node hangs) times out on the
// bridge's socket: that is not checked, never up.
test('a just-woken retained screen whose readiness probe times out does nothing, saying so', async t => {
  const bin = await privateDir('omakase-screen-hang-');
  await writeFile(join(bin, 'node'), '#!/bin/sh\nexec sleep 600\n');
  await chmod(join(bin, 'node'), 0o755);
  const hanging = { spawnerEnv: { PATH: `${bin}:/usr/bin:/bin` }, waitMs: 1000 };
  const visiting = await stoppedScreen(t, 'sw-b1-c8', hanging);
  await assert.rejects(visiting.visit(), { message: NOT_CHECKED });
  const capturing = await stoppedScreen(t, 'sw-b1-c9', hanging);
  await assert.rejects(capturing.capture(), { message: NOT_CHECKED });
  assert.deepEqual(capturing.seen, [], 'no frame was taken');
});
