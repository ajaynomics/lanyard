// A stand-in for a Sprites API on loopback, for the parts the bridge uses: look
// up, create, start and stop a sprite (and, as a platform's cold storage does,
// move a stopped one's disk away: state "cold", brought back by the same
// start), and its guest health. "Booting" a
// sprite runs the real agent/sprite-relay.mjs on this machine with the
// create-time env, and the real agent/guest/spawner.mjs with HOME the sprite's
// directory and the packaged pi-env daemon, behind a counting TCP pass-through
// that stands for the sprite's private address. Both run as this machine's
// user: which user each runs as is bin/check-computer-image's to check. No
// platform, network or cost.
import { createServer } from 'node:http';
import { createServer as createTcpServer, connect } from 'node:net';
import { spawn } from 'node:child_process';
import { mkdir, rm } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { localDaemon } from '@earendil-works/pi-env';

const RELAY = join(dirname(fileURLToPath(import.meta.url)), '..', 'sprite-relay.mjs');
const SPAWNER = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest', 'spawner.mjs');
// CI runs the tests as root, which the relay and spawner refuse on a Sprite.
const AS_ROOT = process.getuid?.() === 0 ? { SPRITE_TEST_AS_ROOT: '1' } : {};
// A Sprite's image has node on its PATH, in /usr/bin; this machine's may be
// elsewhere (CI's is in /usr/local/bin), so the guest's PATH starts with it.
const PATH = [...new Set([dirname(process.execPath), '/usr/bin', '/bin'])].join(':');
const FIELDS = new Set(['name', 'image', 'port', 'env', 'host_aliases', 'files', 'vcpu', 'mem_mib', 'disk_mib', 'pids_limit', 'idle_stop_after', 'idle_destroy_after']);

