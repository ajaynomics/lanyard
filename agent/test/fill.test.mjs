// agent/guest/fill.mjs against real pages in a real Chromium over CDP: local
// https servers stand in for the sites (every name mapped to loopback, a
// throwaway self-signed certificate), and the fill runs as it does on a
// Sprite, with the sign-in in its environment alone.
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile, execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile } from 'node:fs/promises';
import { createServer } from 'node:https';
import { createServer as createHttpServer } from 'node:http';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { privateDir, spawnGroup } from './processes.mjs';

const GUEST = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest');
const CHROMIUM = [process.env.CHROME_BIN, '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable']
  .find(path => path && existsSync(path));
const PASSWORD = 'correct-horse-battery-staple-7731'; // gitleaks:allow (a made-up test password)
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

const SIGN_IN = '<form><input type="text" name="user"><input type="password" name="pass"></form>';
const PAGES = {
  '/plain': SIGN_IN,
  // Cal.com's shape: a select's hidden input (Base UI's, visually hidden but with
  // client rects) between the username and the password.
  '/cal': '<form><input type="text" name="url" value="cal.com/"><input type="text" name="username">' +
    '<input type="text" id="base-ui-_r_1_-hidden-input" tabindex="-1" style="position:absolute;width:1px;height:1px;margin:-1px;' +
    'overflow:hidden;clip:rect(0 0 0 0);border:0;padding:0;white-space:nowrap">' +
    '<input type="password" name="password" autocomplete="current-password"></form>',
  // A username-first sign-in's first step, with a search box after it.
  '/username-first': '<form><input type="text" name="account" autocomplete="username"></form><input type="text" name="q" placeholder="Search">',
  '/unlabelled': '<form><input type="text"></form>',
  // Another site's sign-in in a frame, beside a search box of the page's own.
  '/outer': '<input type="text" name="q" placeholder="Search"><iframe id="signin" style="width:400px;height:200px"></iframe>',
  // A bank's: an account number besides the user ID, each named by its label.
  '/account': '<form><label for="acct">Account Number</label><input type="text" id="acct" name="acct">' +
    '<label for="uid">User ID</label><input type="text" id="uid" name="uid"><input type="password" name="pass"></form>',
  // One named only by its placeholder, after the username.
  '/customer': '<form><input type="email" name="login"><input type="text" name="cust" placeholder="Customer number"><input type="password" name="pw"></form>',
  // An account box nobody can see is no account box.
  '/hidden-account': '<form><input type="text" name="accountNumber" style="display:none"><input type="text" name="user"><input type="password" name="pass"></form>',
  // A phone provider's settings, where an API password is set: a box for it and
  // one to confirm it, beside other settings, and a hidden password box.
  '/api-password': '<form><input type="text" name="allowed_ip" value="203.0.113.7"><input type="password" id="new_password" name="new_password">' +
    '<input type="password" id="confirm_password" name="confirm_password"><input type="text" name="note">' +
    '<input type="password" name="hidden_password" style="display:none"></form>'
};

