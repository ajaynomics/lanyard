// agent/guest/visit.mjs against a fake Chromium DevTools endpoint on loopback:
// the HTTP side (/json/version, /json/list, /json/close), the browser's
// websocket (Target.createTarget, Target.activateTarget) and one per tab. No
// browser, no network. same-tab.test.mjs runs it against a real Chromium.
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
  const tabs = new Map(), requests = [], navigations = [], created = [], activated = [];
  // Tabs whose renderer has wedged: still listed, and the browser still answers for
  // them, but the page itself never answers a script or a navigation.
  const wedged = new Set();
  // Tabs that answer but never move: Page.navigate is answered and the earlier
  // page fires a load event, yet nothing commits (#73).
  const stuck = new Set();
  // Where an address redirects to, and tabs whose commits go unreported.
  const redirects = new Map(), unreported = new Set();
  let made = 0, port, fake;
  // Each tab's window (Browser.getWindowForTarget): the screen's is window 1.
  // One tab is in front, visible with the keyboard's focus.
  const add = (id, url = 'https://person.example/', window = 1) => tabs.set(id, { id, type: 'page', url, history: [url], window,
    get webSocketDebuggerUrl() { return `ws://127.0.0.1:${port}/devtools/page/${id}`; },
    toJSON() { return { id, type: 'page', url: this.url, webSocketDebuggerUrl: this.webSocketDebuggerUrl }; } });
  personsTabs.forEach(id => add(id));
  const server = createServer((request, response) => {
    requests.push(`${request.method} ${request.url}`);
    const send = body => response.end(typeof body === 'string' ? body : JSON.stringify(body));
    if (request.url === '/json/version') return send({ webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/browser/b` });
    if (request.url === '/json/list') return void setTimeout(() => send([...tabs.values()]), fake.listDelay ?? 0);
    if (request.url.startsWith('/json/close/')) { tabs.delete(request.url.split('/').pop()); return send('Target is closing'); }
    response.writeHead(404).end();
  });
  const sockets = new WebSocketServer({ server });
  sockets.on('connection', (socket, request) => {
    const id = request.url.split('/').pop();
    socket.on('message', raw => {
      const { id: call, method, params } = JSON.parse(raw);
      const reply = result => socket.send(JSON.stringify({ id: call, result }));
      if (wedged.has(id) && ['Runtime.evaluate', 'Page.navigate', 'Page.captureScreenshot', 'Page.getLayoutMetrics'].includes(method)) return;
      if (method === 'Target.createTarget' && fake.failCreate) socket.send(JSON.stringify({ id: call, error: { message: 'Target.createTarget failed' } }));
      // The browser exits mid-call: its socket closes and the call is never answered.
      else if (method === 'Target.createTarget' && fake.exitOnCreate) socket.terminate();
      else if (method === 'Target.createTarget') {
        created.push(params);
        add(`agent-${++made}`, params.url, params.newWindow ? 100 + made : 1);
        if (!params.background) fake.front = `agent-${made}`;
        reply({ targetId: `agent-${made}` });
      } else if (method === 'Target.activateTarget') {
        activated.push(params.targetId);
        fake.front = params.targetId;
        reply({});
      } else if (method === 'Browser.getWindowForTarget') {
        reply({ windowId: tabs.get(params.targetId)?.window });
      } else if (method === 'Page.getNavigationHistory') {
        const { history } = tabs.get(id);
        reply({ currentIndex: history.length - 1, entries: history.map(url => ({ url })) });
      } else if (method === 'Page.navigate') {
        navigations.push([id, params.url]);
        const event = (name, eventParams = {}) => socket.send(JSON.stringify({ method: name, params: eventParams }));
        if (stuck.has(id)) {
          reply({ frameId: 'f', loaderId: 'l' });
          return event('Page.loadEventFired');
        }
        const landed = redirects.get(params.url) ?? params.url;
        tabs.get(id).url = landed;
        tabs.get(id).history.push(landed);
        if (!unreported.has(id)) event('Page.frameNavigated', { frame: { id: 'f', loaderId: 'l', url: landed } });
        reply({ frameId: 'f', loaderId: 'l' });
        event('Page.loadEventFired');
      } else if (method === 'Runtime.evaluate' && /visibilityState/.test(params.expression)) {
        reply({ result: { value: fake.front === id ? ['visible', true] : fake.visible.has(id) ? ['visible', false] : ['hidden', false] } });
      } else if (method === 'Runtime.evaluate') reply({ result: { value: JSON.stringify({ url: tabs.get(id).url, title: `Title of ${tabs.get(id).url}`, text: 'Hello' }) } });
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
  // Tabs visible in a window of their own without the keyboard's focus.
  const visible = new Set();
  return fake = { tabs, requests, navigations, created, activated, wedged, stuck, redirects, unreported, visible, add, front: personsTabs[0],
    url: `http://127.0.0.1:${port}`, close };
}

const visit = (home, cdp, url, extraEnv = {}) => new Promise(resolve => {
  execFile(process.execPath, [VISIT, url], { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, ...extraEnv } },
    (error, stdout, stderr) => resolve({ code: error?.code ?? 0, stdout, stderr }));
});

// A new tab in the screen's window, not a window of its own (agent b10, 16 Nov).
const TAB = { url: 'about:blank#visit_website' };

test('a visit opens its page as a tab in the screen\'s window and brings it to the front; the same site reuses it, another site gets its own', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);

  const first = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(first.code, 0, first.stderr);
  assert.deepEqual(JSON.parse(first.stdout), { title: 'Title of https://one.example/', text: 'Hello', screenshot: '/9j/' });
  assert.deepEqual(chromium.created, [TAB], 'one tab, in the screen\'s window');
  assert.equal(chromium.front, 'agent-1', 'in front');
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-1');

  chromium.front = 'person-1';
  const second = await visit(home, chromium.url, 'https://www.one.example/more');
  assert.equal(second.code, 0, second.stderr);
  assert.equal(chromium.created.length, 1, 'the same site, the same tab');
  assert.equal(chromium.front, 'agent-1', 'brought to the front again');

  const third = await visit(home, chromium.url, 'https://two.example/');
  assert.equal(third.code, 0, third.stderr);
  assert.deepEqual(chromium.created, [TAB, TAB], 'another site, another tab');
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-2');
  assert.deepEqual(chromium.navigations, [['agent-1', 'https://one.example/'], ['agent-1', 'https://www.one.example/more'], ['agent-2', 'https://two.example/']]);
  assert.equal(chromium.tabs.get('agent-1').url, 'https://www.one.example/more', 'the first site keeps its tab');

  const back = await visit(home, chromium.url, 'https://one.example/again');
  assert.equal(back.code, 0, back.stderr);
  assert.equal(chromium.created.length, 2, 'back on the first site, its own tab again');
  assert.deepEqual(chromium.navigations.at(-1), ['agent-1', 'https://one.example/again']);
  assert.equal(chromium.front, 'agent-1');

  // The person's tabs are never navigated or closed.
  assert.equal(chromium.tabs.size, 4);
  assert.equal(chromium.tabs.get('person-1').url, 'https://person.example/');
  assert.equal(chromium.requests.some(line => /\/json\/close/.test(line)), false);
});

