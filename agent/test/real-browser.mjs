// A real Chromium over CDP standing in for the screen's browser, local https
// servers for the sites (*.example.com and *.example.org mapped to loopback, a
// throwaway self-signed certificate), and a stand-in Sprite: this machine
// running the guest scripts. Only the Sprite's exec is a stand-in; the
// browser, the pages and the scripts are the real ones. On a Sprite the shared
// folder is /home/agent/browser-files; here it is <home>/browser-files, named
// to the guest scripts by BROWSER_FILES, which the Sprite's spawner never
// passes on.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile } from 'node:fs/promises';
import { createServer } from 'node:https';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { privateDir, spawnGroup, stopGroup } from './processes.mjs';

const GUEST = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest');
export const CHROMIUM = [process.env.CHROME_BIN, '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable']
  .find(path => path && existsSync(path));
export const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
export const text = result => result.output.map(part => part.text).join('');

// The sites' pages:
//   /paint/<colour>  a page in one colour that says which cookies it was sent
//   /sign-in         a sign-in form that sets a cookie
//   /moved           a redirect to another site
//   /popup           a button that opens /paint/ff00ff with window.open
//   /upload          a file field labelled Statement, whose page title reads back the file's name and size
//   anything else    a sign-in form
function page(request, response, port) {
  const host = request.headers.host.split(':')[0];
  response.setHeader('content-type', 'text/html');
  const paint = request.url.match(/^\/paint\/([0-9a-f]{6})$/);
  if (paint) return response.end(`<title>${paint[1]} on ${host}</title><body style="margin:0;background:#${paint[1]}">cookies: ${request.headers.cookie ?? 'none'}`);
  if (request.url === '/moved') return response.writeHead(302, { location: `https://landing.example.org:${port}/paint/ff00ff` }).end();
  if (request.url === '/popup') return response.end('<title>Documents</title><button id="open" style="width:400px;height:200px" ' +
    'onclick="window.open(\'/paint/ff00ff\')">Open the statement</button>');
  if (request.url === '/upload') return response.end('<title>Upload</title><form><label for="doc">Statement</label> <input type="file" id="doc">' +
    '<input type="text" id="note"></form><script>doc.onchange = () => { document.title = doc.files[0].name + " " + doc.files[0].size; };</script>');
  if (request.url === '/sign-in') response.setHeader('set-cookie', 'session=maya; Secure; Path=/');
  response.end(`<title>Sign in to ${host}</title><form><input type="text" name="user"><input type="password" name="pass"></form>`);
}

export async function screen(t) {
  assert.ok(CHROMIUM, 'these tests need Chromium (set CHROME_BIN)');
  const dir = await privateDir('omakase-same-tab-');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem'),
    '-days', '1', '-subj', '/CN=example.com', '-addext', 'subjectAltName=DNS:*.example.com'], { stdio: 'ignore' });
  let port;
  const site = createServer({ key: await readFile(join(dir, 'key.pem')), cert: await readFile(join(dir, 'cert.pem')) }, (request, response) => page(request, response, port));
  await new Promise(resolve => site.listen(0, '127.0.0.1', resolve));
  port = site.address().port;
  const mapping = [`--host-resolver-rules=MAP *.example.com 127.0.0.1:${port}, MAP *.example.org 127.0.0.1:${port}`, '--ignore-certificate-errors'];
  const profile = join(dir, 'profile');
  spawnGroup(t, CHROMIUM, ['--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    `--user-data-dir=${profile}`, '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', ...mapping, 'about:blank'], { stdio: 'ignore' });
  t.after(() => { site.closeAllConnections?.(); site.close(); });
  // Chromium creates DevToolsActivePort before it writes the port in; read
  // early, the address has no port and every call goes to port 80.
  const devToolsPort = async () => existsSync(join(profile, 'DevToolsActivePort')) &&
    (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).match(/^\d+\n/)?.[0].trim();
  for (let i = 0; i < 200 && !(await devToolsPort()); i++) await pause(50);
  const cdp = `http://127.0.0.1:${await devToolsPort()}`;
  const home = join(dir, 'home');
  const shared = join(home, 'browser-files');
  await mkdir(shared, { recursive: true });

  const pages = async () => (await (await fetch(`${cdp}/json/list`)).json()).filter(tab => tab.type === 'page');
  // DevTools answers before Chromium has listed its first tab; on a busy
  // machine a test that takes the person's tab at once would find none.
  for (let i = 0; i < 200 && (await pages()).length === 0; i++) await pause(50);
  const call = async (tab, method, params = {}) => {
    const socket = new WebSocket(tab.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    socket.send(JSON.stringify({ id: 1, method, params }));
    const reply = await Promise.race([new Promise(resolve => { socket.onmessage = event => { const message = JSON.parse(event.data); if (message.id === 1) resolve(message); }; }), pause(5000)]);
    socket.close();
    return reply;
  };

  const exec = (argv, options) => new Promise(resolve => {
    let [program, ...args] = argv;
    if (program === 'node' && args[0]?.startsWith('/opt/agent/')) args = [join(GUEST, args[0].slice('/opt/agent/'.length)), ...args.slice(1)];
    if (program === 'node') program = process.execPath;
    else if (['chromium', 'chromium-browser', 'google-chrome'].includes(program)) { program = CHROMIUM; args = [...mapping, ...args]; }
    const child = spawnGroup(t, program, args, { cwd: home, env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, BROWSER_FILES: shared, ...options.env } });
    child.stdout.on('data', chunk => options.onOutput?.(String(chunk), ctx, { stream: 'stdout' }));
    child.stderr.on('data', chunk => options.onOutput?.(String(chunk), ctx, { stream: 'stderr' }));
    const timer = setTimeout(() => { stopGroup(child); resolve({ ok: false, error: { code: 'timeout', message: `timeout:${options.timeout}` } }); }, (options.timeout ?? 60) * 1000);
    child.on('error', error => { clearTimeout(timer); resolve({ ok: false, error: { code: 'spawn_error', message: error.message } }); });
    child.on('close', code => { clearTimeout(timer); resolve({ ok: true, value: { exitCode: code } }); });
  });
  const env = {
    id: 'sprites:as-test-b1-c3', cwd: home, exec, onScreen: exec,
    createDir: async path => { await mkdir(path, { recursive: true }); return { ok: true }; },
    readBinaryFile: async path => { try { return { ok: true, value: await readFile(path) }; } catch (error) { return { ok: false, error }; } }
  };
  // A screenshot's colour at its centre, read by the browser itself.
  const colour = async (tab, jpeg) => (await call(tab, 'Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `new Promise(resolve => {
    const image = new Image();
    image.onload = () => { const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      resolve([...context.getImageData(image.width >> 1, image.height >> 1, 1, 1).data.slice(0, 3)]); };
    image.src = 'data:image/jpeg;base64,${jpeg}'; })` }))?.result?.result?.value;
  // Each page's window, by the browser's own account.
  const windows = async () => {
    const browser = { webSocketDebuggerUrl: (await (await fetch(`${cdp}/json/version`)).json()).webSocketDebuggerUrl };
    const each = new Map();
    for (const page of await pages()) each.set(page.id, (await call(browser, 'Browser.getWindowForTarget', { targetId: page.id }))?.result?.windowId);
    return each;
  };
  // What a tab's page says: visible or hidden, and an expression's value.
  const evaluate = async (tab, expression) => (await call(tab, 'Runtime.evaluate', { expression, returnByValue: true }))?.result?.result?.value;
  return { port, home, shared, cdp, api: { env }, pages, call, colour, windows, evaluate };
}
