// The agent's screen: Rails' websocket upgrade at /v1/conversations/:id/screen,
// carried by the real sidecar, bridge and relay to a stand-in websockify on
// the stand-in Sprite's loopback.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { createServer as createTcpServer, connect } from 'node:net';
import { createServer } from '../server.mjs';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { privateDir, eventually } from './processes.mjs';
import { railsStandIn } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';

const SIDECAR_TOKEN = 'sidecar-token-0123456789';

// websockify's part: answer the upgrade, then echo.
async function fakeWebsockify() {
  const seen = { requests: [], connections: 0 };
  const server = createTcpServer(socket => {
    seen.connections++;
    let buffer = '', upgraded = false;
    socket.on('data', chunk => {
      if (upgraded) return void socket.write(chunk);
      buffer += chunk;
      const end = buffer.indexOf('\r\n\r\n');
      if (end < 0) return;
      seen.requests.push(buffer.slice(0, end));
      upgraded = true;
      socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
      if (buffer.length > end + 4) socket.write(buffer.slice(end + 4));
    });
    socket.on('error', () => {});
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { seen, port: server.address().port, close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections?.(); }) };
}

function spritesEnv(t, values) {
  const saved = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  t.after(() => { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
}

// A raw websocket upgrade, as Rails sends it. Resolves with the socket and
// everything read once the response's head has arrived or the socket closed.
function upgrade(port, path, { token = SIDECAR_TOKEN } = {}) {
  return new Promise(resolve => {
    const socket = connect(port, '127.0.0.1', () => socket.write(`GET ${path} HTTP/1.1\r\nHost: sidecar.local\r\n` +
      `${token ? `Authorization: Bearer ${token}\r\n` : ''}Upgrade: websocket\r\nConnection: Upgrade\r\n` +
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'));
    let got = '';
    const done = () => resolve({ socket, got });
    socket.on('data', data => { got += data; if (got.includes('\r\n\r\n')) done(); });
    socket.on('close', done);
    socket.on('error', () => {});
  });
}

async function setup(t) {
  const root = await privateDir('omakase-screen-');
  const websockify = await fakeWebsockify();
  const api = await spritesStandIn(root, { guestEnv: { SPRITE_SCREEN_PORT: String(websockify.port) } });
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image, SPRITES_KEEPALIVE_MS: '100' });
  const cwd = await privateDir('omakase-screen-bot-');
  const app = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: SIDECAR_TOKEN, railsToken: 'rails-token-0123456789',
    sprites: { token: api.token, image: api.image } }, {
    ...scriptedProvider([message('hi')]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: railsStandIn().invoke, onComputerLog: () => {} });
  const { port } = await app.listen(0);
  t.after(async () => { await app.close(); await api.close(); await websockify.close(); });
  const { id } = await app.runtime.create({ actorId: 'alice', workspaceId: 'one', requestId: 'create' });
  const path = `/v1/conversations/${id}/screen?actorId=alice&workspaceId=one&computer=ss-b6`;
  return { api, websockify, port, id, path, name: `ss-b6-c${id}` };
}

test('the screen pipe needs the bearer and the owner, wakes the Sprite, rewrites the path, pipes bytes and keeps the Sprite awake while open', async t => {
  const f = await setup(t);

  assert.match((await upgrade(f.port, f.path, { token: null })).got, /^HTTP\/1.1 401/);
  assert.match((await upgrade(f.port, f.path.replace('actorId=alice', 'actorId=mallory'))).got, /^HTTP\/1.1 404/);
  assert.match((await upgrade(f.port, f.path.replace('computer=ss-b6', 'computer=Bad'))).got, /^HTTP\/1.1 422/);
  assert.equal(f.api.sprites.size, 0, 'nothing woken for a refused request');

  // The first open creates the agent's Sprite.
  const first = await upgrade(f.port, f.path);
  assert.match(first.got, /^HTTP\/1.1 101/);
  const [request] = f.websockify.seen.requests;
  assert.match(request, /^GET \/websockify HTTP\/1.1\r\n/);
  assert.doesNotMatch(request, /authorization/i);
  assert.match(request, /Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==/);
  const echoed = await new Promise(resolve => { first.socket.once('data', data => resolve(String(data))); first.socket.write('pixels'); });
  assert.equal(echoed, 'pixels');

  // While open, the bridge looks the Sprite up, which keeps it awake.
  const lookups = () => f.api.log.filter(line => line === `GET /v1/sprites/${f.name}`).length;
  const before = lookups();
  await new Promise(resolve => setTimeout(resolve, 500));
  assert.ok(lookups() >= before + 3, `kept awake (${before} -> ${lookups()})`);
  first.socket.destroy();
  assert.ok(await eventually(() => f.api.connections() === 0), 'closes the pipe to the Sprite');

  // A stopped Sprite is woken by opening its screen.
  await f.api.stop(f.name);
  const again = await upgrade(f.port, f.path);
  assert.match(again.got, /^HTTP\/1.1 101/);
  assert.equal(f.api.log.filter(line => line === `POST /v1/sprites/${f.name}/start`).length, 1);
  assert.equal(f.api.log.filter(line => line === 'POST /v1/sprites').length, 1);
  again.socket.destroy();
});

test('a Sprite whose disk is in cold storage is reported as cold without waking it, and opening its screen brings it back', async t => {
  const f = await setup(t);
  const query = 'actorId=alice&workspaceId=one&computer=ss-b6';
  const ask = async (q = query, token = SIDECAR_TOKEN) => {
    const response = await fetch(`http://127.0.0.1:${f.port}/v1/conversations/${f.id}/computer?${q}`, { headers: token ? { authorization: `Bearer ${token}` } : {} });
    return { status: response.status, body: await response.json() };
  };
  const calls = pattern => f.api.log.filter(line => pattern.test(line)).length;

  // An agent's first screen: there is no Sprite yet, so nothing to bring back.
  assert.deepEqual(await ask(), { status: 200, body: { waking: null } });
  assert.equal(f.api.sprites.size, 0, 'a lookup creates nothing');

  const running = await upgrade(f.port, f.path);
  running.socket.destroy();
  assert.deepEqual((await ask()).body, { waking: null });
  await f.api.stop(f.name);
  assert.deepEqual((await ask()).body, { waking: null }, 'stopped is not cold');

  await f.api.cold(f.name);
  const starts = () => calls(new RegExp(`^POST /v1/sprites/${f.name}/start$`));
  const before = starts();
  assert.deepEqual(await ask(), { status: 200, body: { waking: 'cold' } });
  assert.equal(starts(), before, 'a lookup wakes nothing');

  // The same start that wakes a stopped Sprite brings the disk back.
  const woken = await upgrade(f.port, f.path);
  assert.match(woken.got, /^HTTP\/1.1 101/);
  assert.equal(starts(), before + 1);
  assert.equal(f.api.sprites.get(f.name).state, 'running');
  assert.deepEqual((await ask()).body, { waking: null });
  woken.socket.destroy();

  assert.equal((await ask(query, null)).status, 401);
  assert.equal((await ask(query.replace('alice', 'mallory'))).status, 404);
  assert.equal((await ask(query.replace('ss-b6', 'Bad'))).status, 422);
});

test('the relay refuses a screen connection without the secret', async t => {
  const f = await setup(t);
  const opened = await upgrade(f.port, f.path);
  opened.socket.destroy();
  const before = f.websockify.seen.connections;
  const { port } = f.api.sprites.get(f.name);
  const answer = await new Promise(resolve => {
    const socket = connect(port, '127.0.0.1', () => socket.write(`AGENT-SCREEN ${'0'.repeat(64)}\r\nGET /websockify HTTP/1.1\r\n\r\n`));
    let got = '';
    socket.on('data', data => { got += data; });
    socket.on('close', () => resolve(got));
    socket.on('error', () => {});
  });
  assert.equal(answer, '');
  assert.equal(f.websockify.seen.connections, before, 'websockify never reached');
});

test('a deleted agent\'s Sprite is deleted with its disk, by Rails with the bearer and the owner, and deleting it again is fine', async t => {
  const f = await setup(t);
  const query = 'actorId=alice&workspaceId=one&computer=ss-b6';
  const remove = async (q = query, token = SIDECAR_TOKEN) => {
    const response = await fetch(`http://127.0.0.1:${f.port}/v1/conversations/${f.id}/computer?${q}`,
      { method: 'DELETE', headers: token ? { authorization: `Bearer ${token}` } : {} });
    return { status: response.status, body: await response.json() };
  };
  const running = await upgrade(f.port, f.path);
  running.socket.destroy();
  assert.ok(f.api.sprites.has(f.name));

  assert.equal((await remove(query, null)).status, 401);
  assert.equal((await remove(query.replace('actorId=alice', 'actorId=mallory'))).status, 404);
  assert.equal((await remove(query.replace('computer=ss-b6', 'computer=Bad'))).status, 422);
  assert.ok(f.api.sprites.has(f.name), 'a refused request deletes nothing');

  assert.deepEqual(await remove(), { status: 200, body: { removed: true } });
  assert.equal(f.api.sprites.has(f.name), false);
  assert.equal(f.api.log.filter(line => line === `DELETE /v1/sprites/${f.name}`).length, 1);
  assert.deepEqual(await remove(), { status: 200, body: { removed: true } }, 'already gone');
  assert.equal(f.api.log.filter(line => line === 'POST /v1/sprites').length, 1, 'nothing made it again');
});