test('a remembered tab that is gone (closed by the person) is replaced, not trusted; the person\'s tabs are left alone', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  await writeFile(join(home, '.visit-tab'), 'agent-gone');

  const stale = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(stale.code, 0, stale.stderr);
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-1');
  assert.deepEqual(chromium.navigations, [['agent-1', 'https://one.example/']]);

  // The person closes it; the next visit opens a tab again.
  chromium.tabs.delete('agent-1');
  const again = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(again.code, 0, again.stderr);
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-2');
  assert.deepEqual(chromium.created, [TAB, TAB]);
  assert.deepEqual(chromium.navigations.at(-1), ['agent-2', 'https://one.example/']);
  assert.ok(!chromium.navigations.some(([id]) => id.startsWith('person')));
});

test('after the browser restarts, its tab is found by its first page and reused; a person\'s tab on the same site is not', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  assert.equal((await visit(home, chromium.url, 'https://one.example/')).code, 0);

  // The restart: new ids for every tab. The person's tab is on the visit's site too.
  chromium.tabs.clear();
  chromium.add('person-3', 'https://one.example/');
  chromium.add('restored-1', 'about:blank#visit_website');
  chromium.tabs.get('restored-1').history.push('https://one.example/');
  chromium.tabs.get('restored-1').url = 'https://one.example/';
  chromium.front = 'person-3';
  const again = await visit(home, chromium.url, 'https://one.example/next');
  assert.equal(again.code, 0, again.stderr);
  assert.equal(chromium.created.length, 1, 'no new tab');
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'restored-1');
  assert.deepEqual(chromium.navigations.at(-1), ['restored-1', 'https://one.example/next']);
  assert.equal(chromium.front, 'restored-1');
  assert.equal(chromium.tabs.get('person-3').url, 'https://one.example/');
});

test('a remembered tab whose page no longer answers is closed at once and the visit opens a new tab', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  assert.equal((await visit(home, chromium.url, 'https://one.example/')).code, 0);

  // Its tab is still listed and its history still read, but its page never answers.
  chromium.wedged.add('agent-1');
  const started = Date.now();
  const again = await visit(home, chromium.url, 'https://one.example/two');
  const elapsed = Date.now() - started;
  assert.equal(again.code, 0, again.stderr);
  assert.ok(elapsed < 15_000, `took ${elapsed} ms`);
  assert.equal(JSON.parse(again.stdout).title, 'Title of https://one.example/two');
  assert.ok(chromium.requests.includes('GET /json/close/agent-1'), 'the wedged tab is closed');
  assert.deepEqual(chromium.created, [TAB, TAB]);
  assert.equal(await readFile(join(home, '.visit-tab'), 'utf8'), 'agent-2');
  assert.deepEqual(chromium.navigations.at(-1), ['agent-2', 'https://one.example/two']);
  assert.ok(!chromium.navigations.some(([id]) => id.startsWith('person')));
});