// A Chromium with one tab, https sites on loopback (every name), plain http at
// plain.example.net, and the fill run as the Sprite runs it.
async function browser(t) {
  assert.ok(CHROMIUM, 'these tests need Chromium (set CHROME_BIN)');
  const dir = await privateDir('omakase-fill-');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem'),
    '-days', '1', '-subj', '/CN=example.com'], { stdio: 'ignore' });
  const serve = (request, response) => {
    const url = new URL(request.url, 'https://x');
    response.setHeader('content-type', 'text/html');
    let body = PAGES[url.pathname] ?? '';
    if (url.pathname === '/outer') body = body.replace('<iframe id="signin"', `<iframe id="signin" src="${url.searchParams.get('frame')}"`);
    response.end(`<title>${request.headers.host.split(':')[0]} ${url.pathname}</title>${body}`);
  };
  const site = createServer({ key: await readFile(join(dir, 'key.pem')), cert: await readFile(join(dir, 'cert.pem')) }, serve);
  const plain = createHttpServer(serve);
  await new Promise(resolve => site.listen(0, '127.0.0.1', resolve));
  await new Promise(resolve => plain.listen(0, '127.0.0.1', resolve));
  const port = site.address().port;
  const profile = join(dir, 'profile');
  spawnGroup(t, CHROMIUM, ['--headless=new', '--no-sandbox', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
    // Chrome (CI's) upgrades plain http to https first; the http case needs it plain.
    '--disable-features=HttpsUpgrades,HttpsFirstBalancedModeAutoEnable',
    `--user-data-dir=${profile}`, '--remote-debugging-address=127.0.0.1', '--remote-debugging-port=0', '--ignore-certificate-errors',
    `--host-resolver-rules=MAP plain.example.net 127.0.0.1:${plain.address().port}, MAP * 127.0.0.1:${port}`, 'about:blank'], { stdio: 'ignore' });
  t.after(() => { for (const server of [site, plain]) { server.closeAllConnections?.(); server.close(); } });
  for (let i = 0; i < 200 && !existsSync(join(profile, 'DevToolsActivePort')); i++) await pause(50);
  const cdp = `http://127.0.0.1:${(await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]}`;
  const home = join(dir, 'home');
  await mkdir(home);

  const targets = async () => (await (await fetch(`${cdp}/json/list`)).json());
  const pages = async () => (await targets()).filter(tab => tab.type === 'page');
  const call = async (target, method, params = {}) => {
    const socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    socket.send(JSON.stringify({ id: 1, method, params }));
    const reply = await Promise.race([new Promise(resolve => { socket.onmessage = event => { const message = JSON.parse(event.data); if (message.id === 1) resolve(message); }; }), pause(5000)]);
    socket.close();
    return reply?.result;
  };
  // Each input's name (or id) and value, in the page or frame on `url`.
  const values = async url => {
    const target = (await targets()).find(each => each.url.startsWith(url));
    assert.ok(target, `a page or frame on ${url}`);
    const read = await call(target, 'Runtime.evaluate', { returnByValue: true,
      expression: 'Object.fromEntries([...document.querySelectorAll("input")].map(field => [field.name || field.id || field.type, field.value]))' });
    return read.result.value;
  };
  // visit_website's own script, so the page is in the tab ~/.visit-tab names.
  const visit = url => new Promise(resolve => execFile(process.execPath, [join(GUEST, 'visit.mjs'), url.replace('PORT', port)],
    { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp } }, (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr })));
  const open = async url => {
    const visited = await visit(url);
    assert.equal(visited.code, 0, visited.stderr);
  };
  const fill = signIn => new Promise(resolve => execFile(process.execPath, [join(GUEST, 'fill.mjs')],
    { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, AGENT_SIGN_IN: JSON.stringify({ username: 'maya', password: PASSWORD, ...signIn }) } },
    (error, stdout, stderr) => {
      assert.equal(stdout.includes(PASSWORD) || stderr.includes(PASSWORD), false, 'the password is never printed');
      if (signIn.account) assert.equal(stdout.includes(signIn.account) || stderr.includes(signIn.account), false, 'nor the account');
      let reply = null;
      try { reply = JSON.parse(stdout); } catch {}
      resolve({ code: error?.code ?? 0, reply, stderr });
    }));
  return { port, cdp, pages, targets, call, values, open, visit, fill, url: path => `https://${path.replace('PORT', port)}` };
}

test('the sign-in goes to the tab visit_website opened, never to the person\'s tab in front or another window\'s, though each is a sign-in on the site', async t => {
  const chrome = await browser(t);
  const none = await chrome.fill({ host: 'example.com' });
  assert.equal(none.code, 0);
  assert.deepEqual(none.reply, { ok: false, error: 'Open the sign-in page with visit_website first.' });

  const [person] = await chrome.pages();
  await chrome.call(person, 'Page.navigate', { url: chrome.url('person.example.com:PORT/plain') });
  await chrome.open('https://app.example.com:PORT/plain');
  const version = await (await fetch(`${chrome.cdp}/json/version`)).json();
  await chrome.call(version, 'Target.createTarget', { url: chrome.url('other.example.com:PORT/plain'), newWindow: true });
  await pause(1000);

  const result = await chrome.fill({ host: 'example.com' });
  assert.equal(result.code, 0);
  assert.deepEqual(result.reply, { ok: true, filled: ['username', 'password'], url: chrome.url('app.example.com:PORT/plain') });
  assert.deepEqual(await chrome.values(chrome.url('app.example.com:PORT/plain')), { user: 'maya', pass: PASSWORD });
  assert.deepEqual(await chrome.values(chrome.url('person.example.com:PORT/plain')), { user: '', pass: '' });
  assert.deepEqual(await chrome.values(chrome.url('other.example.com:PORT/plain')), { user: '', pass: '' });
});

test('Cal.com\'s shape: the username and password are filled, never the select\'s hidden input between them', async t => {
  const chrome = await browser(t);
  await chrome.open('https://app.example.com:PORT/cal?next=%2F#top');
  const result = await chrome.fill({ host: 'example.com' });
  assert.equal(result.code, 0);
  assert.deepEqual(result.reply, { ok: true, filled: ['username', 'password'], url: chrome.url('app.example.com:PORT/cal') });
  assert.deepEqual(await chrome.values(chrome.url('app.example.com:PORT/cal')),
    { url: 'cal.com/', username: 'maya', 'base-ui-_r_1_-hidden-input': '', password: PASSWORD });
});

