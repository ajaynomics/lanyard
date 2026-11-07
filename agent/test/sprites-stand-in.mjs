// A stand-in for Ajay's Sprites API on loopback (an existing
// docs/sprites-developer-cheatsheet.md), for the parts the bridge uses: look
// up, create, start and stop a sprite (and, as an existing cold storage does,
// move a stopped one's disk away: state "cold", brought back by the same
// start), and its guest health. "Booting" a
// sprite runs the real agent/sprite-relay.mjs on this machine with the
// create-time env, HOME the sprite's directory and the packaged pi-env daemon,
// behind a counting TCP pass-through that stands for the sprite's private
// address. No platform, network or cost.
import { createServer } from 'node:http';
import { createServer as createTcpServer, connect } from 'node:net';
import { spawn } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { localDaemon } from '@earendil-works/pi-env';

const RELAY = join(dirname(fileURLToPath(import.meta.url)), '..', 'sprite-relay.mjs');
const FIELDS = new Set(['name', 'image', 'port', 'env', 'host_aliases', 'files', 'vcpu', 'mem_mib', 'disk_mib', 'pids_limit', 'idle_stop_after', 'idle_destroy_after']);

// `awake`: the scope's awake cap; creating or starting one more answers 429
// scope_capacity_exceeded, as the platform does. `guestEnv`: more of the
// guest's own environment (where its screen listens, in tests).
export async function spritesStandIn(root, { token = 'synthetic-sprites-token', image = 'gitea.example.com/ajaynomics/durable-assistants-agent:test', awake = Infinity, guestEnv = {} } = {}) {
  const sprites = new Map(), log = [], open = new Set();
  const full = () => [...sprites.values()].filter(sprite => sprite.state === 'running').length >= awake;
  const homeOf = name => join(root, name, 'home');

  async function boot(sprite) {
    await mkdir(homeOf(sprite.name), { recursive: true });
    const relay = spawn(process.execPath, [RELAY], {
      env: { PATH: '/usr/bin:/bin', HOME: homeOf(sprite.name), PI_ENV_DAEMON: localDaemon(), ...guestEnv, ...sprite.env, PORT: '0' },
      stdio: ['ignore', 'pipe', 'inherit']
    });
    const relayPort = await new Promise((resolve, reject) => {
      relay.stdout.on('data', data => { const port = /listening on (\d+)/.exec(String(data))?.[1]; if (port) resolve(Number(port)); });
      relay.on('exit', () => reject(new Error('relay exited')));
    });
    // The sprite's "private address": counts live connections.
    const front = createTcpServer(socket => {
      const back = connect(relayPort, '127.0.0.1');
      open.add(socket);
      socket.pipe(back).pipe(socket);
      const done = () => { open.delete(socket); socket.destroy(); back.destroy(); };
      socket.on('close', done); back.on('close', done); socket.on('error', done); back.on('error', done);
    });
    await new Promise(resolve => front.listen(0, '127.0.0.1', resolve));
    Object.assign(sprite, { state: 'running', relay, front, ip: '127.0.0.1', port: front.address().port });
  }

  async function halt(sprite, state = 'stopped') {
    sprite.relay?.kill('SIGKILL');
    for (const socket of open) socket.destroy();
    await new Promise(resolve => sprite.front ? sprite.front.close(resolve) : resolve());
    Object.assign(sprite, { state, relay: undefined, front: undefined, ip: undefined });
  }

  const row = sprite => ({ name: sprite.name, state: sprite.state, ip: sprite.ip, port: sprite.port, image: sprite.image });
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
      const sprite = { name: body.name, image: body.image, env: body.env ?? {}, created: body, state: 'starting' };
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
    reply(404, { code: 'not_found' });
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  return {
    url: `http://127.0.0.1:${server.address().port}`, token, image, log, sprites, homeOf,
    connections: () => open.size,
    stop: name => halt(sprites.get(name)),
    // After 14 days stopped, the disk goes to cold storage.
    cold: name => halt(sprites.get(name), 'cold'),
    async close() { for (const sprite of sprites.values()) await halt(sprite); await new Promise(done => server.close(done)); server.closeAllConnections?.(); }
  };
}

async function text(request) { const parts = []; for await (const part of request) parts.push(part); return Buffer.concat(parts).toString('utf8'); }
