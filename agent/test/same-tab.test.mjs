// visit_website and the saved sign-in's filler agree on the page, in a real
// Chromium (agent/test/real-browser.mjs): visit.mjs, fill.mjs, browser.mjs and
// sign-in.mjs are the real ones.
//
// Every page the agent opens is a tab in the screen's one window, brought to
// the front, so the person sees what the agent sees and the filler types into
// the page in front (agent b10, 16 Nov). The visit's earlier "window of its
// own" opened behind the person's: the person's screen kept an old about:blank
// window in front and ctrl+Tab could not reach the visit's. And a visit never
// navigates away from a tab another site is using: one that did locked a
// person out ("another instance open").
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { visitWebsite } from '../browser.mjs';
import { fillSignIn } from '../sign-in.mjs';
import { screen as realScreen, pause, text } from './real-browser.mjs';

const PASSWORD = 'correct-horse-battery-staple-7731'; // gitleaks:allow (a made-up test password)
const CALL = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'sign_in_with_saved_password', arguments: { name: 'Portal' } };

async function screen(t) {
  const browser = await realScreen(t);
  return { ...browser,
    visit: url => visitWebsite.execute({ url }, browser.api, ctx),
    signIn: host => fillSignIn(async () => ({ host, username: 'maya', password: PASSWORD }), CALL, { signIn: 'Portal' }, browser.api, ctx),
    visitTab: async () => (await readFile(join(browser.home, '.visit-tab'), 'utf8')).trim() };
}
const near = (actual, expected) => actual?.every((value, i) => Math.abs(value - expected[i]) < 40);

test('the agent\'s tab crashed: visit_website replaces it, and the sign-in fills the page it reported', async t => {
  const browser = await screen(t);
  const [tab] = await browser.pages();
  await writeFile(join(browser.home, '.visit-tab'), tab.id);
  await browser.call(tab, 'Page.navigate', { url: `https://login.example.com:${browser.port}/paint/0000ff` });
  await pause(500);
  await browser.call(tab, 'Page.crash');
  await pause(500);

  const visited = await browser.visit(`https://login.example.com:${browser.port}/`);
  assert.match(text(visited), /Title: Sign in to login\.example\.com/);

  const showing = await browser.pages();
  assert.deepEqual(showing.map(page => new URL(page.url).hostname), ['login.example.com'], 'one tab, on the page visit_website reported');
  assert.equal(await browser.visitTab(), showing[0].id);

  const filled = await browser.signIn('login.example.com');
  assert.equal(filled.isError, undefined, text(filled));
  assert.match(text(filled), /^Filled the username and password for Portal on https:\/\/login\.example\.com:\d+\/\./);
  assert.equal(JSON.stringify(filled).includes(PASSWORD), false);
});

test('the agent\'s tab on another site: a sign-in there is refused naming the tab and host it saw; after visit_website it fills', async t => {
  const browser = await screen(t);
  await browser.visit(`https://other.example.com:${browser.port}/`);
  const other = await browser.visitTab();

  const refused = await browser.signIn('login.example.com');
  assert.equal(refused.isError, true);
  assert.match(text(refused), /"Sign in to other\.example\.com", is on https:\/\/other\.example\.com,/, 'names the tab and host it saw');
  assert.match(text(refused), /not on login\.example\.com over https, so nothing was filled/);
  assert.equal(JSON.stringify(refused).includes(PASSWORD), false);

  const visited = await browser.visit(`https://login.example.com:${browser.port}/`);
  assert.match(text(visited), /Title: Sign in to login\.example\.com/);
  assert.notEqual(await browser.visitTab(), other, 'a tab of its own for the other site');
  assert.equal((await browser.pages()).find(page => page.id === other)?.url, `https://other.example.com:${browser.port}/`, 'the other site keeps its tab');
  const filled = await browser.signIn('login.example.com');
  assert.equal(filled.isError, undefined, text(filled));
});

// Agent b10, 16 Nov: the page opened in a window of its own, the fill typed
// there, and the person's screen kept an old window in front.
test('after visit_website and the fill, the tab in front of the screen\'s one window is the filled page, and the earlier tab keeps its URL', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  const earlier = `https://person.example.com:${browser.port}/paint/00ff00`;
  await browser.call(person, 'Page.navigate', { url: earlier });
  await pause(500);

  const visited = await browser.visit(`https://login.example.com:${browser.port}/sign-in`);
  assert.equal(visited.isError, undefined, text(visited));
  const filled = await browser.signIn('login.example.com');
  assert.equal(filled.isError, undefined, text(filled));

  const id = await browser.visitTab();
  const tabs = await browser.pages();
  const windows = await browser.windows();
  assert.equal(new Set(windows.values()).size, 1, 'one window on the screen');
  assert.deepEqual(tabs.map(tab => tab.id).sort(), [person.id, id].sort(), 'the person\'s tab and the visit\'s new tab');
  const visit = tabs.find(tab => tab.id === id);
  assert.equal(await browser.evaluate(visit, 'document.visibilityState'), 'visible', 'the filled page is the tab in front');
  assert.equal(await browser.evaluate(visit, 'document.querySelector("[name=pass]").value'), PASSWORD, 'and is the page filled');
  assert.equal(await browser.evaluate(person, 'document.visibilityState'), 'hidden', 'the earlier tab is behind it');
  assert.equal(tabs.find(tab => tab.id === person.id).url, earlier, 'the earlier tab keeps its URL');
  assert.ok(near(await browser.colour(person, (await browser.call(visit, 'Page.captureScreenshot', { format: 'jpeg' }))?.result?.data), [255, 255, 255]),
    'a screenshot of the tab in front answers');
});