test('no password field: a field marked for the username is filled; a page with only an unlabelled text box is refused', async t => {
  const chrome = await browser(t);
  await chrome.open('https://accounts.example.com:PORT/username-first');
  const first = await chrome.fill({ host: 'example.com' });
  assert.equal(first.code, 0);
  assert.deepEqual(first.reply, { ok: true, filled: ['username'], url: chrome.url('accounts.example.com:PORT/username-first') });
  assert.deepEqual(await chrome.values(chrome.url('accounts.example.com:PORT/username-first')), { account: 'maya', q: '' });

  await chrome.open('https://accounts.example.com:PORT/unlabelled');
  const unlabelled = await chrome.fill({ host: 'example.com' });
  assert.equal(unlabelled.code, 0);
  assert.equal(unlabelled.reply.ok, false);
  assert.match(unlabelled.reply.error, /no password field/i);
  assert.deepEqual(await chrome.values(chrome.url('accounts.example.com:PORT/unlabelled')), { text: '' });
});

test('a sign-in in a frame from another site is filled when the frame is on the sign-in\'s site, never when only the page is', async t => {
  const chrome = await browser(t);
  const frame = chrome.url('idmsa.example.com:PORT/plain');
  await chrome.open(`https://www.example.org:PORT/outer?frame=${encodeURIComponent(frame)}`);
  assert.ok((await chrome.targets()).some(each => each.type === 'iframe' && each.url === frame), 'the frame runs in its own process');

  const inFrame = await chrome.fill({ host: 'idmsa.example.com' });
  assert.equal(inFrame.code, 0);
  assert.deepEqual(inFrame.reply, { ok: true, filled: ['username', 'password'], url: frame });
  assert.deepEqual(await chrome.values(frame), { user: 'maya', pass: PASSWORD });
  assert.deepEqual(await chrome.values(chrome.url('www.example.org:PORT/outer')), { q: '' });

  await chrome.open(`https://www.example.org:PORT/outer?frame=${encodeURIComponent(frame)}`);
  const onlyPage = await chrome.fill({ host: 'www.example.org' });
  assert.equal(onlyPage.code, 0);
  assert.equal(onlyPage.reply.ok, false);
  assert.match(onlyPage.reply.error, /no password field/i);
  assert.deepEqual(await chrome.values(frame), { user: '', pass: '' });
  assert.deepEqual(await chrome.values(chrome.url('www.example.org:PORT/outer')), { q: '' });
});

test('nothing is filled on another site, a look-alike, or over http, and the refusal names the tab it saw', async t => {
  const chrome = await browser(t);
  for (const url of ['https://bank.example.com.evil.test:PORT/plain', 'https://evilbank.example.com:PORT/plain', 'http://plain.example.net/plain']) {
    await chrome.open(url);
    const result = await chrome.fill({ host: url.startsWith('http:') ? 'plain.example.net' : 'bank.example.com' });
    assert.equal(result.code, 0, url);
    assert.equal(result.reply.ok, false, url);
    assert.match(result.reply.error, /^The tab visit_website last opened, ".+", is on https?:\/\/[a-z.]+, not on [a-z.]+ over https, so nothing was filled\.$/, url);
    assert.deepEqual(Object.values(await chrome.values(url.replace('PORT', chrome.port))), ['', ''], url);
  }
});

test('a saved account goes into the page\'s account box, the username into the user ID box, and the password into its own', async t => {
  const chrome = await browser(t);
  await chrome.open('https://bank.example.com:PORT/account');
  const result = await chrome.fill({ host: 'example.com', account: '12345' });
  assert.equal(result.code, 0);
  assert.deepEqual(result.reply, { ok: true, filled: ['account', 'username', 'password'], url: chrome.url('bank.example.com:PORT/account') });
  assert.deepEqual(await chrome.values(chrome.url('bank.example.com:PORT/account')), { acct: '12345', uid: 'maya', pass: PASSWORD });

  await chrome.open('https://bank.example.com:PORT/customer');
  const customer = await chrome.fill({ host: 'example.com', account: '12345' });
  assert.deepEqual(customer.reply.filled, ['account', 'username', 'password']);
  assert.deepEqual(await chrome.values(chrome.url('bank.example.com:PORT/customer')), { login: 'maya', cust: '12345', pw: PASSWORD });
});

test('a page with no account box is filled as before, and says the saved account was not needed', async t => {
  const chrome = await browser(t);
  for (const path of ['/plain', '/hidden-account']) {
    await chrome.open(`https://bank.example.com:PORT${path}`);
    const result = await chrome.fill({ host: 'example.com', account: '12345' });
    assert.equal(result.code, 0, path);
    assert.deepEqual(result.reply, { ok: true, filled: ['username', 'password'], url: chrome.url(`bank.example.com:PORT${path}`), accountUnused: true }, path);
    assert.equal(Object.values(await chrome.values(chrome.url(`bank.example.com:PORT${path}`))).includes('12345'), false, path);
  }
  await chrome.open('https://bank.example.com:PORT/hidden-account');
  const without = await chrome.fill({ host: 'example.com' });
  assert.deepEqual(without.reply.filled, ['username', 'password'], 'a hidden account box asks for nothing');
});

