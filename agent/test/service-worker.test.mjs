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
    registration: { showNotification: async (title, options) => shown.push({ title, ...options }) },
    navigator: badge ? { setAppBadge: async count => badges.push(count), clearAppBadge: async () => badges.push(0) } : {},
  };
  const context = vm.createContext({ self, Response, URL });
  vm.runInContext(source, context);
  const push = async notice => {
    let done;
    handlers.push({ data: { json: () => notice }, waitUntil: promise => { done = promise; } });
    await done;
  };
  return { shouldShow: context.shouldShow, push, shown, badges };
}

const reply = { kind: 'reply', title: 'Iris', body: 'The flights are booked.', url: '/conversations/7', tag: 'conversation-7', badge: 0 };
const needsYou = { kind: 'needs_you', title: 'Iris needs you', body: 'Allow send email?', url: '/conversations/7', tag: 'conversation-7', badge: 2 };
const focusedOn = path => ({ focused: true, url: `https://agents.example.com${path}` });

test('a reply shows unless a focused window is already on its thread', () => {
  const { shouldShow } = worker();
  assert.equal(shouldShow(reply, []), true);
  assert.equal(shouldShow(reply, [ focusedOn('/conversations/8') ]), true);
  assert.equal(shouldShow(reply, [ { focused: false, url: 'https://agents.example.com/conversations/7' } ]), true);
  assert.equal(shouldShow(reply, [ focusedOn('/conversations/7') ]), false);
});

test('an agent that needs the person always shows, even on its own thread', () => {
  const { shouldShow } = worker();
  assert.equal(shouldShow(needsYou, [ focusedOn('/conversations/7') ]), true);
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

test('a reply on the thread in front is not shown, and the badge still clears', async () => {
  const sw = worker({ windows: [ focusedOn('/conversations/7') ] });
  await sw.push(reply);
  assert.deepEqual(sw.badges, [ 0 ]);
  assert.equal(sw.shown.length, 0);
});

test('without the Badging API a notice still shows', async () => {
  const sw = worker({ badge: false });
  await sw.push(reply);
  assert.equal(sw.shown.length, 1);
});
