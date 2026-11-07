// The relay of an agent's Sprite (Dockerfile.agent; agent/guest/entrypoint.sh
// starts it). It listens on $PORT and, for each connection that opens with
// the right secret, copies bytes both ways to the pi-env daemon it starts, to
// the screen's websockify on the guest's loopback, or to a command
// connector's process; agent/sprites-bridge.mjs is the other end.
//
//   first line from the bridge:  AGENT-RELAY <secret> <daemon token>\n
//                           or:  AGENT-SCREEN <secret>\n
//                           or:  AGENT-COMMAND <secret>\n{command, args, env, cwd}\n
//
// A command runs as this guest's user in its home folder (a relative cwd is
// inside it), with its stdin and stdout piped. When it exits, one closing
// line carries the end of its stderr (agent/command-connectors.mjs).
//
// The secret arrives in the Sprite's create-time environment
// (SPRITE_RELAY_SECRET); anything on the platform's network can reach this port, so
// a connection without it is closed before a daemon starts. Nothing here
// knows about conversations, models or Rails.
import { createServer, connect } from 'node:net';
import { spawn } from 'node:child_process';
import { timingSafeEqual } from 'node:crypto';
import { homedir } from 'node:os';
import { resolve } from 'node:path';

const secret = Buffer.from(process.env.SPRITE_RELAY_SECRET ?? '');
const daemon = process.env.PI_ENV_DAEMON || '/usr/local/bin/pi-env';
// The platform does not apply the image's ENV, so HOME may be unset.
const home = process.env.HOME || homedir();
const MAX_HELLO = 512;
// websockify, in front of the screen's VNC server.
const SCREEN_PORT = Number(process.env.SPRITE_SCREEN_PORT || 6080);

if (secret.length < 32) { console.error('sprite-relay: SPRITE_RELAY_SECRET is not set'); process.exit(1); }

const matches = given => {
  const bytes = Buffer.from(given);
  return bytes.length === secret.length && timingSafeEqual(bytes, secret);
};

// A command connector: the entry's line, then the command, piped.
const MAX_ENTRY = 64 * 1024;
const STDERR_CHARS = 500;
function command(socket, first) {
  let line = first;
  const onEntry = chunk => {
    line = Buffer.concat([line, chunk]);
    const end = line.indexOf('\n');
    if (end < 0) return void (line.length > MAX_ENTRY && socket.destroy());
    socket.off('data', onEntry);
    socket.pause();
    let entry;
    try { entry = JSON.parse(line.subarray(0, end).toString('utf8')); } catch { return void socket.destroy(); }
    const { SPRITE_RELAY_SECRET: _secret, ...guest } = process.env;
    let stderr = '', ended = false;
    const finish = code => {
      if (ended) return;
      ended = true;
      socket.end(`\n${JSON.stringify({ jsonrpc: '2.0', method: 'agent/exit', params: { code, stderr: stderr.slice(-STDERR_CHARS) } })}\n`);
    };
    // As in pi, a leading ~/ names the home folder.
    const homed = value => String(value).replace(/^~\//, `${home}/`);
    // Its own process group, so a wrapper's server (npx, uvx) stops with it.
    const child = spawn(homed(entry.command), Array.isArray(entry.args) ? entry.args.map(homed) : [], { detached: true,
      cwd: resolve(home, typeof entry.cwd === 'string' ? homed(entry.cwd) : '.'), env: { ...guest, HOME: home, ...entry.env },
      stdio: ['pipe', 'pipe', 'pipe'] });
    child.stdout.pipe(socket, { end: false });
    child.stderr.setEncoding('utf8').on('data', text => { stderr = (stderr + text).slice(-STDERR_CHARS * 4); });
    child.stdin.on('error', () => {});
    child.on('error', error => { stderr += error.message; finish(null); });
    child.on('close', finish);
    socket.on('close', () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} });
    const rest = line.subarray(end + 1);
    if (rest.length) child.stdin.write(rest);
    socket.pipe(child.stdin);
  };
  socket.on('data', onEntry);
  onEntry(Buffer.alloc(0));
}

const server = createServer(socket => {
  let hello = Buffer.alloc(0);
  socket.setTimeout(10000, () => socket.destroy());
  const onHello = chunk => {
    hello = Buffer.concat([hello, chunk]);
    const end = hello.indexOf('\n');
    if (end < 0) return void (hello.length > MAX_HELLO && socket.destroy());
    socket.off('data', onHello);
    socket.setTimeout(0);
    const [word, given, token] = hello.subarray(0, end).toString('utf8').split(' ');
    const rest = hello.subarray(end + 1);
    if (!given || !matches(given)) return void socket.destroy();
    if (word === 'AGENT-SCREEN' && token === undefined) {
      // Hold what follows the hello until websockify answers; pipe resumes it.
      socket.pause();
      const screen = connect(SCREEN_PORT, '127.0.0.1', () => { if (rest.length) screen.write(rest); socket.pipe(screen).pipe(socket); });
      screen.on('error', () => socket.destroy());
      socket.on('error', () => {});
      socket.on('close', () => screen.destroy());
      screen.on('close', () => socket.destroy());
      return;
    }
    if (word === 'AGENT-COMMAND' && token === undefined) return void command(socket, rest);
    if (word !== 'AGENT-RELAY' || !/^[0-9a-f]{16,128}$/.test(token ?? '')) return void socket.destroy();
    const child = spawn(daemon, ['serve', '--token', token], { cwd: home, env: { ...process.env, HOME: home }, stdio: ['pipe', 'pipe', 'inherit'] });
    child.on('error', error => { console.error(`sprite-relay: ${error.message}`); socket.destroy(); });
    child.stdout.pipe(socket);
    socket.pipe(child.stdin);
    if (rest.length) child.stdin.write(rest);
    socket.on('error', () => {});
    child.stdin.on('error', () => {});
    socket.on('close', () => child.exitCode === null && child.kill('SIGKILL'));
    child.on('close', () => socket.end());
  };
  socket.on('data', onHello);
  socket.on('error', () => {});
});

server.listen(Number(process.env.PORT ?? 8080), '0.0.0.0', () => console.log(`sprite-relay listening on ${server.address().port}`));