test('a tab that answers but never leaves the earlier page fails the visit, naming both addresses, instead of reporting that page', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  assert.equal((await visit(home, chromium.url, 'https://not-found.example.org/missing')).code, 0);

  // Another site: a new tab, which never leaves its first page.
  chromium.stuck.add('agent-2');
  const stale = await visit(home, chromium.url, 'https://example.com/someone');
  assert.equal(stale.code, 1, stale.stdout);
  assert.equal(stale.stdout, '');
  assert.equal(stale.stderr.trim(),
    'The browser could not open https://example.com/someone (the tab is on about:blank#visit_website instead).');
});

test('a redirect to another site that the navigation committed is the page visited; so is one within the site, reported or not', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  chromium.redirects.set('https://short.example.com/go', 'https://landing.example.org/page');
  const away = await visit(home, chromium.url, 'https://short.example.com/go');
  assert.equal(away.code, 0, away.stderr);
  assert.equal(JSON.parse(away.stdout).title, 'Title of https://landing.example.org/page');

  // Within the site the address alone is enough, even with no commit reported.
  chromium.unreported.add('agent-2');
  chromium.redirects.set('https://example.com/about', 'https://www.example.com/about/#team');
  const within = await visit(home, chromium.url, 'https://example.com/about');
  assert.equal(within.code, 0, within.stderr);
  assert.equal(JSON.parse(within.stdout).title, 'Title of https://www.example.com/about/#team');

  // Another site the navigation never reported landing on is not.
  chromium.redirects.set('https://example.com/elsewhere', 'https://example.org/');
  const unexplained = await visit(home, chromium.url, 'https://example.com/elsewhere');
  assert.equal(unexplained.code, 1);
  assert.match(unexplained.stderr, /the tab is on https:\/\/example\.org\/ instead/);
});

// Background tabs seldom answer a script in time: asked one by one, 34 tabs
// took the visit's whole 40 seconds before it navigated.
test('a browser with many tabs that never answer still gets its visit within its time', async t => {
  const home = await privateDir('omakase-visit-');
  const persons = Array.from({ length: 34 }, (_, i) => `person-${i + 1}`);
  const chromium = await fakeChromium(t, persons);
  for (const id of persons.slice(0, -1)) chromium.wedged.add(id);
  chromium.front = 'person-34';
  const started = Date.now();
  const result = await visit(home, chromium.url, 'https://one.example/');
  const took = Date.now() - started;
  assert.equal(result.code, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).title, 'Title of https://one.example/');
  assert.ok(took < 10_000, `took ${took} ms`);
  assert.deepEqual(chromium.navigations, [['agent-1', 'https://one.example/']]);
});

// The tabs answer together now, so the one in front is still the focused
// one, not merely the first visible: its window is the screen's, and the
// visit's own tabs in any other window are closed.
test('the tab in front is the visible one with the keyboard\'s focus, wherever it is in the list', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t, []);
  chromium.add('own-1', 'about:blank#visit_website', 1);
  chromium.add('own-2', 'about:blank#visit_website', 2);
  chromium.visible.add('own-1');
  chromium.front = 'own-2';
  const result = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(result.code, 0, result.stderr);
  assert.deepEqual(chromium.navigations, [['own-2', 'https://one.example/']]);
  assert.ok(chromium.requests.includes('GET /json/close/own-1'), 'the tab behind is closed');
  assert.ok(!chromium.requests.includes('GET /json/close/own-2'));
});

// Choosing the tab has a bound of its own, outside the page's 40 seconds.
test('a browser too slow to give the visit its tab fails it within the choosing\'s own bound, saying so', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  chromium.wedged.add('person-2');
  chromium.listDelay = 4900;
  const started = Date.now();
  const result = await visit(home, chromium.url, 'https://one.example/');
  const took = Date.now() - started;
  assert.equal(result.code, 1, result.stderr);
  assert.equal(result.stderr, 'The browser could not open https://one.example/ (its tabs did not answer within 10 s).\n');
  assert.ok(took < 12_000, `took ${took} ms`);
  assert.deepEqual(chromium.navigations, []);
});

test('a browser that answers but cannot give the visit a tab fails the visit; only one that cannot be reached falls back to headless', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  chromium.failCreate = true;
  const result = await visit(home, chromium.url, 'https://one.example/');
  assert.equal(result.code, 1, result.stderr);
  assert.match(result.stderr, /^The browser could not open https:\/\/one\.example\/ \(no tab for it: /);
});

// A browser that dies mid-call closes its socket; waiting out the call's
// time limit would read as a hang, and hide that it died (#575).
test('a browser whose connection closes mid-call fails the visit at once, saying so', async t => {
  const home = await privateDir('omakase-visit-');
  const chromium = await fakeChromium(t);
  chromium.exitOnCreate = true;
  const started = performance.now();
  const result = await visit(home, chromium.url, 'https://one.example/');
  const took = performance.now() - started;
  assert.equal(result.code, 1, result.stderr);
  assert.match(result.stderr, /^The browser could not open https:\/\/one\.example\/ \(no tab for it: the browser closed its connection\)/);
  // Target.createTarget's own limit is 5 seconds.
  assert.ok(took < 2500, `took ${Math.round(took)} ms`);
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
