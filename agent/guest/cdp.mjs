// The screen's Chromium and the one way to drive it (#60). Run as `browser`
// by agent/guest/entrypoint.sh; it starts Chromium with
// --remote-debugging-pipe, so Chromium itself listens on no port, and starts
// it again when it closes.
//
// A debugging port on loopback answers every user on the computer, the
// agent's shell included, and through it any page's fields: a password just
// filled. So DevTools is served here instead, on 127.0.0.1:$SPRITE_CDP_PORT
// (9222), only under a path holding a token made at each boot, which only
// `browser` can read (/run/browser/cdp-token). Anything else gets 404.
// visit.mjs, fill.mjs, pay.mjs and answer.mjs run as `browser`
// (agent/guest/spawner.mjs) with AGENT_CDP set to http://127.0.0.1:9222/<token>,
// and see what they saw on Chromium's own port:
//
//   GET /<token>/json/version, /json/list, /json/close/<id>, /json/activate/<id>, PUT /json/new?<url>
//   WebSocket /<token>/devtools/browser and /<token>/devtools/page/<target id>
//
// Chromium's pipe is one connection; each WebSocket here is a client on it. A
// page's socket is a session attached to that page (Target.attachToTarget,
// flattened), its id hidden from the client as Chromium's own page socket
// would; the sessions a client opens (a frame from another site) are its own.
// Each message's id is renumbered on the pipe and given back on the way out.
//
// Unlike Chromium's own /json/list, the list is not ordered by last use: the
// pipe has no such order.
import { createServer } from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { spawn } from 'node:child_process';

// It reads what its clients send, and drives the person's browser; never as root.
if (process.getuid?.() === 0) { console.error('cdp: refusing to run as root'); process.exit(1); }
const token = process.env.SPRITE_CDP_TOKEN ?? '';
const PORT = Number(process.env.SPRITE_CDP_PORT || 9222);
if (!/^[0-9a-f]{32,128}$/.test(token)) { console.error('cdp: SPRITE_CDP_TOKEN is not set'); process.exit(1); }
const chromium = process.env.SPRITE_CHROMIUM || 'chromium';
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

// --- Chromium on the pipe: JSON messages, each ending in a NUL byte.
let pipe = null;
let next = 0;
const internal = new Map();
const pending = new Map();
const owners = new Map();
const clients = new Set();

function write(message) {
  if (!pipe) return false;
  pipe.write(`${JSON.stringify(message)}\0`);
  return true;
}
// A call of this process's own, for the HTTP endpoints and a page socket's session.
function call(method, params = {}, sessionId) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    internal.set(id, { resolve, reject });
    if (!write({ id, method, params, ...(sessionId ? { sessionId } : {}) })) { internal.delete(id); reject(new Error('the browser is not running')); }
  });
}

function fromChromium(message) {
  if (message.id !== undefined) {
    const own = internal.get(message.id);
    if (own) {
      internal.delete(message.id);
      return message.error ? own.reject(new Error(message.error.message)) : own.resolve(message.result);
    }
    const asked = pending.get(message.id);
    if (!asked) return;
    pending.delete(message.id);
    if (message.result?.sessionId && asked.method === 'Target.attachToTarget') owners.set(message.result.sessionId, asked.client);
    return asked.client.send({ ...message, id: asked.id });
  }
  if (message.method === 'Target.detachedFromTarget') {
    const page = [...clients].find(client => client.session === message.params.sessionId);
    owners.delete(message.params.sessionId);
    if (page) return page.close();
  }
  // An event in a session goes to the client that owns it; a new session
  // opened in it (Target.setAutoAttach) belongs to that client too. An event
  // outside any session goes to every browser socket.
  if (message.sessionId) {
    const owner = owners.get(message.sessionId);
    if (!owner) return;
    if (message.method === 'Target.attachedToTarget') owners.set(message.params.sessionId, owner);
    return owner.send(message);
  }
  for (const client of clients) {
    if (client.session) continue;
    if (message.method === 'Target.attachedToTarget' && !owners.has(message.params.sessionId)) owners.set(message.params.sessionId, client);
    client.send(message);
  }
}

