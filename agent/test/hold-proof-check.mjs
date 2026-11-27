// Invoked in a disposable image with --network none. Origin observations do not depend on the proxy or its replies.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { copyFileSync, existsSync, readdirSync, readFileSync, watch } from 'node:fs';
import { createServer } from 'node:https';
import { connect, createServer as tcpServer } from 'node:net';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';

const fixtureHost = '127.0.0.1';
const body = 'note=synthetic+hello&password=do-not-show';
const secret = randomBytes(32).toString('hex');
const posts = [], otherWrites = [];
let connections = 0;

function origin(cert, key) {
  const site = createServer({ cert, key }, async (req, res) => {
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    if (req.method === 'POST') posts.push(Buffer.concat(chunks));
    if (['PUT', 'PATCH', 'DELETE'].includes(req.method)) otherWrites.push([req.method, req.url, Buffer.concat(chunks)]);
    res.writeHead(200, { 'content-type': 'text/html' });
    res.end(`<!doctype html><link rel="icon" href="data:,">${req.method === 'POST' ? '<title>received</title>' : `<title>fixture</title>
      <form method="post" action="/submit"><input name="note" value="synthetic hello"><input type="password" name="password" value="do-not-show"><button>Send</button></form>`}`);
  });
  site.on('connection', () => connections++);
  site.listen({ host: fixtureHost, port: 443 });
  return site;
}

export function proofControl(channel, decision) {
  let waiting, others = 0;
  // Chromium can send background writes between stages. Keep reading so an
  // unrelated ticket cannot close the idle socket or become a proof ticket.
  void (async () => {
    try {
      for (;;) {
        const ticket = await channel.next();
        if (channel.socket.destroyed) return;
        if (typeof ticket?.site !== 'string') return channel.close('invalid proof ticket');
        if (ticket.site !== `https://${fixtureHost}`) {
          // The hold refuses the browser's own writes before asking; one that
          // still reaches the relay fails the idle stage.
          others++;
          console.log('NOTE: denied a browser write to another site, which the check did not make');
          channel.send(decision(ticket, 'deny'));
        } else if (waiting) waiting(ticket);
        else return channel.close('unexpected fixture ticket');
      }
    } catch {
      channel.close('proof relay exchange failed');
    } finally {
      waiting?.(null);
    }
  })();

  return {
    next(signal) {
      if (channel.socket.destroyed || waiting || signal.aborted) return Promise.resolve(null);
      return new Promise(resolve => {
        const abort = () => { channel.close('proof ticket deadline'); waiting(null); };
        waiting = ticket => {
          signal.removeEventListener('abort', abort);
          waiting = undefined;
          resolve(ticket);
        };
        signal.addEventListener('abort', abort, { once: true });
      });
    },
    send: answer => channel.send(answer),
    close: () => channel.close(),
    get socket() { return channel.socket; },
    get others() { return others; },
    get closeReason() { return channel.closeReason; },
  };
}

function run(command, args, options = {}) {
  const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
  const output = [];
  child.stdout.on('data', chunk => output.push(chunk));
  return once(child, 'exit').then(([code]) => ({ code, text: Buffer.concat(output).toString() }));
}

const plainClient = `const [body, ca] = JSON.parse(process.argv[1]);
  const request = require('node:https').request({ host: '127.0.0.1', method: 'POST', path: '/submit', ca,
    headers: { 'content-type': 'application/x-www-form-urlencoded', 'content-length': Buffer.byteLength(body) } }, res => res.resume());
  request.setTimeout(3000, () => request.destroy());
  request.on('error', () => process.exitCode = 1);
  request.end(body);`;

const browser = (script, ...args) => run('su-exec', ['browser', 'node', '-e', script, ...args]);
const read = path => readFileSync(path, 'utf8');
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const snapshot = () => [connections, posts.length, otherWrites.length];
const notFromPage = () => existsSync('/run/sprite-logs/hold.log') ? read('/run/sprite-logs/hold.log').split('browser hold: refused: browser write not from a page').length - 1 : 0;
const unchanged = (before, stage) => assert.deepEqual(snapshot(), before, `${stage}: no upstream TCP or HTTP`);
function log(message) { console.log(`PASS: ${message}`); }

// What ends a boot wait early: the computer exiting. proof() sets it.
let halted = new Promise(() => {});

