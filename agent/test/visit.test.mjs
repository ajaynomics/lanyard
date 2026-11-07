// agent/guest/visit.mjs against a fake Chromium DevTools endpoint on loopback:
// the HTTP side (/json/list, /json/new, /json/activate, /json/close) and a
// websocket per tab. No browser, no network.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { readFile, writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { privateDir } from './processes.mjs';

const VISIT = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest', 'visit.mjs');

async function fakeChromium(t, personsTabs = ['person-1', 'person-2']) {
  const tabs = new Map(), requests = [], navigations = [];
  let made = 0, port;
  const add = id => tabs.set(id, { id, type: 'page', url: 'https://person.example/', get webSocketDebuggerUrl() { return `ws://127.0.0.1:${port}/devtools/page/${id}`; } });
  personsTabs.forEach(add);
  const server = createServer((request, response) => {
    requests.push(`${request.method} ${request.url}`);
    const send = body => response.end(typeof body === 'string' ? body : JSON.stringify(body));
    if (request.url === '/json/list') return send([...tabs.values()]);
    if (request.url.startsWith('/json/new')) { add(`agent-${++made}`); return send(tabs.get(`agent-${made}`)); }
    if (request.url.startsWith('/json/activate/')) return send('Target activated');
    response.writeHead(404).end();
  });
  const sockets = new WebSocketServer({ server });
  sockets.on('connection', (socket, request) => {
    const id = request.url.split('/').pop();
    socket.on('message', raw => {
      const { id: call, method, params } = JSON.parse(raw);
      const reply = result => socket.send(JSON.stringify({ id: call, result }));
      if (method === 'Page.navigate') {
        navigations.push([id, params.url]);
        tabs.get(id).url = params.url;
        reply({ frameId: 'f' });
        socket.send(JSON.stringify({ method: 'Page.loadEventFired', params: {} }));
      } else if (method === 'Runtime.evaluate') reply({ result: { value: JSON.stringify({ title: `Title of ${tabs.get(id).url}`, text: 'Hello' }) } });
      else if (method === 'Page.getLayoutMetrics') reply({ cssVisualViewport: { clientWidth: 1280, clientHeight: 700 } });
      // A big window: the picture is about 100 KB at full size and shrinks with the scale and quality asked for.
      else if (method === 'Page.captureScreenshot') reply({ data: process.env.FAKE_BIG_SHOT ? 'A'.repeat(Math.round(100_000 * (params.clip?.scale ?? 1) ** 2 * (params.quality / 80))) : '/9j/' });
      else reply({});
    });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
  let closed;
  const close = () => closed ??= new Promise(resolve => { sockets.close(); server.close(resolve); server.closeAllConnections?.(); });
  t.after(close);
  return { tabs, requests, navigations, url: `http://127.0.0.1:${port}`, close };
}

const visit = (home, cdp, url, extraEnv = {}) => new Promise(resolve => {
  execFile(process.execPath, [VISIT, url], { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, ...extraEnv } },
    (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr }));
});

test('every visit uses one tab: the first opens it, later ones navigate it and the page stays showing', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);

  const first = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(first.code, 0, first.stderr);
  assert.deepEqual(JSON.parse(first.stdout), { title: 'Title of https://one.example/', text: 'Hello', screenshot: '/9j/' });
  assert.equal(chromium.requests.filter(line => line.startsWith('PUT /json/new')).length, 1);
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-1');
  assert.deepEqual(chromium.requests.filter(line => line.includes('/json/activate/')), ['GET /json/activate/agent-1']);

  const second = await visit(home, chromium.url, 'https://two.example/');
  assert.equal(second.code, 0, second.stderr);
  assert.equal(JSON.parse(second.stdout).title, 'Title of https://two.example/');
  assert.equal(chromium.requests.filter(line => line.startsWith('PUT /json/new')).length, 1, 'no second tab');
  assert.deepEqual(chromium.navigations, [['agent-1', 'https://one.example/'], ['agent-1', 'https://two.example/']]);

  // The person's tabs are never navigated, and nothing is ever closed.
  assert.equal(chromium.tabs.size, 3);
  assert.equal(chromium.tabs.get('person-1').url, 'https://person.example/');
  assert.equal(chromium.requests.some(line => line.includes('/json/close')), false);
});

test('a remembered tab that is gone (closed by the person) is replaced, not trusted; the person\'s tabs are left alone', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  await writeFile(join(home, '.visit-tab'), 'agent-gone');

  const stale = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(stale.code, 0, stale.stderr);
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-1');
  assert.deepEqual(chromium.navigations, [['agent-1', 'https://one.example/']]);

  // The person closes it; the next visit opens one again.
  chromium.tabs.delete('agent-1');
  const again = await visit(home, chromium.url, 'https://two.example/');
  assert.equal(again.code, 0, again.stderr);
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-2');
  assert.deepEqual(chromium.navigations.at(-1), ['agent-2', 'https://two.example/']);
  assert.ok(!chromium.navigations.some(([id]) => id.startsWith('person')));
});

test('with no browser on the screen it exits 3 so the caller falls back to headless Chromium', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  await chromium.close();
  const result = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(result.code, 3);
  assert.match(result.stderr, /browser is not running/);
});

test('a big window never makes the output longer than the harness reads: the picture shrinks until it fits', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  // The fake browser runs in this process, so the flag is set here.
  process.env.FAKE_BIG_SHOT = '1';
  t.after(() => { delete process.env.FAKE_BIG_SHOT; });
  const big = await new Promise(resolve => execFile(process.execPath, [VISIT, 'https://one.example/'], {
    env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: chromium.url }, maxBuffer: 1 << 24 },
    (error, stdout) => resolve({ error, stdout })));
  assert.ok(big.stdout.length < 60_000, `output was ${big.stdout.length} characters`);
  assert.doesNotThrow(() => JSON.parse(big.stdout));
});
