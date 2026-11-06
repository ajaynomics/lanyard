// Carries one pi-env daemon connection to a bot's Sprite (agent/computers.mjs).
//
//   node sprites-bridge.mjs <sprite> serve --token <hex>
//
// pi-env's Connection starts this as it would `ssh host pi-env serve ...` and
// talks the daemon's protocol over our stdin and stdout. The Sprite is a
// microVM on Ajay's own Sprites platform (an existing
// docs/sprites-developer-cheatsheet.md). Its image (Dockerfile.agent) runs
// agent/sprite-relay.mjs, which starts the daemon for a TCP connection that
// opens with the right secret. We do the cheatsheet's "resume": look the
// Sprite up, create it if missing, start it if stopped, wait until its
// entrypoint runs, then connect to its private address and copy bytes.
//
// Direct traffic is not activity to the platform, so while connected we look
// the Sprite up once a minute to keep it from being stopped under us. Once no
// daemon request has been in flight for SPRITES_IDLE_MS we exit; the platform
// stops the Sprite after its own idle time, and the Connection starts us again
// on its next request.
//
// Reads SPRITES_TOKEN, SPRITES_URL and SPRITES_IMAGE from the sidecar's
// environment. The Sprite gets only PORT and the relay secret, which is
// derived from the token, so no new secret is stored anywhere.
import { createHmac } from 'node:crypto';
import { connect } from 'node:net';

const [name, ...daemonArgs] = process.argv.slice(2);
const token = process.env.SPRITES_TOKEN;
const image = process.env.SPRITES_IMAGE;
const base = (process.env.SPRITES_URL || 'https://sprites.example.com').replace(/\/+$/, '');
const idleMs = Number(process.env.SPRITES_IDLE_MS) || 60000;
const keepAliveMs = Number(process.env.SPRITES_KEEPALIVE_MS) || 60000;
const bootMs = Number(process.env.SPRITES_BOOT_MS) || 180000;
const PORT = 8080;
const fail = message => { process.stderr.write(`sprites-bridge: ${message}\n`); process.exit(1); };
const sprite = `${base}/v1/sprites/${encodeURIComponent(name ?? '')}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// What the Sprite is made with. A bot keeps its files across quiet weeks; the
// platform stops it after half an hour without use and keeps the disk.
const CREATE = {
  port: PORT, vcpu: 1, mem_mib: 1024, disk_mib: 4096, idle_stop_after: '30m', idle_destroy_after: '30d'
};

const relaySecret = (spritesToken, spriteName) =>
  createHmac('sha256', spritesToken).update(`avery sprite relay ${spriteName}`).digest('hex');

async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(`${sprite}${path}`.replace(/\/$/, ''), {
    method, signal: AbortSignal.timeout(bootMs),
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined
  });
  const text = await response.text();
  let json = {};
  try { json = text ? JSON.parse(text) : {}; } catch {}
  return { status: response.status, ok: response.ok, json };
}

const explain = (what, reply) => `${what} failed (${reply.status}${reply.json.code ? ` ${reply.json.code}` : ''})`;

// The Sprite's row once its entrypoint is running: {ip, port}.
async function ensureRunning() {
  let row = await api('');
  if (row.status === 404) {
    const made = await fetch(`${base}/v1/sprites`, {
      method: 'POST', signal: AbortSignal.timeout(bootMs),
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, image, ...CREATE, env: { PORT: String(PORT), SPRITE_RELAY_SECRET: relaySecret(token, name) } })
    });
    const reply = { status: made.status, ok: made.ok, json: await made.json().catch(() => ({})) };
    // Another bridge may have created it a moment ago.
    if (!reply.ok && reply.json.code !== 'conflict') fail(explain('creating the sprite', reply));
    row = await api('');
  }
  if (!row.ok) fail(explain('looking up the sprite', row));
  if (row.json.state === 'stopped') {
    // A Sprite that failed to boot stays stopped until deleted, which would
    // lose the bot's files; that is an operator's call, not ours.
    const started = await api('/start', { method: 'POST' });
    if (!started.ok) fail(explain('starting the sprite', started));
  }
  const deadline = Date.now() + bootMs;
  for (;;) {
    const health = await api('/health');
    if (health.ok && health.json.entrypoint === 'running') break;
    if (Date.now() > deadline) fail('the sprite did not start its relay in time');
    await sleep(1000);
  }
  row = await api('');
  if (!row.ok || !row.json.ip) fail(explain('reading the sprite address', row));
  return { ip: row.json.ip, port: Number(row.json.port) || PORT };
}

// The relay may still be binding its port just after the entrypoint starts.
async function open({ ip, port }) {
  const deadline = Date.now() + 30000;
  for (;;) {
    try {
      return await new Promise((resolve, reject) => {
        const socket = connect({ host: ip, port }, () => { socket.off('error', reject); resolve(socket); });
        socket.once('error', reject);
      });
    } catch (error) {
      if (Date.now() > deadline) throw error;
      await sleep(500);
    }
  }
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

const daemonToken = daemonArgs[0] === 'serve' && daemonArgs[1] === '--token' ? daemonArgs[2] : undefined;
if (!token) fail('SPRITES_TOKEN is not set');
if (!image) fail('SPRITES_IMAGE is not set');
if (!name || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(name) || !/^[0-9a-f]{16,128}$/.test(daemonToken ?? ''))
  fail('usage: sprites-bridge.mjs <sprite> serve --token <hex>');
try {
  const socket = await open(await ensureRunning());
  const keepAlive = setInterval(() => api('').catch(() => {}), keepAliveMs);
  const watch = activity(() => { clearInterval(keepAlive); socket.destroy(); process.exit(0); });
  socket.write(`AVERY-RELAY ${relaySecret(token, name)} ${daemonToken}\n`);
  socket.on('data', chunk => { watch.daemon(chunk); process.stdout.write(chunk); });
  process.stdin.on('data', chunk => { watch.client(chunk); socket.write(chunk); });
  process.stdin.on('end', () => socket.end());
  socket.on('error', error => fail(`the connection to the sprite failed: ${error.message}`));
  socket.on('close', () => { clearInterval(keepAlive); process.exit(0); });
} catch (error) {
  fail(error.message);
}