// A wait ends on what it waits for, or on a real failure (the computer exits,
// DevTools closes), never on a clock: a loaded runner outlasts any clock (run
// 9984's browser came up after the 8 s this once allowed). With `changes`, a
// path, it looks again on each change beneath it; otherwise a short pause.
export async function until(label, inspect, { changes, failed = halted } = {}) {
  let changed = false, wake = () => {};
  const watcher = changes && watch(changes, { recursive: true }, () => { changed = true; wake(); });
  const failure = failed.then(reason => ({ reason }));
  try {
    for (;;) {
      changed = false;
      const value = await inspect();
      if (value) return value;
      if (changed) continue;
      const woke = await Promise.race([new Promise(resolve => { wake = resolve; if (!changes) setTimeout(resolve, 35); }), failure]);
      if (woke?.reason) {
        const last = await inspect();
        if (last) return last;
        throw new Error(`${label}: ${woke.reason}`);
      }
    }
  } finally { watcher?.close(); }
}

async function cdp() {
  await import('/opt/agent/hold/cdp-client.mjs');
  const tabs = await until('browser', async () => {
    try {
      const token = read('/run/browser/cdp-token');
      const result = await fetch(`http://127.0.0.1:9222/${token}/json/list`, { signal: AbortSignal.timeout(300) });
      return (await result.json()).find(tab => tab.type === 'page');
    } catch { return null; }
  });
  const page = await devtools(tabs.webSocketDebuggerUrl);
  return { ...page, async form() {
    const reply = await page.call('Page.navigate', { url: 'https://127.0.0.1/form' });
    assert(!reply.errorText, `browser navigation failed: ${reply.errorText}`);
    await until('synthetic form', () => page.evalPage("document.readyState === 'complete' && document.title === 'fixture'"));
  } };
}