test('visit_website reuses its own tab on the same site, opens a new one for another site, and never navigates a tab it did not open', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  const paint = (host, colour) => `https://${host}:${browser.port}/paint/${colour}`;
  const inFront = async id => browser.evaluate((await browser.pages()).find(tab => tab.id === id), 'document.visibilityState');

  for (const colour of ['ff0000', '00ff00']) assert.match(text(await browser.visit(paint('login.example.com', colour))), new RegExp(`Title: ${colour}`));
  const login = await browser.visitTab();
  assert.match(text(await browser.visit(paint('www.example.org', '0000ff'))), /Title: 0000ff/);
  const org = await browser.visitTab();
  assert.notEqual(org, login, 'another site, another tab');
  assert.match(text(await browser.visit(paint('login.example.com', 'ffff00'))), /Title: ffff00/);
  assert.equal(await browser.visitTab(), login, 'back on the first site, its tab again');
  assert.equal(await inFront(login), 'visible', 'brought to the front');

  const tabs = await browser.pages();
  assert.equal(tabs.length, 3);
  assert.equal(new Set((await browser.windows()).values()).size, 1, 'all in the screen\'s one window');
  assert.equal(tabs.find(tab => tab.id === org).url, paint('www.example.org', '0000ff'), 'the other site\'s tab keeps its page');
  assert.equal(tabs.find(tab => tab.id === person.id).url, 'about:blank', 'the person\'s tab is never navigated');

  // A tab a site opened is never the visit's, even on the visit's site.
  await browser.call(tabs.find(tab => tab.id === login), 'Runtime.evaluate', { expression: 'window.open("/paint/00ffff")', userGesture: true });
  await pause(1000);
  const opened = (await browser.pages()).find(tab => tab.url === paint('login.example.com', '00ffff'));
  assert.ok(opened, 'the site opened a tab');
  await browser.call(tabs.find(tab => tab.id === login), 'Page.crash');
  await pause(500);
  assert.match(text(await browser.visit(paint('login.example.com', 'ff00ff'))), /Title: ff00ff/);
  assert.notEqual(await browser.visitTab(), opened.id);
  assert.equal((await browser.pages()).find(tab => tab.id === opened.id).url, paint('login.example.com', '00ffff'), 'the site\'s tab keeps its page');
});

// A Sprite made before this kept its visits in a window of their own, behind
// the person's. That window is the agent's: it is closed, so no page is left
// in a hidden window, and the visit opens in the person's window.
test('an older Sprite\'s visit window, behind the person\'s, is closed and the page opens as a tab in front of the person\'s window', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  await browser.call(person, 'Page.navigate', { url: `https://person.example.com:${browser.port}/paint/00ff00` });
  await pause(500);
  const version = { webSocketDebuggerUrl: (await (await fetch(`${browser.cdp}/json/version`)).json()).webSocketDebuggerUrl };
  const old = (await browser.call(version, 'Target.createTarget', { url: 'about:blank#visit_website', newWindow: true, background: true }))?.result?.targetId;
  assert.ok(old, 'the old visit window opened');
  await browser.call((await browser.pages()).find(tab => tab.id === old), 'Page.navigate', { url: `https://old.example.com:${browser.port}/paint/0000ff` });
  await pause(500);
  await fetch(`${browser.cdp}/json/activate/${person.id}`);
  await pause(500);
  assert.equal(new Set((await browser.windows()).values()).size, 2, 'set-up: two windows');
  await writeFile(join(browser.home, '.visit-tab'), old);

  const visited = await browser.visit(`https://login.example.com:${browser.port}/paint/ff0000`);
  assert.equal(visited.isError, undefined, text(visited));
  assert.ok(near(await browser.colour(person, visited.output[1].data), [255, 0, 0]), 'the screenshot shows the page asked for');

  const after = await browser.windows();
  const id = await browser.visitTab();
  assert.equal(after.has(old), false, 'the old visit window is closed');
  assert.equal(after.get(id), after.get(person.id), 'the page is a tab in the person\'s window');
  assert.equal(await browser.evaluate((await browser.pages()).find(tab => tab.id === id), 'document.visibilityState'), 'visible');
  assert.equal((await browser.pages()).find(tab => tab.id === person.id).url, `https://person.example.com:${browser.port}/paint/00ff00`);
});

// The check that the tab left the earlier page (#73) lets a redirect through
// when the navigation itself committed where it landed, on another site too.
test('a redirect to another site shows the page it lands on, reported as visited', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  assert.match(text(await browser.visit(`https://short.example.com:${browser.port}/paint/0000ff`)), /Title: 0000ff on short\.example\.com/);

  const visited = await browser.visit(`https://short.example.com:${browser.port}/moved`);
  assert.equal(visited.isError, undefined, text(visited));
  assert.match(text(visited), /Title: ff00ff on landing\.example\.org/);
  assert.ok(near(await browser.colour(person, visited.output[1].data), [255, 0, 255]), 'the screenshot shows where it landed');
  assert.equal((await browser.pages()).find(page => page.id === person.id).url, 'about:blank');
  const id = await browser.visitTab();
  assert.equal((await browser.pages()).find(page => page.id === id).url, `https://landing.example.org:${browser.port}/paint/ff00ff`);
});
