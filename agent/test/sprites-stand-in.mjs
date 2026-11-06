// A stand-in for the Sprites API on loopback, for the parts the bridge uses:
// look up and create a sprite, write a file, and exec over a WebSocket with
// Sprites' framing (one leading stream byte). Each sprite is a directory whose
// `home` is HOME for the commands it runs, which run on this machine. No
// Fly.io account, network or cost.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, writeFile, chmod } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { WebSocketServer } from 'ws';

export async function spritesStandIn(root, { token = 'synthetic-sprites-token' } = {}) {
  const sprites = new Set(), log = [], execs = new Set();
  const authorized = request => request.headers.authorization === `Bearer ${token}`;
  const homeOf = name => join(root, name, 'home');
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://stand-in');
    log.push(`${request.method} ${url.pathname}`);
    if (!authorized(request)) return void response.writeHead(401).end();
    const [, , , name, action, verb] = url.pathname.split('/');
    if (request.method === 'GET' && url.pathname === `/v1/sprites/${name}` && !action)
      return void response.writeHead(sprites.has(name) ? 200 : 404, { 'Content-Type': 'application/json' }).end(JSON.stringify({ name }));
    if (request.method === 'POST' && url.pathname === '/v1/sprites') {
      const body = JSON.parse(await text(request));
      sprites.add(body.name);
      await mkdir(homeOf(body.name), { recursive: true });
      return void response.writeHead(201, { 'Content-Type': 'application/json' }).end(JSON.stringify({ name: body.name }));
    }
    if (request.method === 'PUT' && action === 'fs' && verb === 'write' && sprites.has(name)) {
      const path = resolve(url.searchParams.get('path'));
      if (!path.startsWith(homeOf(name))) return void response.writeHead(403).end();
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, await bytes(request));
      await chmod(path, parseInt(url.searchParams.get('mode') ?? '0644', 8));
      return void response.writeHead(200).end();
    }
    response.writeHead(404).end();
  });
  const sockets = new WebSocketServer({ noServer: true });
  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url, 'http://stand-in');
    const name = url.pathname.split('/')[3];
    log.push(`WS ${url.pathname}`);
    if (!authorized(request) || !sprites.has(name) || url.pathname !== `/v1/sprites/${name}/exec`) return void socket.destroy();
    sockets.handleUpgrade(request, socket, head, ws => {
      const [command, ...args] = url.searchParams.getAll('cmd');
      const child = spawn(command, args, { cwd: homeOf(name), env: { PATH: '/usr/bin:/bin', HOME: homeOf(name) }, stdio: 'pipe' });
      execs.add(child);
      const send = (stream, data) => ws.readyState === ws.OPEN && ws.send(Buffer.concat([Buffer.from([stream]), data]));
      child.stdout.on('data', data => send(1, data));
      child.stderr.on('data', data => send(2, data));
      child.on('error', () => { send(3, Buffer.from([127])); ws.close(); });
      child.on('close', code => { execs.delete(child); send(3, Buffer.from([code ?? 1])); });
      ws.on('message', (data, binary) => {
        if (!binary || !data.length) return;
        if (data[0] === 0) child.stdin.write(data.subarray(1));
        if (data[0] === 4) child.stdin.end();
      });
      // A dropped connection ends the command, as a non-detachable Sprites exec.
      ws.on('close', () => child.exitCode === null && child.kill('SIGKILL'));
    });
  });
  await new Promise(done => server.listen(0, '127.0.0.1', done));
  return {
    url: `http://127.0.0.1:${server.address().port}`, token, log, sprites, homeOf,
    running: () => execs.size,
    async close() { for (const child of execs) child.kill('SIGKILL'); sockets.close(); await new Promise(done => server.close(done)); server.closeAllConnections?.(); }
  };
}

async function bytes(request) { const parts = []; for await (const part of request) parts.push(part); return Buffer.concat(parts); }
async function text(request) { return (await bytes(request)).toString('utf8'); }
