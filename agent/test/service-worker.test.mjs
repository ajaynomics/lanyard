import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

// The Rails app's service worker (app/views/pwa/service-worker.js), run in a
// stand-in for the worker's global: which notices it shows, and what it shows.
// It lives with the sidecar's tests because this is where node --test runs.
const source = await readFile(new URL('../../app/views/pwa/service-worker.js', import.meta.url), 'utf8');

function worker({ windows = [], badge = true } = {}) {
  const handlers = {};
  const shown = [];
  const badges = [];
  const self = {
    location: { origin: 'https://agents.example.com' },
    addEventListener: (type, handler) => { handlers[type] = handler; },
    skipWaiting: () => {},
    clients: { claim: async () => {}, matchAll: async () => windows, openWindow: async url => shown.push({ opened: url }) },
    registration: {
      showNotification: async (title, options) => shown.push({ title, ...options, closed: false }),
      getNotifications: async ({ tag }) => shown.filter(it => it.tag === tag).map(it => ({ close: () => { it.closed = true; } })),
    },
    navigator: badge ? { setAppBadge: async count => badges.push(count), clearAppBadge: async () => badges.push(0) } : {},
  };
  const context = vm.createContext({ self, Response, URL });
  vm.runInContext(source, context);
  const wait = (type, event) => { let done; handlers[type]({ ...event, waitUntil: promise => { done = promise; } }); return done; };
  const push = notice => wait('push', { data: notice === null ? null : { json: () => notice } });
  const pushData = data => wait('push', { data });
  const click = url => wait('notificationclick', { notification: { close: () => {}, data: { url } } });
  return { push, pushData, click, shown, badges };
}

const reply = { kind: 'reply', title: 'Iris', body: 'The flights are booked.', url: '/conversations/7', tag: 'conversation-7', badge: 0 };
const needsYou = { kind: 'needs_you', title: 'Iris needs you', body: 'Allow send email?', url: '/conversations/7', tag: 'conversation-7', badge: 2 };
const focusedOn = path => ({ focused: true, url: `https://agents.example.com${path}` });
const loud = sw => sw.shown.filter(it => !it.silent && !it.closed).map(it => it.title);

// iOS takes a subscription away after a few pushes that show nothing.
test('every push shows a notification: a reply on a thread not in front shows as usual', async () => {
  for (const windows of [ [], [ focusedOn('/conversations/8') ], [ { focused: false, url: 'https://agents.example.com/conversations/7' } ] ]) {
    const sw = worker({ windows });
    await sw.push(reply);
    assert.deepEqual(loud(sw), [ 'Iris' ]);
  }
});

test('a reply on the thread in front is shown silently and closed at once, and the badge still clears', async () => {
  const sw = worker({ windows: [ focusedOn('/conversations/7') ] });
  await sw.push(reply);
  assert.deepEqual(sw.badges, [ 0 ]);
  assert.equal(sw.shown.length, 1);
  assert.deepEqual([ sw.shown[0].silent, sw.shown[0].closed ], [ true, true ]);
  assert.deepEqual(loud(sw), []);
});

test('an agent that needs the person always shows, even on its own thread', async () => {
  const sw = worker({ windows: [ focusedOn('/conversations/7') ] });
  await sw.push(needsYou);
  assert.deepEqual(loud(sw), [ 'Iris needs you' ]);
});

test('a push shows the notice by its thread tag and sets the badge', async () => {
  const sw = worker();
  await sw.push(needsYou);
  assert.deepEqual(sw.badges, [ 2 ]);
  assert.equal(sw.shown.length, 1);
  assert.equal(sw.shown[0].title, 'Iris needs you');
  assert.equal(sw.shown[0].body, 'Allow send email?');
  assert.equal(sw.shown[0].tag, 'conversation-7');
  assert.deepEqual({ ...sw.shown[0].data }, { url: '/conversations/7' });
});

test('an empty, untitled or broken push still shows one, opening the app, and leaves the badge alone', async () => {
  const sw = worker();
  await sw.push(null);
  await sw.push({});
  await sw.pushData({ json: () => { throw new SyntaxError('Unexpected token'); } });
  assert.deepEqual(loud(sw), [ 'New activity', 'New activity', 'New activity' ]);
  assert.deepEqual(sw.shown.map(it => it.data.url), [ '/', '/', '/' ]);
  assert.deepEqual(sw.badges, []);
});

test('without the Badging API a notice still shows', async () => {
  const sw = worker({ badge: false });
  await sw.push(reply);
  assert.equal(sw.shown.length, 1);
});

test('a click focuses the window on the thread, else moves the app\'s open window there, else opens one', async () => {
  const focused = [];
  const navigated = [];
  const on = { url: 'https://agents.example.com/conversations/7', focus: async () => focused.push('on') };
  const other = { url: 'https://agents.example.com/settings/account', focus: async () => other, navigate: async url => navigated.push(url) };

  await worker({ windows: [ other, on ] }).click('/conversations/7');
  assert.deepEqual(focused, [ 'on' ]);

  await worker({ windows: [ other ] }).click('/conversations/7');
  assert.deepEqual(navigated, [ 'https://agents.example.com/conversations/7' ]);

  const none = worker();
  await none.click('/conversations/7');
  assert.deepEqual(none.shown, [ { opened: 'https://agents.example.com/conversations/7' } ]);
});