// One page's DevTools. A call ends on its answer or on a real failure (the
// socket closes, the page's renderer crashes), never on a clock: in runs
// 10319 and 10326 a loaded runner answered one of the timeout stage's polls
// after the 5 s this once allowed.
export async function devtools(address) {
  const socket = new WebSocket(address);
  const outstanding = new Map();
  let gone;
  const fail = reason => {
    gone ??= reason;
    for (const [id, { method, reject }] of outstanding) { outstanding.delete(id); reject(new Error(`${gone}: ${method}`)); }
  };
  const opened = new Promise((resolve, reject) => {
    socket.addEventListener('open', resolve);
    socket.addEventListener('close', () => { fail('DevTools closed'); reject(new Error('DevTools did not open')); });
  });
  socket.addEventListener('message', event => {
    const reply = JSON.parse(event.data);
    if (['Inspector.targetCrashed', 'Inspector.detached'].includes(reply.method)) return fail(`DevTools: ${reply.method}`);
    const asked = outstanding.get(reply.id);
    if (!asked) return;
    outstanding.delete(reply.id);
    if (reply.error || reply.result.exceptionDetails) asked.reject(new Error(`DevTools refused ${asked.method}`));
    else asked.resolve(reply.result);
  });
  await opened;
  let next = 0;
  const call = (method, params) => new Promise((resolve, reject) => {
    if (gone) return reject(new Error(`${gone}: ${method}`));
    const id = ++next;
    outstanding.set(id, { method, resolve, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  // So a crashed renderer says so, instead of leaving a call unanswered.
  await call('Inspector.enable');
  const evalPage = async expression => (await call('Runtime.evaluate', { expression, returnByValue: true })).result.value;
  return { close: () => socket.close(), call, evalPage };
}

const alpnProbe = `const [root, version, protocols] = JSON.parse(process.argv[1]);
  const net = require('node:net'), tls = require('node:tls');
  const raw = net.connect(18181, '127.0.0.1', () => raw.write('CONNECT 127.0.0.1:443 HTTP/1.1\\r\\nHost: 127.0.0.1:443\\r\\n\\r\\n'));
  const timer = setTimeout(() => { raw.destroy(); process.exit(1); }, 2500);
  raw.once('error', () => process.exit(1));
  raw.once('data', data => {
    if (!data.toString().startsWith('HTTP/1.1 200 ')) process.exit(1);
    const socket = tls.connect({ socket: raw, host: '127.0.0.1', ca: root, minVersion: version, maxVersion: version, ALPNProtocols: protocols });
    socket.once('secureConnect', () => { console.log(socket.alpnProtocol || 'none'); clearTimeout(timer); socket.destroy(); });
    socket.once('error', error => { console.log(error.code); clearTimeout(timer); });
  });`;

const directProbe = `const net = require('node:net');
  const s = net.connect(Number(process.argv[2]), process.argv[1]);
  s.on('connect', () => { s.destroy(); process.exit(1); });
  s.on('error', () => process.exit(0));
  setTimeout(() => { s.destroy(); process.exit(0); }, 450);`;

const udpProbe = `const dgram = require('node:dgram');
  for (const family of ['udp4', 'udp6']) {
    const s = dgram.createSocket(family);
    for (const port of [53, 443]) s.send('synthetic', port, family === 'udp4' ? '127.0.0.1' : '::1', () => {});
    setTimeout(() => s.close(), 100);
  }`;

const udpDrops = () => JSON.parse(execFileSync('nft', ['-j', 'list', 'counter', 'inet', 'browser_hold', 'blocked_dns_quic']))
  .nftables.find(item => item.counter).counter.packets;

async function proof() {
  copyFileSync('/proof/site.pem', '/usr/local/share/ca-certificates/hold-test-origin.crt');
  execFileSync('update-ca-certificates', { stdio: 'ignore' });
  const computer = spawn('/opt/agent/entrypoint.sh', { env: { PATH: process.env.PATH, SPRITE_RELAY_SECRET: secret }, stdio: 'ignore' });
  let chrome, control;
  try {
    const runDir = '/dev/shm/browser-hold/private';
    halted = once(computer, 'exit').then(() => 'the computer exited');
    const pid = await until('hold proxy', () => existsSync(`${runDir}/ready`) && Number(read(`${runDir}/ready`)), { changes: '/dev/shm' });
    const { LineSocket, decisionKey, signedDecision } = await import('/opt/agent/hold/wire.mjs');
    const decision = (ticket, answer = 'allow') => signedDecision(decisionKey(secret), ticket, answer);
    async function attach() {
      const socket = await until('relay', async () => {
        const wire = connect(8080, '127.0.0.1');
        try { await once(wire, 'connect'); return wire; } catch { wire.destroy(); return null; }
      });
      const channel = new LineSocket(socket);
      const ready = channel.next(AbortSignal.timeout(5000));
      socket.write(`AGENT-HOLD ${secret}\n`);
      assert((await ready)?.status === 'ready', 'authenticated hold relay did not connect');
      return proofControl(channel, decision);
    }
    await until('browser trust installed', () => existsSync('/run/browser/cdp.sock'), { changes: '/run' });
    const root = read(`${runDir}/root.pem`);
    assert(!readdirSync(runDir).some(path => path.endsWith('.key') || path === 'relay-key'), 'key file gone after setup');
    assert.match(read(`/proc/${pid}/status`), new RegExp(`Uid:\\s+${execFileSync('id', ['-u', 'hold']).toString().trim()}\\s`));
    const inspectNss = execFileSync('su-exec', ['browser', 'certutil', '-L', '-a', '-d', 'sql:/home/browser/.pki/nssdb', '-n', 'Browser Hold Local Authority']).toString();
    assert(inspectNss.replaceAll('\r', '').trim() === root.trim(), 'the generated root is trusted in browser NSS');
    assert(!read('/etc/ssl/certs/ca-certificates.crt').includes(root.trim()), 'the generated root is not in the system store');
    for (const user of ['browser', 'agent']) {
      assert.notEqual((await run('su-exec', [user, 'sh', '-c', `test -r ${runDir}/root.pem || test -r /proc/${pid}/mem`])).code, 0);
    }
    log('CA generated on guest tmpfs; key file gone, root only in browser NSS, proxy memory isolated by UID');

    const beforeALPN = snapshot();
    for (const version of ['TLSv1.2', 'TLSv1.3']) {
      const fallback = await browser(alpnProbe, JSON.stringify([root, version, ['h2', 'http/1.1']]));
      const onlyH2 = await browser(alpnProbe, JSON.stringify([root, version, ['h2']]));
      assert.deepEqual(fallback, { code: 0, text: 'http/1.1\n' }, `${version} falls back to HTTP/1.1`);
      assert.deepEqual(onlyH2, { code: 0, text: 'ERR_SSL_TLSV1_ALERT_NO_APPLICATION_PROTOCOL\n' }, `${version} never offers h2`);
    }
    unchanged(beforeALPN, 'front TLS negotiation');
    log('TLS 1.2 and 1.3 negotiated HTTP/1.1 with mixed ALPN and refused h2-only offers');

    chrome = await cdp();
    await chrome.form();
    log('real Chromium loaded the form over verified HTTPS');

    const beforeEgress = snapshot();
    const v6 = tcpServer();
    v6.listen(9443, '::1');
    await once(v6, 'listening');
    try {
      for (const [host, port] of [['127.0.0.1', '443'], ['::1', '9443']]) {
        assert.equal((await browser(directProbe, host, port)).code, 0, 'no direct TCP');
      }
      const beforeDrops = udpDrops();
      assert.equal((await browser(udpProbe)).code, 0);
      assert.equal(udpDrops() - beforeDrops, 4, 'IPv4 and IPv6 DNS and QUIC packets dropped');
      unchanged(beforeEgress, 'browser UID egress');
      log('nftables blocked direct IPv4 and IPv6 TCP and counted DNS and QUIC drops');
    } finally { v6.close(); }

    async function pending({ form = false, requestBody = body, method = 'POST', json = false, stage = method } = {}) {
      const before = snapshot();
      const arriving = control.next(AbortSignal.timeout(6000));
      if (form) await chrome.evalPage('document.querySelector("button").click(); true');
      else await chrome.evalPage(`window.holdResult = null;
        fetch('/submit', { method: ${JSON.stringify(method)}, body: ${json ? JSON.stringify(requestBody) : `new URLSearchParams(${JSON.stringify(requestBody)})`},
          ${json ? "headers: { 'Content-Type': 'application/json' }" : ''} })
          .then(result => window.holdResult = result.status, () => window.holdResult = 'disconnected'); true`);
      const ticket = await arriving;
      if (!ticket) {
        // The page, the scripted request's result, and why the relay closed
        // (its own read deadline, or what the other end did first).
        const page = await chrome.evalPage("document.body.textContent.includes('The browser request was not allowed.') ? 'refused' : document.title === 'fixture' ? 'form' : 'other'");
        const result = form ? 'form' : await chrome.evalPage("String(window.holdResult ?? 'pending')");
        const relay = control.closeReason ?? (control.socket.destroyed ? 'closed' : 'open');
        throw new Error(`${stage}: browser ${method} was not held (page=${page}, result=${result}, relay=${relay})`);
      }
      assert.equal(ticket.method, method);
      assert.equal(ticket.path, '/submit');
      assert.equal(ticket.site, 'https://127.0.0.1');
      assert.equal(ticket.targetDigest, digest('/submit'));
      assert.equal(ticket.digest, digest(requestBody));
      assert(ticket.fields.some(([name, value]) => name === 'password' && value === '[withheld]'));
      assert(!JSON.stringify(ticket).includes('do-not-show'));
      await delay(120);
      unchanged(before, 'pending');
      return { before, ticket };
    }

    control = await attach();
    // Chromium checks on its on-device model every minute, from no page.
    const idle = snapshot();
    const refusedBefore = notFromPage();
    await delay(180_000);
    assert.equal(control.others, 0, 'the idle browser sent nothing for review');
    unchanged(idle, 'idle browser');
    log(`an idle browser sent nothing for review in 3 minutes; the hold refused ${notFromPage() - refusedBefore} of the browser's own writes`);

    const allowed = await pending({ form: true });
    const replay = decision(allowed.ticket);
    control.send(replay);
    await until('native form result', () => chrome.evalPage("document.title === 'received'"));
    assert.deepEqual(snapshot(), [allowed.before[0] + 1, 1, 0]);
    assert.deepEqual(posts, [Buffer.from(body)]);
    log('native Chromium form waited without an origin connection, then arrived once byte for byte');

    const jsonBody = '{"note": "synthetic hello", "password": "do-not-show"}';
    for (const [index, method] of ['PUT', 'PATCH', 'DELETE'].entries()) {
      await chrome.form();
      const { before, ticket } = await pending({ method, requestBody: jsonBody, json: true });
      control.send(decision(ticket));
      assert.equal(await until(method, () => chrome.evalPage('window.holdResult')), 200);
      assert.deepEqual(snapshot(), [before[0] + 1, 1, index + 1]);
      assert.deepEqual(otherWrites.at(-1), [method, '/submit', Buffer.from(jsonBody)]);
    }
    log('scripted PUT, PATCH and DELETE each arrived once with the exact JSON bytes');

    const unreviewable = snapshot();
    for (const script of [
      "fetch('/submit', { method: 'POST', body: 'unknown content' })",
      "fetch('/submit', { method: 'POST', body: new URLSearchParams({ note: 'a'.repeat(65536) }) })",
      "fetch('/submit', { method: 'POST', body: new FormData(document.querySelector('form')) })",
    ]) {
      await chrome.evalPage(`window.holdResult = null; ${script}.then(r => window.holdResult = r.status, () => window.holdResult = 'disconnected'); true`);
      assert.equal(await until('unreviewable body', () => chrome.evalPage('window.holdResult')), 403);
    }
    unchanged(unreviewable, 'unreviewable body');
    log('unknown, oversized and multipart bodies were refused before any upstream traffic');

    for (const [name, answer] of [
      ['deny', ticket => decision(ticket, 'deny')],
      ['forged', ticket => ({ ...decision(ticket), mac: '0'.repeat(64) })],
      ['reused', () => replay],
      ['altered site', ticket => decision({ ...ticket, site: 'https://example.com' })],
      ['altered path', ticket => decision({ ...ticket, targetDigest: digest('/other') })],
      ['altered body', ticket => decision({ ...ticket, digest: digest('other') })],
      ['altered method', ticket => decision({ ...ticket, method: 'PUT' })],
      ['lost relay', () => control.close()],
      ['timeout', () => {}],
    ]) {
      const { before, ticket } = await pending({ stage: name });
      const message = answer(ticket);
      if (message) control.send(message);
      const status = await until(name, () => chrome.evalPage('window.holdResult'));
      assert.equal(status, 403, `${name} must deny`);
      unchanged(before, name);
      log(`${name}: no upstream TCP or HTTP`);
      if (['lost relay', 'timeout'].includes(name)) control = await attach();
    }

    const stopped = await pending();
    process.kill(pid, 'SIGKILL');
    await until('stopped proxy', () => !existsSync(`/proc/${pid}`));
    assert.equal((await browser(directProbe, '127.0.0.1', '443')).code, 0);
    unchanged(stopped.before, 'stopped proxy');
    log('stopped proxy: pending POST did not arrive; direct egress stayed blocked');
    const impostor = tcpServer(socket => socket.destroy());
    impostor.listen(18181, '127.0.0.1');
    await once(impostor, 'listening');
    try {
      assert.equal((await browser(directProbe, '127.0.0.1', '18181')).code, 0, 'a non-hold listener cannot impersonate the dead proxy');
    } finally { impostor.close(); }
    log('nftables blocked a replacement listener with the wrong UID');
    assert.deepEqual(posts, [Buffer.from(body)]);
  } catch (error) {
    // Bootstrap errors carry only fixed diagnostics, not fixture tickets or site traffic.
    for (const file of ['/run/sprite-logs/hold.log', '/run/sprite-logs/relay.log']) {
      if (existsSync(file)) console.error(read(file).split('\n').slice(-8).join('\n'));
    }
    throw error;
  } finally {
    control?.close();
    chrome?.close();
    computer.kill('SIGTERM');
  }
}

if (import.meta.main) {
  const cert = readFileSync('/proof/site.pem');
  const site = origin(cert, readFileSync('/proof/site.key'));
  await once(site, 'listening');
  try {
    if (!existsSync('/opt/agent/hold/boot.sh')) {
      const { code } = await browser(plainClient, JSON.stringify([body, cert.toString()]));
      assert.equal(code, 0, 'baseline probe reached the local site');
      assert.deepEqual(posts, [Buffer.from(body)], 'baseline sent the exact body directly');
      console.error('FAIL: the browser UID sent the HTTPS POST to the origin without Allow');
      console.error('FAIL: direct browser UID egress was not blocked');
      console.error('FAIL: no held decision, throwaway CA, or TLS tunnel to verify');
      process.exitCode = 1;
    } else {
      await proof();
    }
  } catch (error) {
    console.error('FAIL:', error.message);
    process.exitCode = 1;
  } finally {
    site.closeAllConnections();
    site.close();
  }
}
