// Carries one pi-env daemon connection to an agent's Sprite (agent/computers.mjs).
//
//   node sprites-bridge.mjs <sprite> serve --token <hex>
//   node sprites-bridge.mjs <sprite> wake [--size <cpus>,<memory MiB>,<disk MiB>]
//                                              (wake it, made at that size if missing, then exit 0)
//   node sprites-bridge.mjs <sprite> state     (print its state without waking it)
//   node sprites-bridge.mjs <sprite> destroy   (delete it and its disk; gone already is fine)
//   node sprites-bridge.mjs <sprite> remake [--size <cpus>,<memory MiB>,<disk MiB>]
//                                              (delete it and its disk, then make it again at that size, else with its memory)
//   node sprites-bridge.mjs <sprite> screen    (a pipe to its screen's websockify)
//   node sprites-bridge.mjs <sprite> command   (a pipe to a command connector's process)
//   node sprites-bridge.mjs <sprite> desk      (one desktop action in, its answer out)
//   node sprites-bridge.mjs <sprite> browser   (one screen script's entry in, its output out;
//                                               exit 3: the Sprite's relay predates it;
//                                               desk --existing too)
//   desk and browser exit 4 when the Sprite they woke has no screen's browser in time,
//   or its readiness could not be checked.
//   screen, desk and browser accept --existing to wake and connect by name, never create.
//
// pi-env's Connection starts this as it would `ssh host pi-env serve ...` and
// talks the daemon's protocol over our stdin and stdout. The Sprite is a
// microVM on a Sprites platform (SPRITES_URL). Its image (Dockerfile.agent) runs
// agent/sprite-relay.mjs, which starts the daemon for a TCP connection that
// opens with the right secret. We do the platform's "resume": look the
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
const base = (process.env.SPRITES_URL || '').replace(/\/+$/, '');
const idleMs = Number(process.env.SPRITES_IDLE_MS) || 60000;
const keepAliveMs = Number(process.env.SPRITES_KEEPALIVE_MS) || 60000;
// A wake may take up to two minutes (a disk brought back from cold storage).
const bootMs = Number(process.env.SPRITES_BOOT_MS) || 120000;
// A Sprite's relay answers seconds before its screen's browser does, so a
// desktop action or screen script on a Sprite just woken first waits this
// long, at most, for DevTools on the guest's loopback.
const screenWaitMs = Number(process.env.SPRITES_SCREEN_WAIT_MS) || 20000;
const cdpPort = Number(process.env.SPRITES_CDP_PORT) || 9222;
const PORT = 8080;
const fail = message => { process.stderr.write(`sprites-bridge: ${message}\n`); process.exit(1); };
const sprite = `${base}/v1/sprites/${encodeURIComponent(name ?? '')}`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

// What an agent's Sprite is made with, which cannot be changed later. It is
// asleep after an hour without use and never deleted ('0'); the platform's
// cold storage moves a disk asleep for 14 days and brings it back on wake.
const CREATE = { port: PORT, idle_stop_after: '1h', idle_destroy_after: '0' };
// Its size when Rails sends none: the install's default, Computer::Size.default.
const DEFAULT_SIZE = { vcpu: 2, mem_mib: 2048, disk_mib: 8192 };

const relaySecret = (spritesToken, spriteName) =>
  createHmac('sha256', spritesToken).update(`agent sprite relay ${spriteName}`).digest('hex');

async function api(path, { method = 'GET', body } = {}) {
  const response = await fetch(`${sprite}${path}`.replace(/\/$/, ''), {
    method, signal: AbortSignal.timeout(bootMs),
    ...(existing ? { redirect: 'manual' } : {}),
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined
  });
  const text = await response.text();
  let json = {};
  try { json = text ? JSON.parse(text) : {}; } catch {}
  return { status: response.status, ok: response.ok, json };
}

const explain = (what, reply) => `${what} failed (${reply.status}${reply.json.code ? ` ${reply.json.code}` : ''})`;

function checkExisting(row) {
  if (existing && (!row.ok || (Object.hasOwn(row.json ?? {}, 'name') && row.json.name !== name)))
    fail('retained Sprite unavailable');
}

function relayAddress(row) {
  checkExisting(row);
  if (!row.ok || !row.json.ip) fail(explain('reading the sprite address', row));
  return { ip: row.json.ip, port: Number(row.json.port) || PORT };
}

// A missing Sprite is made at `size` only on the ordinary path.
async function ensureRunning(size = DEFAULT_SIZE) {
  let row = await api(''), woke = false;
  checkExisting(row);
  if (row.status === 404) {
    woke = true;
    const made = await fetch(`${base}/v1/sprites`, {
      method: 'POST', signal: AbortSignal.timeout(bootMs),
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, image, ...CREATE, ...size, env: { PORT: String(PORT), SPRITE_RELAY_SECRET: relaySecret(token, name) } })
    });
    const reply = { status: made.status, ok: made.ok, json: await made.json().catch(() => ({})) };
    // Another bridge may have created it a moment ago.
    if (!reply.ok && reply.json.code !== 'conflict') fail(explain('creating the sprite', reply));
    row = await api('');
  }
  if (!row.ok) fail(explain('looking up the sprite', row));
  if (row.json.state !== 'running') woke = true;
  // A disk in cold storage comes back through the same start.
  if (row.json.state === 'stopped' || row.json.state === 'cold') {
    // A Sprite that failed to boot stays stopped until deleted, which would
    // lose the agent's files; that is an operator's call, not ours.
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
  return { ...relayAddress(await api('')), woke };
}