test('a page that asks for an account the saved sign-in lacks is not filled at all, and says so', async t => {
  const chrome = await browser(t);
  await chrome.open('https://bank.example.com:PORT/account');
  const result = await chrome.fill({ host: 'example.com' });
  assert.equal(result.code, 0);
  assert.equal(result.reply.ok, false);
  assert.match(result.reply.error, /^Nothing was filled: the page also asks for an account number/);
  assert.match(result.reply.error, /ask the person/i);
  assert.deepEqual(await chrome.values(chrome.url('bank.example.com:PORT/account')), { acct: '', uid: '', pass: '' });
});

// A real entry's "Account:" line held a note of a hundred characters, which was
// typed into a firm's account box. An account number has no spaces and is short.
test('an Account line that reads like a note is not typed, and the agent is told why', async t => {
  const chrome = await browser(t);
  await chrome.open('https://bank.example.com:PORT/account');
  const note = 'QZ7FIRM is the firm code but call the office first, the portal locks after two failed tries this month';
  const result = await chrome.fill({ host: 'example.com', account: note });
  assert.equal(result.code, 0);
  assert.equal(result.reply.ok, false);
  assert.match(result.reply.error, /^Nothing was filled: the saved sign-in's "Account:" line does not look like an account number/);
  assert.equal(result.reply.error.includes('QZ7FIRM'), false, 'the account is never echoed');
  assert.deepEqual(await chrome.values(chrome.url('bank.example.com:PORT/account')), { acct: '', uid: '', pass: '' });

  for (const odd of ['QZ7 FIRM', 'Q'.repeat(41)]) {
    const refused = await chrome.fill({ host: 'example.com', account: odd });
    assert.equal(refused.reply.ok, false, odd);
  }

  const code = await chrome.fill({ host: 'example.com', account: 'QZ7FIRM1' });
  assert.deepEqual(code.reply.filled, ['account', 'username', 'password']);
  assert.deepEqual(await chrome.values(chrome.url('bank.example.com:PORT/account')), { acct: 'QZ7FIRM1', uid: 'maya', pass: PASSWORD });
});

// The real case: setting an API password from a saved entry, where the site
// saves nothing until the Confirm Password box matches the New Password box.
test('named password boxes, a confirm box among them, get the password and nothing else is touched', async t => {
  const chrome = await browser(t);
  const page = chrome.url('phone.example.com:PORT/api-password');
  const before = { allowed_ip: '203.0.113.7', new_password: '', confirm_password: '', note: '', hidden_password: '' };
  await chrome.open('https://phone.example.com:PORT/api-password');
  const result = await chrome.fill({ host: 'example.com', password: undefined, username: undefined,
    boxes: { selectors: ['#new_password', 'input[name=confirm_password]'], password: PASSWORD } });
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(result.reply, { ok: true, filled: ['password box #new_password', 'password box input[name=confirm_password]'], url: page });
  assert.deepEqual(await chrome.values(page), { ...before, new_password: PASSWORD, confirm_password: PASSWORD });
});

test('a named box that is not a password box a person can see, or that is not on the page, fills nothing at all', async t => {
  const chrome = await browser(t);
  const page = chrome.url('phone.example.com:PORT/api-password');
  const before = { allowed_ip: '203.0.113.7', new_password: '', confirm_password: '', note: '', hidden_password: '' };
  await chrome.open('https://phone.example.com:PORT/api-password');
  for (const [named, error] of [
    ['input[name=note]', /^input\[name=note\] is not a password box a person can see, so nothing was filled\./],
    ['input[name=hidden_password]', /^input\[name=hidden_password\] is not a password box a person can see/],
    ['#nowhere', /^Nothing on the page matches #nowhere, so nothing was filled\./],
    ['###', /^Nothing on the page matches ###, so nothing was filled\./]
  ]) {
    const result = await chrome.fill({ host: 'example.com', password: undefined, username: undefined,
      boxes: { selectors: ['#new_password', named], password: PASSWORD } });
    assert.equal(result.code, 0, named);
    assert.equal(result.reply.ok, false, named);
    assert.match(result.reply.error, error, named);
    assert.deepEqual(await chrome.values(page), before, named);
  }

  await chrome.open('https://phone.example.net:PORT/api-password');
  const elsewhere = await chrome.fill({ host: 'example.com', password: undefined, username: undefined,
    boxes: { selectors: ['#new_password'], password: PASSWORD } });
  assert.equal(elsewhere.reply.ok, false);
  assert.match(elsewhere.reply.error, /not on example\.com over https/);
});
