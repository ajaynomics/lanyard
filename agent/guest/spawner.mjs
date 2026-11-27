// The agent's half of its Sprite's relay (agent/sprite-relay.mjs is the
// other). It runs as `agent` (agent/guest/entrypoint.sh) and starts, as that
// user, the pi-env daemon and command connectors the relay asks for. It listens
// on a Unix socket in a directory only `agent` and `relay` can enter
// (SPRITE_SPAWN_SOCKET), and holds no secret: the relay checks the platform's
// secret before it passes a connection on, and the agent may already run as
// itself anything this starts.
//
//   first line from the relay:  AGENT-RELAY <daemon token>\n
//                           or:  AGENT-COMMAND\n{command, args, env, cwd}\n
//
// A command runs in the home folder (a relative cwd is inside it), with its
// stdin and stdout piped. When it exits, one closing line carries the end of
// its stderr (agent/command-connectors.mjs).
//
// What it starts gets a fixed environment, built here from named values,
// never this process's own: a secret that reached this process by mistake
// still reaches nothing it starts.
//
// A second one runs as `browser` (#60), on /run/browser-spawn/browser.sock, for
// the relay's AGENT-BROWSER: with SPRITE_SPAWN_SCRIPTS (the scripts it may run,
// separated by colons) it runs only `node <one of them>`, passes on only
// AGENT_* variables (a sign-in or a card), starts no daemon, and gives each the
// screen's DevTools address with its token (agent/guest/cdp.mjs) as AGENT_CDP,
// once it has seen that the port is held by its own user, so a script never
// sends a page's fields to a port the agent took.
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { readFileSync, rmSync } from 'node:fs';

// It reads what the agent sends; never as root.
// SPRITE_TEST_AS_ROOT: the sidecar's tests, when CI runs them as root; the
// entrypoint's fixed environment (env -i) never carries it onto a Sprite.
if (process.getuid?.() === 0 && process.env.SPRITE_TEST_AS_ROOT !== '1') { console.error('spawner: refusing to run as root'); process.exit(1); }
const socketPath = process.env.SPRITE_SPAWN_SOCKET || '/run/spawn/agent.sock';
const daemon = process.env.PI_ENV_DAEMON || '/usr/local/bin/pi-env';
const home = process.env.HOME || homedir();
const user = process.env.USER || 'agent';
const scripts = process.env.SPRITE_SPAWN_SCRIPTS ? process.env.SPRITE_SPAWN_SCRIPTS.split(':') : null;
const cdpPort = Number(process.env.SPRITE_CDP_PORT || 9222);
const cdpToken = process.env.SPRITE_CDP_TOKEN ?? '';
const childEnv = Object.freeze({
  HOME: home, USER: user, LOGNAME: user, SHELL: '/bin/sh',
  PATH: process.env.PATH || '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  DISPLAY: process.env.DISPLAY || ':99', TZ: process.env.TZ || 'UTC',
  // No install or update telemetry from any pi a command connector runs.
  PI_TELEMETRY: '0'
});
const MAX_HELLO = 512;
const MAX_ENTRY = 64 * 1024;
const STDERR_CHARS = 500;

// Whether 127.0.0.1:<cdpPort> is listened on by this process's own user, by
// the kernel's account (/proc/net/tcp: address, state 0A listening, uid).
function cdpHeld() {
  const address = `0100007F:${cdpPort.toString(16).toUpperCase().padStart(4, '0')}`;
  try {
    return readFileSync('/proc/net/tcp', 'utf8').split('\n').slice(1).map(line => line.trim().split(/\s+/))
      .some(fields => fields[1] === address && fields[3] === '0A' && Number(fields[7]) === process.getuid());
  } catch { return false; }
}

// What a script-only spawner runs: argv and environment, or null when refused.
function scripted(entry) {
  const [script, ...args] = Array.isArray(entry.args) ? entry.args.map(String) : [];
  if (entry.command !== 'node' || !scripts.includes(script)) return null;
  const env = Object.fromEntries(Object.entries(entry.env ?? {}).filter(([name]) => /^AGENT_[A-Z_]+$/.test(name) && name !== 'AGENT_CDP')
    .map(([name, value]) => [name, String(value)]));
  // Not held: no script runs, and the caller hears what a script says
  // when the screen's browser is not there (exit 3).
  if (!cdpToken || !cdpHeld()) return { unheld: true };
  env.AGENT_CDP = `http://127.0.0.1:${cdpPort}/${cdpToken}`;
  return { command: process.execPath, args: [script, ...args], env };
}

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
    if (scripts) {
      const allowed = scripted(entry ?? {});
      if (!allowed) return void socket.destroy();
      if (allowed.unheld) return void socket.end(`${JSON.stringify({ jsonrpc: '2.0', method: 'agent/exit',
        params: { code: 3, stderr: 'The screen\'s browser is not running.' } })}\n`);
      entry = { ...allowed, cwd: '.' };
    }
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
      cwd: resolve(home, typeof entry.cwd === 'string' ? homed(entry.cwd) : '.'), env: { ...childEnv, ...entry.env },
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

// pi-env serve takes its token only as an argument (`--token <hex>`, its only
// form in 1.6.0), and any user on the guest reads a process's arguments in
// /proc/<pid>/cmdline. So the daemon gets a token made here, and its first
// line, `PI-ENV <that token>`, reaches the sidecar as `PI-ENV <the sidecar's>`.
function relay(socket, token, rest) {
  const own = randomBytes(16).toString('hex');
  const child = spawn(daemon, ['serve', '--token', own], { cwd: home, env: childEnv, stdio: ['pipe', 'pipe', 'inherit'] });
  child.on('error', error => { console.error(`spawner: ${error.message}`); socket.destroy(); });
  const marker = Buffer.from(`PI-ENV ${own}\n`);
  let head = Buffer.alloc(0);
  const onFirst = chunk => {
    head = Buffer.concat([head, chunk]);
    const at = head.indexOf(marker);
    // As pi-env's client does, what comes before the line is dropped.
    if (at < 0) return void (head.length > MAX_ENTRY && socket.destroy());
    child.stdout.off('data', onFirst);
    socket.write(`PI-ENV ${token}\n`);
    const after = head.subarray(at + marker.length);
    if (after.length) socket.write(after);
    child.stdout.pipe(socket);
  };
  child.stdout.on('data', onFirst);
  socket.pipe(child.stdin);
  if (rest.length) child.stdin.write(rest);
  child.stdin.on('error', () => {});
  socket.on('close', () => child.exitCode === null && child.kill('SIGKILL'));
  child.on('close', () => socket.end());
}

const server = createServer(socket => {
  let hello = Buffer.alloc(0);
  socket.on('error', () => {});
  const onHello = chunk => {
    hello = Buffer.concat([hello, chunk]);
    const end = hello.indexOf('\n');
    if (end < 0) return void (hello.length > MAX_HELLO && socket.destroy());
    socket.off('data', onHello);
    const [word, token, extra] = hello.subarray(0, end).toString('utf8').split(' ');
    const rest = hello.subarray(end + 1);
    if (word === 'AGENT-COMMAND' && token === undefined) return void command(socket, rest);
    if (word === 'AGENT-RELAY' && !scripts && extra === undefined && /^[0-9a-f]{16,128}$/.test(token ?? '')) return void relay(socket, token, rest);
    socket.destroy();
  };
  socket.on('data', onHello);
});

rmSync(socketPath, { force: true });
// The directory, not the socket's mode, decides who may connect.
server.listen({ path: socketPath, readableAll: true, writableAll: true }, () => console.log(`spawner listening on ${socketPath}`));