// Whether the screen's browser answers DevTools, waited for once, within
// screenWaitMs, by a probe the agent's own spawner runs on the guest. Any
// answer will do: cdp.mjs gives one without its token 404, an older image's
// Chromium its version; refused means not up yet. A relay that hangs up
// without a byte predates AGENT-COMMAND, so the call itself says the computer is
// too old; a socket that times out is not checked, never up. A probe that could not run (no node, say) knows nothing of the browser
// and is never taken for one that answered.
const PROBE = 'const [port, ms] = process.argv.slice(1).map(Number); setTimeout(() => process.exit(4), ms);' +
  'const ask = () => fetch(`http://127.0.0.1:${port}/json/version`).then(() => process.exit(0), () => setTimeout(ask, 250)); ask();';
async function screenUp(address) {
  const socket = await open(address);
  socket.write(`AGENT-COMMAND ${relaySecret(token, name)}\n${JSON.stringify({ command: 'node', args: ['-e', PROBE, String(cdpPort), String(screenWaitMs)] })}\n`);
  let answer = '', heard = false, timedOut = false, failed = false;
  socket.setTimeout(screenWaitMs + 10000, () => { timedOut = true; socket.destroy(); });
  socket.on('data', chunk => { heard = true; answer = (answer + chunk).slice(-4096); });
  // A reset is how a relay that reads only its hello hangs up on the rest.
  socket.on('error', error => { if (!['ECONNRESET', 'EPIPE'].includes(error.code)) failed = true; });
  await new Promise(resolve => socket.on('close', resolve));
  // Only a relay that hung up without a byte is an old one; a timeout, another
  // error or an answer without an exit says nothing of the browser.
  if (!heard && !timedOut && !failed) return 'up';
  const code = answer.match(/"method":"agent\/exit","params":\{"code":(\w+)/)?.[1];
  return timedOut || failed ? 'not checked' : code === '0' ? 'up' : code === '4' ? 'not started' : 'not checked';
}

// What a desktop action or screen script on the Sprite needs first: its
// relay, and on a Sprite just woken its screen's browser too (exit 4).
async function screenReady() {
  const address = await ensureRunning();
  const state = address.woke ? await screenUp(address) : 'up';
  if (state === 'not started') {
    process.stderr.write(`The screen's browser did not start within ${Math.round(screenWaitMs / 1000)} s.\n`);
    process.exit(4);
  }
  if (state === 'not checked') {
    process.stderr.write('The screen\'s browser could not be checked (the readiness probe did not run), so nothing was done.\n');
    process.exit(4);
  }
  return address;
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
      if (existing) ({ ip, port } = relayAddress(await api('')));
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
// `wake` and `remake` may say the size to make it at, as "<cpus>,<memory MiB>,<disk MiB>".
const sized = mode => daemonArgs[0] === mode &&
  (daemonArgs.length === 1 || (daemonArgs.length === 3 && daemonArgs[1] === '--size' && /^[1-9][0-9]{0,8}(,[1-9][0-9]{0,8}){2}$/.test(daemonArgs[2])));
const [vcpu, mem_mib, disk_mib] = daemonArgs.length === 3 ? daemonArgs[2].split(',').map(Number) : [];
const size = vcpu ? { vcpu, mem_mib, disk_mib } : undefined;
const waking = sized('wake');
const looking = daemonArgs.length === 1 && daemonArgs[0] === 'state';
const destroying = daemonArgs.length === 1 && daemonArgs[0] === 'destroy';
const remaking = sized('remake');
const [mode, option] = daemonArgs;
const existing = daemonArgs.length === 2 && option === '--existing' && ['screen', 'desk', 'browser'].includes(mode);
const view = kind => mode === kind && (daemonArgs.length === 1 || existing);
const screen = view('screen');
const command = daemonArgs.length === 1 && mode === 'command';
const desk = view('desk');
const browser = view('browser');
if (!token) fail('SPRITES_TOKEN is not set');
if (!base) fail('SPRITES_URL is not set');
if (!image) fail('SPRITES_IMAGE is not set');
if (!name || !/^[a-z0-9][a-z0-9-]{0,62}$/.test(name) || (daemonArgs.includes('--existing') && !existing) ||
    !(waking || looking || destroying || remaking || screen || command || desk || browser || /^[0-9a-f]{16,128}$/.test(daemonToken ?? '')))
  fail('usage: sprites-bridge.mjs <sprite> serve --token <hex> | wake [--size c,m,d] | state | destroy | remake [--size c,m,d] | command | {screen,desk,browser} [--existing]');
if (waking) { await ensureRunning(size); process.exit(0); }
// Its agent was deleted. The platform keeps a Sprite made with
// idle_destroy_after '0' forever, so this is the only way it goes.
if (destroying) {
  const gone = await api('', { method: 'DELETE' });
  if (!gone.ok && gone.status !== 404) fail(explain('deleting the sprite', gone));
  process.exit(0);
}
// An operator rebuilds it with the agent's computer held, at the agent's
// size when given it (docs/agent.md). Without one, its memory may have been
// raised by hand on the host, which a create would otherwise put back.
if (remaking) {
  const old = await api('');
  if (!old.ok && old.status !== 404) fail(explain('looking up the sprite', old));
  const memory = Number.isInteger(old.json.mem_mib) && old.json.mem_mib > 0 ? old.json.mem_mib : DEFAULT_SIZE.mem_mib;
  const gone = await api('', { method: 'DELETE' });
  if (!gone.ok && gone.status !== 404) fail(explain('deleting the sprite', gone));
  await ensureRunning(size ?? { ...DEFAULT_SIZE, mem_mib: memory });
  // Said aloud: a platform that reports no size gets the default, which the
  // operator may need to raise again.
  console.log(size ? `remade with ${size.vcpu} CPUs, ${size.mem_mib} MiB of memory and ${size.disk_mib} MiB of disk, as asked` :
    `remade with ${memory} MiB${memory === old.json.mem_mib ? '' : ' (the default: the platform reported no size)'}`);
  process.exit(0);
}
// `cold`: its disk is in cold storage, and a wake takes up to a minute.
if (looking) {
  const row = await api('');
  if (!row.ok && row.status !== 404) fail(explain('looking up the sprite', row));
  process.stdout.write(`${row.status === 404 ? 'missing' : row.json.state ?? 'unknown'}\n`);
  process.exit(0);
}
// The screen, a command connector's process (its entry is the first line
// we pass on) or a desktop action (its line; the relay answers and closes):
// bytes both ways until either side closes, and the Sprite kept awake all
// the while, however quiet the pipe.
// One of the screen's scripts (#60): the relay answers `AGENT-BROWSER` first,
// and only then is the entry sent, so a relay made before it, which closes
// the connection on reading the hello, closes it cleanly with nothing to
// answer: exit 3, and the caller knows to go the old way. A connection that
// fails is an error, never that.
if (browser) {
  const socket = await open(await screenReady());
  const keepAlive = setInterval(() => api('').catch(() => {}), keepAliveMs);
  socket.write(`AGENT-BROWSER ${relaySecret(token, name)}\n`);
  let head = Buffer.alloc(0), acked = false, failed = false;
  const onHead = chunk => {
    head = Buffer.concat([head, chunk]);
    if (head.length < 14) return;
    socket.off('data', onHead);
    if (head.subarray(0, 14).toString('latin1') !== 'AGENT-BROWSER\n') { failed = true; return void socket.destroy(); }
    acked = true;
    if (head.length > 14) process.stdout.write(head.subarray(14));
    socket.pipe(process.stdout);
    process.stdin.pipe(socket, { end: false });
  };
  socket.on('data', onHead);
  socket.on('error', () => { failed = true; });
  socket.on('close', () => { clearInterval(keepAlive); process.exit(acked ? 0 : failed ? 1 : 3); });
} else if (screen || command || desk) {
  const socket = await open(await (desk ? screenReady() : ensureRunning()));
  const keepAlive = setInterval(() => api('').catch(() => {}), keepAliveMs);
  socket.write(`${screen ? 'AGENT-SCREEN' : command ? 'AGENT-COMMAND' : 'AGENT-DESK'} ${relaySecret(token, name)}\n`);
  let answered = false;
  if (desk && existing) socket.once('data', () => { answered = true; });
  socket.pipe(process.stdout);
  process.stdin.pipe(socket, { end: false });
  // A retained desktop's relay that hangs up without an answer, reset or not
  // (the action line arrives unread), predates AGENT-DESK: exit 3.
  const tooOld = () => desk && existing && !answered;
  socket.on('error', error => process.exit(tooOld() && ['ECONNRESET', 'EPIPE'].includes(error.code) ? 3 : 1));
  socket.on('close', () => { clearInterval(keepAlive); process.exit(tooOld() ? 3 : 0); });
  // A desktop action's answer comes after its line; the relay closes.
  if (!desk) process.stdin.on('end', () => { clearInterval(keepAlive); socket.destroy(); });
} else try {
  const socket = await open(await ensureRunning());
  const keepAlive = setInterval(() => api('').catch(() => {}), keepAliveMs);
  const watch = activity(() => { clearInterval(keepAlive); socket.destroy(); process.exit(0); });
  socket.write(`AGENT-RELAY ${relaySecret(token, name)} ${daemonToken}\n`);
  socket.on('data', chunk => { watch.daemon(chunk); process.stdout.write(chunk); });
  process.stdin.on('data', chunk => { watch.client(chunk); socket.write(chunk); });
  process.stdin.on('end', () => socket.end());
  socket.on('error', error => fail(`the connection to the sprite failed: ${error.message}`));
  socket.on('close', () => { clearInterval(keepAlive); process.exit(0); });
} catch (error) {
  fail(error.message);
}
