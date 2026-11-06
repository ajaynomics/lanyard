// Carries one pi-env daemon connection to a Sprite (agent/computers.mjs).
//
//   node sprites-bridge.mjs <sprite> serve --token <hex>
//
// pi-env's Connection starts this as it would `ssh host pi-env serve ...` and
// talks the daemon's protocol over our stdin and stdout. We make sure the
// Sprite exists, put the daemon this package ships on it (checked by its
// SHA-256 before it ever runs), then run it over a Sprites exec WebSocket and
// copy bytes both ways. Sprites frames each WebSocket message with one leading
// stream byte: 0 stdin, 1 stdout, 2 stderr, 3 exit (code in the next byte),
// 4 end of stdin (as @fly/sprites 0.2.4 does).
//
// An open WebSocket keeps a Sprite awake, and an awake Sprite is billed. So
// once no daemon request has been in flight for SPRITES_IDLE_MS we exit; the
// Connection treats that as a lost connection and starts us again on its next
// request.
//
// Reads SPRITES_TOKEN (required) and SPRITES_URL from the sidecar's
// environment. Nothing of that environment reaches the Sprite.
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import WebSocket from 'ws';
import { packagedDaemon } from '@earendil-works/pi-env';

const STDIN = 0, STDOUT = 1, STDERR = 2, EXIT = 3, STDIN_EOF = 4;
const [name, ...daemonArgs] = process.argv.slice(2);
const token = process.env.SPRITES_TOKEN;
const base = (process.env.SPRITES_URL || 'https://api.sprites.dev').replace(/\/+$/, '');
const idleMs = Number(process.env.SPRITES_IDLE_MS) || 60000;
const auth = { Authorization: `Bearer ${token}` };
const fail = message => { process.stderr.write(`sprites-bridge: ${message}\n`); process.exit(1); };
const sprite = `${base}/v1/sprites/${encodeURIComponent(name ?? '')}`;
const quote = text => `'${text.replaceAll("'", "'\\''")}'`;

async function request(url, init = {}) {
  const response = await fetch(url, { ...init, headers: { ...auth, ...init.headers }, signal: AbortSignal.timeout(120000) });
  return response;
}

// Opens an exec session; `onOutput(stream, bytes)` sees stdout and stderr.
function exec(cmd, { onOutput = () => {}, onOpen = () => {} } = {}) {
  const url = new URL(`${sprite.replace(/^http/, 'ws')}/exec`);
  for (const arg of cmd) url.searchParams.append('cmd', arg);
  url.searchParams.set('path', cmd[0]);
  url.searchParams.set('stdin', 'true');
  const socket = new WebSocket(url, { headers: auth });
  const exited = new Promise((resolve, reject) => {
    let code;
    socket.on('open', () => onOpen(socket));
    socket.on('message', (data, binary) => {
      if (!binary || data.length === 0) return;
      if (data[0] === STDOUT || data[0] === STDERR) onOutput(data[0], data.subarray(1));
      else if (data[0] === EXIT) { code = data.length > 1 ? data[1] : 0; socket.close(1000); resolve(code); }
    });
    socket.on('close', () => code === undefined && reject(new Error('exec closed without an exit code')));
    socket.on('error', reject);
  });
  return { socket, exited };
}

async function run(script) {
  const out = [];
  const code = await exec(['sh', '-c', script], { onOutput: (stream, bytes) => stream === STDOUT && out.push(bytes) }).exited;
  return { code, stdout: Buffer.concat(out).toString('utf8') };
}

async function ensureSprite() {
  const found = await request(sprite);
  if (found.ok) return;
  if (found.status !== 404) fail(`looking up the sprite failed (${found.status})`);
  const made = await request(`${base}/v1/sprites`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name }) });
  if (!made.ok) fail(`creating the sprite failed (${made.status})`);
}

const ARCH = { x86_64: 'x64', amd64: 'x64', aarch64: 'arm64', arm64: 'arm64' };
const HASH = 'hash() { sha256sum "$1" 2>/dev/null | cut -d" " -f1; }';

