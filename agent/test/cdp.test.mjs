// agent/guest/cdp.mjs against a real Chromium on its pipe (#60): DevTools
// answers only under its token; visit.mjs and fill.mjs work through it as
// they did on Chromium's own port; and it holds its port while Chromium
// restarts. A local https server stands in for the site (every name mapped
// to loopback, a throwaway self-signed certificate).
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile, execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createServer } from 'node:https';
import { createServer as createTcpServer } from 'node:net';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateDir, spawnGroup } from './processes.mjs';

const GUEST = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest');
const CHROMIUM = [process.env.CHROME_BIN, '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable']
  .find(path => path && existsSync(path));
const PASSWORD = 'correct-horse-battery-staple-6014'; // gitleaks:allow (a made-up test password)
const TOKEN = 'b'.repeat(64);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const freePort = () => new Promise(resolve => { const server = createTcpServer().listen(0, '127.0.0.1', () => { const { port } = server.address(); server.close(() => resolve(port)); }); });

async function devtools(t) {
  assert.ok(CHROMIUM, 'these tests need Chromium (set CHROME_BIN)');
  // cdp.mjs refuses root, as a Sprite never runs it so; a runner that is
  // root (CI's) runs it as nobody, in a folder of nobody's outside the
  // tests' own, which is root's alone.
  const root = process.getuid?.() === 0;
  const dir = root ? await mkdtemp(join(tmpdir(), 'omakase-cdp-')) : await privateDir('omakase-cdp-');
  // Chromium may still be writing its profile as its process group dies.
  if (root) t.after(() => rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem'),
    '-days', '1', '-subj', '/CN=example.com'], { stdio: 'ignore' });
  const site = createServer({ key: await readFile(join(dir, 'key.pem')), cert: await readFile(join(dir, 'cert.pem')) }, (request, response) => {
    response.setHeader('content-type', 'text/html');
    if (request.url === '/outer') return response.end('<title>Outer</title><input name="q"><iframe src="https://signin.other.example/" style="width:400px;height:200px"></iframe>');
    response.end(`<title>Sign in to ${request.headers.host.split(':')[0]}</title><form><input type="text" name="user"><input type="password" name="pass"></form>`);
  });
  await new Promise(resolve => site.listen(0, '127.0.0.1', resolve));
  // cdp.mjs starts "chromium" with server.js's flags and the pipe; headless
  // here, and every name mapped to the site.
  const wrapper = join(dir, 'chromium');
  await writeFile(wrapper, `#!/bin/sh\nexec ${CHROMIUM} --headless=new --ignore-certificate-errors --disable-features=HttpsUpgrades ` +
    `'--host-resolver-rules=MAP * 127.0.0.1:${site.address().port}' "$@"\n`, { mode: 0o755 });
  const home = join(dir, 'home');
  await mkdir(home);
  const port = await freePort();
  const user = root ? { uid: 65534, gid: 65534 } : {};
  if (root) execFileSync('chown', ['-R', '65534:65534', dir]);
  const cdp = spawnGroup(t, process.execPath, [join(GUEST, 'cdp.mjs')], { ...user,
    env: { PATH: '/usr/bin:/bin', HOME: home, SPRITE_CDP_TOKEN: TOKEN, SPRITE_CDP_PORT: String(port), SPRITE_CHROMIUM: wrapper,
      PI_DESKTOP_PROFILE_DIR: join(dir, 'profile'), PI_DESKTOP_NO_SANDBOX: '1' },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let said = '';
  cdp.stderr.on('data', chunk => { said = (said + chunk).slice(-4000); });
  t.after(() => { execFile('pkill', ['-KILL', '-f', join(dir, 'profile')], () => {}); site.closeAllConnections?.(); site.close(); });
  const base = `http://127.0.0.1:${port}/${TOKEN}`;
  const up = async () => (await fetch(`${base}/json/version`).catch(() => null))?.status === 200;
  for (let i = 0; i < 200 && !(await up()); i++) await pause(100);
  assert.ok(await up(), `DevTools never came up under its token; cdp.mjs and Chromium said:\n${said}`);
  const script = (name, args, env = {}) => new Promise(resolve => execFile(process.execPath, [join(GUEST, name), ...args],
    { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: base, ...env } }, (error, stdout) => resolve({ code: error?.code ?? 0, stdout })));
  return { port, base, home, script, up };
}