// `awake`: the scope's awake cap; creating or starting one more answers 429
// scope_capacity_exceeded, as the platform does. `guestEnv`: more of the
// relay's environment (where its screen listens, in tests); `spawnerEnv`, of
// the spawner's; `browserEnv`, when given, a second spawner's, the screen's
// script-only one (SPRITE_SPAWN_SCRIPTS, SPRITE_CDP_TOKEN, SPRITE_CDP_PORT),
// which the relay's AGENT-BROWSER reaches.
export async function spritesStandIn(root, { token = 'synthetic-sprites-token', image = 'registry.example/acme/durable-assistants-agent:test', awake = Infinity, guestEnv = {}, spawnerEnv = {}, browserEnv } = {}) {
  const sprites = new Map(), log = [], open = new Set();
  const full = () => [...sprites.values()].filter(sprite => sprite.state === 'running').length >= awake;
  const homeOf = name => join(root, name, 'home');

  async function boot(sprite) {
    await mkdir(homeOf(sprite.name), { recursive: true });
    // A Unix socket's path is short (108 bytes), so in the temp directory itself.
    const socket = join(tmpdir(), `spawn-${randomBytes(6).toString('hex')}.sock`);
    const spawner = spawn(process.execPath, [SPAWNER], {
      env: { PATH, HOME: homeOf(sprite.name), PI_ENV_DAEMON: localDaemon(), ...spawnerEnv, ...AS_ROOT, SPRITE_SPAWN_SOCKET: socket },
      stdio: ['ignore', 'pipe', 'inherit']
    });
    await listening(spawner, /spawner listening/);
    let browser, browserSocket;
    if (browserEnv) {
      browserSocket = join(tmpdir(), `browser-${randomBytes(6).toString('hex')}.sock`);
      browser = spawn(process.execPath, [SPAWNER], {
        env: { PATH, HOME: homeOf(sprite.name), USER: 'browser', ...browserEnv, ...AS_ROOT, SPRITE_SPAWN_SOCKET: browserSocket },
        stdio: ['ignore', 'pipe', 'inherit']
      });
      await listening(browser, /spawner listening/);
    }
    const relay = spawn(process.execPath, [RELAY], {
      env: { PATH, ...guestEnv, ...sprite.env, ...AS_ROOT, SPRITE_SPAWN_SOCKET: socket, PORT: '0',
        ...(browserSocket ? { SPRITE_BROWSER_SOCKET: browserSocket } : {}) },
      stdio: ['ignore', 'pipe', 'inherit']
    });
    const relayPort = Number((await listening(relay, /listening on (\d+)/))[1]);
    // The sprite's "private address": counts live connections.
    const front = createTcpServer(socket => {
      const back = connect(relayPort, '127.0.0.1');
      open.add(socket);
      socket.pipe(back).pipe(socket);
      const done = () => { open.delete(socket); socket.destroy(); back.destroy(); };
      socket.on('close', done); back.on('close', done); socket.on('error', done); back.on('error', done);
    });
    await new Promise(resolve => front.listen(0, '127.0.0.1', resolve));
    Object.assign(sprite, { state: 'running', relay, spawner, socket, browser, browserSocket, front, ip: '127.0.0.1', port: front.address().port });
  }

  async function halt(sprite, state = 'stopped') {
    sprite.relay?.kill('SIGKILL');
    sprite.spawner?.kill('SIGKILL');
    sprite.browser?.kill('SIGKILL');
    if (sprite.socket) await rm(sprite.socket, { force: true });
    if (sprite.browserSocket) await rm(sprite.browserSocket, { force: true });
    for (const socket of open) socket.destroy();
    await new Promise(resolve => sprite.front ? sprite.front.close(resolve) : resolve());
    Object.assign(sprite, { state, relay: undefined, spawner: undefined, socket: undefined, browser: undefined, browserSocket: undefined, front: undefined, ip: undefined });
  }

  const row = sprite => ({ name: sprite.name, state: sprite.state, ip: sprite.ip, port: sprite.port, image: sprite.image, mem_mib: sprite.mem_mib });
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://stand-in');
    log.push(`${request.method} ${url.pathname}`);
    const reply = (status, body) => void response.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify(body));
    if (request.headers.authorization !== `Bearer ${token}`) return reply(401, { code: 'bad_token' });
    const [, , , name, action] = url.pathname.split('/');
    if (request.method === 'POST' && url.pathname === '/v1/sprites') {
      const body = JSON.parse(await text(request));
      if (Object.keys(body).some(key => !FIELDS.has(key))) return reply(400, { code: 'bad_json' });
      if (body.image !== image) return reply(403, { code: 'network_policy_not_approved' });
      if (sprites.has(body.name)) return reply(409, { code: 'conflict' });
      if (full()) return reply(429, { code: 'scope_capacity_exceeded' });
      const sprite = { name: body.name, image: body.image, env: body.env ?? {}, created: body, mem_mib: body.mem_mib ?? 256, state: 'starting' };
      sprites.set(body.name, sprite);
      await boot(sprite);
      return reply(201, row(sprite));
    }
    const sprite = sprites.get(name);
    if (!sprite) return reply(404, { code: 'not_found' });
    if (request.method === 'GET' && !action) return reply(200, row(sprite));
    if (request.method === 'GET' && action === 'health') return reply(200, { entrypoint: sprite.state === 'running' ? 'running' : 'none', ready: true });
    if (request.method === 'POST' && action === 'start') {
      if (sprite.state !== 'running' && full()) return reply(429, { code: 'scope_capacity_exceeded' });
      if (sprite.state !== 'running') await boot(sprite);
      return reply(200, { state: 'running', ip: sprite.ip });
    }
    if (request.method === 'POST' && action === 'stop') { await halt(sprite); return reply(200, { state: 'stopped' }); }
    if (request.method === 'DELETE' && !action) { await halt(sprite); sprites.delete(name); return void response.writeHead(204).end(); }
    reply(404, { code: 'not_found' });
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  return {
    url: `http://127.0.0.1:${server.address().port}`, token, image, log, sprites, homeOf,
    connections: () => open.size,
    stop: name => halt(sprites.get(name)),
    // After 14 days stopped, the disk goes to cold storage.
    cold: name => halt(sprites.get(name), 'cold'),
    // An operator's resize on the host, which the platform's API has no call for.
    resize: (name, mib) => { sprites.get(name).mem_mib = mib; },
    async close() { for (const sprite of sprites.values()) await halt(sprite); await new Promise(done => server.close(done)); server.closeAllConnections?.(); }
  };
}

// The match of `pattern` in what the process prints once it listens.
function listening(child, pattern) {
  return new Promise((resolve, reject) => {
    let out = '';
    child.stdout.on('data', data => { out += data; const match = pattern.exec(out); if (match) resolve(match); });
    child.on('exit', () => reject(new Error(`${pattern} never printed`)));
  });
}

async function text(request) { const parts = []; for await (const part of request) parts.push(part); return Buffer.concat(parts).toString('utf8'); }