// --- One WebSocket client (RFC 6455, text frames, as DevTools uses).
function websocket(socket, head, onMessage, onClose) {
  let buffer = head, parts = [], closed = false;
  const frame = (opcode, payload) => {
    const length = payload.length;
    const header = length < 126 ? Buffer.from([0x80 | opcode, length])
      : length < 65536 ? Buffer.from([0x80 | opcode, 126, length >> 8, length & 255])
        : Buffer.concat([Buffer.from([0x80 | opcode, 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(length)); return b; })()]);
    if (!socket.destroyed) socket.write(Buffer.concat([header, payload]));
  };
  const close = () => {
    if (closed) return;
    closed = true;
    frame(8, Buffer.alloc(0));
    socket.end();
    onClose();
  };
  const read = () => {
    while (buffer.length >= 2) {
      const fin = buffer[0] & 0x80, opcode = buffer[0] & 0x0f, masked = buffer[1] & 0x80;
      let length = buffer[1] & 0x7f, at = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); at = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); at = 10; }
      // A client's frames are masked; one that is not is no WebSocket client.
      if (!masked || length > 256 * 1024 * 1024) return close();
      if (buffer.length < at + 4 + length) return;
      const mask = buffer.subarray(at, at + 4);
      const payload = Buffer.from(buffer.subarray(at + 4, at + 4 + length));
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
      buffer = buffer.subarray(at + 4 + length);
      if (opcode === 8) return close();
      if (opcode === 9) { frame(10, payload); continue; }
      if (opcode === 10) continue;
      parts.push(payload);
      if (fin) { const text = Buffer.concat(parts).toString('utf8'); parts = []; onMessage(text); }
    }
  };
  socket.on('data', chunk => { buffer = Buffer.concat([buffer, chunk]); read(); });
  socket.on('close', () => { if (!closed) { closed = true; onClose(); } });
  socket.on('error', () => {});
  read();
  return { send: text => frame(1, Buffer.from(text)), close };
}

function client(socket, head, session) {
  const me = { session, sessions: new Set() };
  const ws = websocket(socket, head, text => {
    let message;
    try { message = JSON.parse(text); } catch { return; }
    if (typeof message?.id !== 'number' || typeof message.method !== 'string') return;
    // Only its own sessions: a page socket's, or ones it opened.
    if (message.sessionId !== undefined && owners.get(message.sessionId) !== me)
      return ws.send(JSON.stringify({ id: message.id, error: { code: -32001, message: 'No session with given id' } }));
    const id = ++next;
    pending.set(id, { client: me, id: message.id, method: message.method });
    const out = { ...message, id };
    if (session && message.sessionId === undefined) out.sessionId = session;
    if (!write(out)) { pending.delete(id); ws.send(JSON.stringify({ id: message.id, error: { code: -32000, message: 'the browser is not running' } })); }
  }, () => {
    clients.delete(me);
    for (const [id, asked] of pending) if (asked.client === me) pending.delete(id);
    for (const [id, owner] of owners) if (owner === me) { owners.delete(id); if (id !== session) call('Target.detachFromTarget', { sessionId: id }).catch(() => {}); }
    if (session) call('Target.detachFromTarget', { sessionId: session }).catch(() => {});
  });
  me.send = message => {
    // A page socket sees its own session's messages as Chromium's page socket sends them: without it.
    if (session && message.sessionId === session) { const { sessionId: _, ...rest } = message; message = rest; }
    ws.send(JSON.stringify(message));
  };
  me.close = () => ws.close();
  clients.add(me);
  return me;
}

// --- HTTP: the token first, compared in constant time.
function rest(url) {
  const [, given, ...path] = url.split('?')[0].split('/');
  const bytes = Buffer.from(given ?? '');
  if (bytes.length !== token.length || !timingSafeEqual(bytes, Buffer.from(token))) return null;
  return `/${path.join('/')}`;
}
const base = `127.0.0.1:${PORT}/${token}`;
const listed = info => ({ description: '', id: info.targetId, title: info.title, type: info.type, url: info.url,
  webSocketDebuggerUrl: `ws://${base}/devtools/page/${info.targetId}` });

