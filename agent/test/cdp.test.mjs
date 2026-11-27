// agent/guest/cdp.mjs against a real Chromium on its pipe (#60): DevTools
// answers only under its token; visit.mjs and fill.mjs work through it as
// they did on Chromium's own port; and it holds its port while Chromium
// restarts. A local https server stands in for the site (every name mapped
// to loopback, a throwaway self-signed certificate).
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile, execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { createServer } from 'node:https';
import { createServer as createTcpServer } from 'node:net';
import { join, dirname } from 'node:path';
import { setTimeout as pause } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { privateDir, spawnGroup } from './processes.mjs';

const GUEST = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest');
const CHROMIUM = [process.env.CHROME_BIN, '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable']
  .find(path => path && existsSync(path));
const PASSWORD = 'correct-horse-battery-staple-6014'; // gitleaks:allow (a made-up test password)
const TOKEN = 'b'.repeat(64);
const freePort = () => new Promise(resolve => { const server = createTcpServer().listen(0, '127.0.0.1', () => { const { port } = server.address(); server.close(() => resolve(port)); }); });

async function waitFor(signal, check, message) {
  try {
    for (;;) {
      const value = await check(signal);
      if (value) return value;
      await pause(100, undefined, { signal });
    }
  } catch (error) {
    if (signal.aborted) throw new Error(message(), { cause: error });
    throw error;
  }
}

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
  // here, and every name mapped to the site. Each start is recorded, and
  // Chromium's output joins cdp.mjs's, for a failure to show.
  const wrapper = join(dir, 'chromium'), starts = join(dir, 'starts');
  await writeFile(wrapper, `#!/bin/sh\necho "start $$ $(date +%s.%N)" >> '${starts}'\n` +
    `exec ${CHROMIUM} --headless=new --ignore-certificate-errors --disable-features=HttpsUpgrades ` +
    `'--host-resolver-rules=MAP * 127.0.0.1:${site.address().port}' "$@" >&2\n`, { mode: 0o755 });
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
  const hear = chunk => { said = (said + chunk).slice(-8000); };
  cdp.stdout.on('data', hear);
  cdp.stderr.on('data', hear);
  const started = async () => (await readFile(starts, 'utf8').catch(() => '')).split('\n').filter(Boolean);
  const output = async () => `Chromium's starts:\n${(await started()).join('\n')}\ncdp.mjs and Chromium said:\n${said}`;
  t.after(() => { execFile('pkill', ['-KILL', '-f', join(dir, 'profile')], () => {}); site.closeAllConnections?.(); site.close(); });
  const base = `http://127.0.0.1:${port}/${TOKEN}`;
  const pages = async signal => {
    const response = await fetch(`${base}/json/list`, { signal });
    if (response.status === 503) { await response.text(); return []; }
    assert.equal(response.status, 200, 'DevTools did not list its pages');
    return (await response.json()).filter(target => target.type === 'page');
  };
  const initialPages = await waitFor(AbortSignal.timeout(20_000), async signal => {
    const list = await pages(signal).catch(error => {
      if (error.cause?.code === 'ECONNREFUSED') return [];
      throw error;
    });
    return list.length && list;
  }, () => `DevTools never listed a page; cdp.mjs and Chromium said:\n${said}`);
  const script = (name, args, env = {}) => new Promise(resolve => execFile(process.execPath, [join(GUEST, name), ...args],
    { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: base, ...env } }, (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr })));
  return { port, base, home, script, pages, initialPages, started, output };
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

test('it holds its port while Chromium restarts, and serves the new one', { skip: 'Quarantined: flaky, Chromium restart class: the new browser sometimes never answers Target.createTarget (docs/flaky-tests.md)' }, async t => {
  const browser = await devtools(t);
  const signal = AbortSignal.timeout(15_000);
  const { webSocketDebuggerUrl } = await (await fetch(`${browser.base}/json/version`, { signal })).json();
  assert.equal(webSocketDebuggerUrl, `ws://127.0.0.1:${browser.port}/${TOKEN}/devtools/browser`);
  const socket = new WebSocket(webSocketDebuggerUrl);
  t.after(() => socket.close());
  await once(socket, 'open', { signal });
  socket.send(JSON.stringify({ id: 7, method: 'Browser.close' }));
  // A failure says what cdp.mjs and Chromium said, so it shows whether the
  // new browser died or hung (#575).
  try {
    // A reply alone could still be from the browser we just closed: the visit
    // waits for the launcher's second start and a page of the new browser.
    // A 503 means the proxy held the port; a refused connection fails the test.
    await waitFor(signal, async () => (await browser.started()).length >= 2, () => 'Chromium was never started again');
    const oldIds = new Set(browser.initialPages.map(page => page.id));
    await waitFor(signal, async signal => {
      const pages = await browser.pages(signal);
      return pages.length && pages.every(page => !oldIds.has(page.id));
    }, () => 'DevTools never listed a page from the replacement Chromium');
    const visited = await browser.script('visit.mjs', ['https://again.example.com/']);
    assert.equal(visited.code, 0, `visit.mjs failed on the new Chromium:\n${visited.stderr}`);
    assert.equal(JSON.parse(visited.stdout).title, 'Sign in to again.example.com');
  } catch (error) {
    error.message += `\n${await browser.output()}`;
    throw error;
  }
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
