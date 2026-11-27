// agent/fill-socket.mjs against a real Unix socket answering DevTools as the host's fill.sock does.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { chmod, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { WebSocketServer } from 'ws';
import { eventually, privateDir } from './processes.mjs';
import { FILL_SCRIPTS, PAUSED, fillOnly, fillInBrowser, workerExit } from '../fill-socket.mjs';

async function devtools(t) {
  const root = await privateDir('omakase-browsers-');
  await mkdir(join(root, 'avery'));
  const seen = { hosts: [], methods: [] };
  const server = createServer((request, response) => {
    seen.hosts.push(request.headers.host);
    seen.methods.push(`GET ${request.url}`);
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify([{ id: 'A1', type: 'page', url: 'https://example.com/', webSocketDebuggerUrl: 'ws://localhost/devtools/page/A1' }]));
  });
  const pages = new WebSocketServer({ server });
  pages.on('connection', (socket, request) => {
    seen.hosts.push(request.headers.host);
    socket.on('message', data => {
      const message = JSON.parse(data);
      seen.methods.push(message.method);
      socket.send(JSON.stringify({ id: message.id, result: {} }));
    });
  });
  const socket = join(root, 'avery', 'fill.sock');
  await new Promise(resolve => server.listen(socket, resolve));
  t.after(() => { for (const client of pages.clients) client.terminate(); pages.close(); server.close(); });
  return { root, socket, seen };
}

test('the fill socket takes a fill\'s few calls; any other is refused and never reaches the browser', async t => {
  const { socket, seen } = await devtools(t);
  const browser = fillOnly(socket);
  const [tab] = await (await browser.fetch('http://localhost/json/list')).json();
  await assert.rejects(browser.fetch('http://localhost/json/new?https://example.com/'), /only the list of tabs/);
  assert.throws(() => new browser.WebSocket('ws://localhost/devtools/browser/B1'), /only a tab/);

  const page = new browser.WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { page.addEventListener('open', resolve); page.addEventListener('error', reject); });
  t.after(() => page.close());
  const replies = new Map();
  page.addEventListener('message', event => { const message = JSON.parse(event.data); replies.set(message.id, message); });
  const ask = async (id, method, params = {}) => {
    page.send(JSON.stringify({ id, method, params }));
    return eventually(() => replies.get(id));
  };

  assert.deepEqual((await ask(1, 'Page.getFrameTree')).result, {});
  // fill.mjs's own fill, as it writes the call; then the same start with any other body, code or value.
  const [fill] = FILL_SCRIPTS, filling = `${fill}"example.com", true, false, null)`;
  const scripts = ['document.body.innerText', '(function fill(sameSite) { return document.body.innerText })(null)',
    `${filling};document.body.innerText`, `${filling}, (() => document.body.innerText)()`, `${fill}"example.com", true, false, document.cookie)`,
    `${fill}"example.com",true, false, null)`];
  const refused = [['Page.navigate', { url: 'https://example.net/' }], ['Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter' }],
    ['DOM.getDocument'], ['Target.createTarget', { url: 'about:blank' }], ...scripts.map(expression => ['Runtime.evaluate', { expression, returnByValue: true }])];
  for (const [index, [method, params]] of refused.entries())
    assert.match((await ask(index + 2, method, params)).error.message, /is not part of a fill/, params?.expression ?? method);
  assert.equal(FILL_SCRIPTS.length, 2, 'fill.mjs\'s fill and fillBoxes, read from its own file');
  assert.deepEqual((await ask(99, 'Runtime.evaluate', { expression: filling, returnByValue: true })).result, {});

  assert.deepEqual(seen.methods, ['GET /json/list', 'Page.getFrameTree', 'Runtime.evaluate']);
  assert.deepEqual([...new Set(seen.hosts)], ['localhost'], 'Chromium answers only Host: localhost');
});

test('no browser at the socket, or a name that is not one, fills nothing and says so', async t => {
  const { root } = await devtools(t);
  assert.equal(await fillInBrowser('blake', { host: 'example.com', password: 'x' }, { root }), null, 'no socket: the browser is not running');
  assert.deepEqual(await fillInBrowser('../avery', { host: 'example.com', password: 'x' }, { root }), { ok: false, error: 'That is not an agent\'s browser.' });
});

test('a fill.sock the host has held (refused to Core) says sign-ins are paused, not that the browser is down', async t => {
  assert.equal(workerExit(Object.assign(new Error('connect EACCES'), { code: 'EACCES' })), 4);
  assert.equal(workerExit(Object.assign(new Error('connect ENOENT'), { code: 'ENOENT' })), 3);
  const { root } = await devtools(t);
  if (process.getuid?.() === 0) return t.diagnostic('root reads any socket: the refusal is checked by workerExit above');
  await chmod(join(root, 'avery', 'fill.sock'), 0o000);
  assert.deepEqual(await fillInBrowser('avery', { host: 'example.com', password: 'x' }, { root }), { ok: false, error: PAUSED });
});