const server = createServer(async (request, response) => {
  const path = rest(request.url);
  const answer = (status, body) => {
    response.writeHead(status, { 'content-type': typeof body === 'string' ? 'text/plain' : 'application/json' });
    response.end(typeof body === 'string' ? body : JSON.stringify(body));
  };
  if (path === null) return answer(404, 'Not found');
  try {
    if (path === '/json/version') {
      const version = await call('Browser.getVersion');
      return answer(200, { Browser: version.product, 'Protocol-Version': version.protocolVersion, 'User-Agent': version.userAgent,
        webSocketDebuggerUrl: `ws://${base}/devtools/browser` });
    }
    if (path === '/json/list' || path === '/json') {
      const { targetInfos } = await call('Target.getTargets');
      return answer(200, targetInfos.filter(info => info.type !== 'browser' && info.type !== 'tab').map(listed));
    }
    if (path === '/json/new' && request.method === 'PUT') {
      const url = decodeURIComponent(request.url.split('?')[1] ?? '') || 'about:blank';
      const { targetId } = await call('Target.createTarget', { url });
      const { targetInfo } = await call('Target.getTargetInfo', { targetId });
      return answer(200, listed(targetInfo));
    }
    const close = path.match(/^\/json\/close\/([\w-]+)$/), activate = path.match(/^\/json\/activate\/([\w-]+)$/);
    if (close) { await call('Target.closeTarget', { targetId: close[1] }); return answer(200, 'Target is closing'); }
    if (activate) { await call('Target.activateTarget', { targetId: activate[1] }); return answer(200, 'Target activated'); }
  } catch (error) {
    return answer(error.message === 'the browser is not running' ? 503 : 404, error.message);
  }
  answer(404, 'Not found');
});

server.on('upgrade', async (request, socket, head) => {
  socket.on('error', () => {});
  const path = rest(request.url);
  const key = request.headers['sec-websocket-key'];
  const page = path?.match(/^\/devtools\/page\/([\w-]+)$/);
  if (!key || !(path === '/devtools/browser' || page)) return void socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
  let session;
  if (page) {
    try { ({ sessionId: session } = await call('Target.attachToTarget', { targetId: page[1], flatten: true })); } catch {
      return void socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
    }
  }
  const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const me = client(socket, head, session);
  if (session) owners.set(session, me);
});

// --- Chromium, started again when it closes. server.js readies the profile
// (stale locks cleared, marked cleanly exited, startup set to New Tab)
// and gives its flags. Chromium gets a fixed environment, never this
// process's own, which holds the token.
async function browse() {
  const { prepareProfile, chromiumArgs } = await import('./server.js');
  for (;;) {
    const { restore, running } = prepareProfile();
    if (running) { await pause(2000); continue; }
    const child = spawn(chromium, [...chromiumArgs({ restore }), '--remote-debugging-pipe'], {
      stdio: ['ignore', 'ignore', 'inherit', 'pipe', 'pipe'],
      env: Object.fromEntries(['PATH', 'HOME', 'USER', 'LOGNAME', 'DISPLAY', 'TZ', 'PI_DESKTOP_NO_SANDBOX'].filter(name => process.env[name] !== undefined)
        .map(name => [name, process.env[name]]))
    });
    pipe = child.stdio[3];
    let buffer = Buffer.alloc(0);
    child.stdio[4].on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk]);
      for (let end = buffer.indexOf(0); end >= 0; end = buffer.indexOf(0)) {
        const text = buffer.subarray(0, end).toString('utf8');
        buffer = buffer.subarray(end + 1);
        try { fromChromium(JSON.parse(text)); } catch {}
      }
    });
    child.stdio[3].on('error', () => {});
    await new Promise(resolve => { child.on('exit', resolve); child.on('error', resolve); });
    pipe = null;
    for (const [id, own] of internal) { internal.delete(id); own.reject(new Error('the browser is not running')); }
    pending.clear();
    owners.clear();
    for (const each of [...clients]) each.close();
    await pause(2000);
  }
}

// The port is held from boot for as long as this runs, so nothing else can
// take it while Chromium restarts and be sent what a filler fills.
server.listen(PORT, '127.0.0.1', () => {
  console.log(`cdp listening on 127.0.0.1:${PORT}`);
  browse().catch(error => { console.error(`cdp: ${error.message}`); process.exit(1); });
});