// The daemon's path on the Sprite, uploaded if it is missing or different.
async function ensureDaemon() {
  const probe = await run('printf "%s\\n%s\\n" "$HOME" "$(uname -m)"');
  const [home, machine] = probe.stdout.trim().split('\n');
  if (probe.code !== 0 || !home?.startsWith('/') || !ARCH[machine]) fail('the sprite did not report its home and architecture');
  const bytes = await readFile(packagedDaemon({ platform: 'linux', arch: ARCH[machine] }));
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const path = `${home}/.pi-env/pi-env-${sha256.slice(0, 32)}`;
  const check = `${HASH}; [ "$(hash ${quote(path)})" = ${sha256} ]`;
  if ((await run(check)).code === 0) return path;
  const upload = new URL(`${sprite}/fs/write`);
  upload.searchParams.set('path', `${path}.upload`);
  upload.searchParams.set('workingDir', home);
  upload.searchParams.set('mkdirParents', 'true');
  upload.searchParams.set('mode', '0700');
  const put = await request(upload, { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, body: bytes });
  if (!put.ok) fail(`uploading the daemon failed (${put.status})`);
  const install = `${HASH}; f=${quote(path)}; [ "$(hash "$f.upload")" = ${sha256} ] && chmod 700 "$f.upload" && mv "$f.upload" "$f"`;
  if ((await run(install)).code !== 0) fail('the uploaded daemon did not match its SHA-256');
  return path;
}

// Daemon frames: u32 length, u8 type, u32 request id, ... (pi-env
// docs/protocol.md). Requests (1) start work, results (2) and errors (3) end
// it; pings (6) are not activity. Before the daemon's sync line, stdout is
// not framed, so we only start reading frames after it.
function activity(onIdle) {
  const inFlight = new Set();
  let timer;
  const arm = () => { clearTimeout(timer); if (inFlight.size === 0) timer = setTimeout(onIdle, idleMs); };
  const reader = () => {
    let buffer = Buffer.alloc(0);
    return (chunk, each) => {
      buffer = Buffer.concat([buffer, chunk]);
      while (buffer.length >= 9) {
        const length = buffer.readUInt32BE(0);
        if (buffer.length < 4 + length) break;
        each(buffer[4], buffer.readUInt32BE(5));
        buffer = buffer.subarray(4 + length);
      }
    };
  };
  const fromClient = reader(), fromDaemon = reader();
  let synced = false, pending = Buffer.alloc(0);
  arm();
  return {
    client(chunk) {
      fromClient(chunk, (type, id) => { if (type === 1) { inFlight.add(id); arm(); } });
    },
    daemon(chunk) {
      if (!synced) {
        pending = Buffer.concat([pending, chunk]);
        const end = pending.indexOf('\n', pending.indexOf('PI-ENV '));
        if (pending.indexOf('PI-ENV ') < 0 || end < 0) return;
        synced = true;
        chunk = pending.subarray(end + 1);
      }
      fromDaemon(chunk, (type, id) => { if (type === 2 || type === 3) { inFlight.delete(id); arm(); } });
    }
  };
}

if (!token) fail('SPRITES_TOKEN is not set');
if (!name || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(name) || daemonArgs[0] !== 'serve') fail('usage: sprites-bridge.mjs <sprite> serve --token <hex>');
try {
  await ensureSprite();
  const daemon = await ensureDaemon();
  const watch = activity(() => process.exit(0));
  const { exited } = exec([daemon, ...daemonArgs], {
    onOutput: (stream, bytes) => {
      if (stream === STDERR) return void process.stderr.write(bytes);
      watch.daemon(bytes);
      process.stdout.write(bytes);
    },
    onOpen: socket => {
      process.stdin.on('data', chunk => { watch.client(chunk); socket.send(Buffer.concat([Buffer.from([STDIN]), chunk])); });
      process.stdin.on('end', () => socket.send(Buffer.from([STDIN_EOF])));
    }
  });
  process.exit(await exited);
} catch (error) {
  fail(error.message);
}