// One message on a DevTools socket, and the reply to it.
async function call(address, method, params = {}) {
  const socket = new WebSocket(address);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = () => reject(new Error('refused')); });
  socket.send(JSON.stringify({ id: 7, method, params }));
  const reply = await Promise.race([new Promise(resolve => { socket.onmessage = event => { const message = JSON.parse(event.data); if (message.id === 7) resolve(message); }; }), pause(5000)]);
  socket.close();
  return reply;
}

test('DevTools answers only under its token; visit.mjs and fill.mjs work through it, and the filled value is the browser\'s alone', async t => {
  const browser = await devtools(t);
  for (const path of ['/json/version', '/json/list', `/${'a'.repeat(64)}/json/list`, `/${TOKEN.slice(1)}/json/list`]) {
    const response = await fetch(`http://127.0.0.1:${browser.port}${path}`);
    assert.equal(response.status, 404, path);
  }
  await assert.rejects(call(`ws://127.0.0.1:${browser.port}/devtools/browser`, 'Browser.getVersion'), /refused/);

  const visited = await browser.script('visit.mjs', ['https://login.example.com/']);
  assert.equal(visited.code, 0, visited.stdout);
  assert.equal(JSON.parse(visited.stdout).title, 'Sign in to login.example.com');
  const filled = await browser.script('fill.mjs', [], { AGENT_SIGN_IN: JSON.stringify({ host: 'login.example.com', username: 'maya', password: PASSWORD }) });
  assert.deepEqual(JSON.parse(filled.stdout), { ok: true, filled: ['username', 'password'], url: 'https://login.example.com/' });

  // With the token, a page's socket is that page's, as on Chromium's own port: no session in what it is sent.
  const visitTab = (await readFile(join(browser.home, '.visit-tab'), 'utf8')).trim();
  const tab = (await (await fetch(`${browser.base}/json/list`)).json()).find(each => each.id === visitTab);
  assert.match(tab.webSocketDebuggerUrl, new RegExp(`^ws://127\\.0\\.0\\.1:${browser.port}/${TOKEN}/devtools/page/`));
  const reply = await call(tab.webSocketDebuggerUrl, 'Runtime.evaluate', { expression: 'document.querySelector("[type=password]").value', returnByValue: true });
  assert.deepEqual(Object.keys(reply).sort(), ['id', 'result']);
  assert.equal(reply.result.result.value, PASSWORD);
});

test('it holds its port while Chromium restarts, and serves the new one', async t => {
  const browser = await devtools(t);
  const { webSocketDebuggerUrl } = await (await fetch(`${browser.base}/json/version`)).json();
  assert.equal(webSocketDebuggerUrl, `ws://127.0.0.1:${browser.port}/${TOKEN}/devtools/browser`);
  await call(webSocketDebuggerUrl, 'Browser.close').catch(() => {});
  // While it is down the port still answers, as this process.
  const during = await fetch(`${browser.base}/json/version`).then(response => response.status, () => 'refused');
  assert.ok([200, 503].includes(during), `while restarting: ${during}`);
  let back = false;
  for (let i = 0; i < 150 && !back; i++) { await pause(100); back = await browser.up(); }
  assert.ok(back, 'Chromium came back');
  const visited = await browser.script('visit.mjs', ['https://again.example.com/']);
  assert.equal(JSON.parse(visited.stdout).title, 'Sign in to again.example.com');
});

// Another site's frame runs in its own process, reached as its own session
// (Target.setAutoAttach), which belongs to the socket that opened it.
test('fill.mjs fills another site\'s sign-in frame through it', async t => {
  const browser = await devtools(t);
  const visited = await browser.script('visit.mjs', ['https://www.example.com/outer']);
  assert.equal(JSON.parse(visited.stdout).title, 'Outer');
  await pause(500);
  const filled = await browser.script('fill.mjs', [], { AGENT_SIGN_IN: JSON.stringify({ host: 'signin.other.example', username: 'maya', password: PASSWORD }) });
  assert.deepEqual(JSON.parse(filled.stdout), { ok: true, filled: ['username', 'password'], url: 'https://signin.other.example/' });
});
