// Files and popups between the screen's browser and the agent, in a real
// Chromium (agent/test/real-browser.mjs): browser_upload (agent/browser-upload.mjs
// and agent/guest/upload.mjs) and a page's window.open. Downloads, and popups a
// page opens late, depend on the image's Chromium policy, so
// bin/check-computer-image checks those on the image as built.
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFile } from 'node:child_process';
import { mkdir, readFile, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { visitWebsite } from '../browser.mjs';
import { browserUpload } from '../browser-upload.mjs';
import { screen, pause, text } from './real-browser.mjs';

const UPLOAD = new URL('../guest/upload.mjs', import.meta.url).pathname;

test('a page\'s button that calls window.open, clicked, opens a tab in front of the screen\'s window, which the agent can read and close', async t => {
  const browser = await screen(t);
  await visitWebsite.execute({ url: `https://docs.example.com:${browser.port}/popup` }, browser.api, ctx);
  const id = (await readFile(join(browser.home, '.visit-tab'), 'utf8')).trim();
  const tab = (await browser.pages()).find(each => each.id === id);
  for (const type of ['mousePressed', 'mouseReleased']) await browser.call(tab, 'Input.dispatchMouseEvent', { type, x: 100, y: 100, button: 'left', clickCount: 1 });
  await pause(1500);

  const opened = (await browser.pages()).find(each => each.url === `https://docs.example.com:${browser.port}/paint/ff00ff`);
  assert.ok(opened, 'the page opened its popup');
  const windows = await browser.windows();
  assert.equal(windows.get(opened.id), windows.get(id), 'as a tab in the same window');
  assert.equal(await browser.evaluate(opened, 'document.visibilityState'), 'visible', 'in front');
  assert.equal(await browser.evaluate(tab, 'document.visibilityState'), 'hidden');

  const read = await visitWebsite.execute({ url: opened.url }, browser.api, ctx);
  assert.match(text(read), /Title: ff00ff on docs\.example\.com/, 'visit_website reads the same site\'s page');
  await fetch(`${browser.cdp}/json/close/${opened.id}`);
  await pause(500);
  assert.equal((await browser.pages()).some(each => each.id === opened.id), false, 'and it closes');
});

async function uploadPage(t) {
  const browser = await screen(t);
  await visitWebsite.execute({ url: `https://bank.example.com:${browser.port}/upload` }, browser.api, ctx);
  await mkdir(join(browser.home, 'docs'));
  await writeFile(join(browser.home, 'docs', 'statement.pdf'), Buffer.alloc(1234, 7));
  const upload = args => browserUpload.execute(args, browser.api, ctx);
  const title = async () => browser.evaluate((await browser.pages()).find(each => each.url.endsWith('/upload')), 'document.title');
  return { ...browser, upload, title };
}

test('browser_upload puts a file from the agent\'s home into the file field of visit_website\'s tab, found by its label, and the page reads its name and size', async t => {
  const browser = await uploadPage(t);
  const done = await browser.upload({ field: 'Statement', path: 'docs/statement.pdf' });
  assert.equal(done.isError, undefined, text(done));
  assert.match(text(done), /statement\.pdf \(1234 bytes\)/);
  assert.equal(await browser.title(), 'statement.pdf 1234', 'the page read the file');

  // By CSS selector too, and by an absolute path in the home folder.
  await writeFile(join(browser.home, 'docs', 'letter.txt'), 'Dear Maya');
  const again = await browser.upload({ field: '#doc', path: join(browser.home, 'docs', 'letter.txt') });
  assert.equal(again.isError, undefined, text(again));
  assert.equal(await browser.title(), 'letter.txt 9');
});

test('browser_upload refuses a path outside the home folder, a missing file, and a field that is not a file field, saying which', async t => {
  const browser = await uploadPage(t);
  const outside = await browser.upload({ field: 'Statement', path: '/etc/hostname' });
  assert.equal(outside.isError, true);
  assert.match(text(outside), /only a file in your home folder/i);
  const escaped = await browser.upload({ field: 'Statement', path: '../../etc/hostname' });
  assert.equal(escaped.isError, true);
  const missing = await browser.upload({ field: 'Statement', path: 'docs/nothing.pdf' });
  assert.equal(missing.isError, true);
  assert.match(text(missing), /docs\/nothing\.pdf could not be copied/);
  const wrong = await browser.upload({ field: '#note', path: 'docs/statement.pdf' });
  assert.equal(wrong.isError, true);
  assert.match(text(wrong), /not a file field/);
  const none = await browser.upload({ field: 'Passport', path: 'docs/statement.pdf' });
  assert.equal(none.isError, true);
  assert.match(text(none), /No file field labelled "Passport"/);
  assert.equal(await browser.title(), 'Upload', 'nothing was put in the field');
});

// The agent can write the shared folder, and so plant a link there to a file
// only the browser's user may read (its cookies, say). upload.mjs takes only a
// plain file that is really in the folder, and hands the page its own copy.
test('the browser\'s half of browser_upload refuses a link planted in the shared folder, and anything outside it', async t => {
  const browser = await uploadPage(t);
  const secret = join(browser.home, '..', 'browser-only-cookies');
  await writeFile(secret, 'session=maya');
  await mkdir(join(browser.shared, '.uploads', 'planted'), { recursive: true });
  await symlink(secret, join(browser.shared, '.uploads', 'planted', 'cookies.txt'));
  await symlink(join(browser.home, '..'), join(browser.shared, '.uploads', 'up'));
  const run = path => new Promise(resolve => execFile(process.execPath, [UPLOAD], { env: { PATH: '/usr/bin:/bin', HOME: browser.home,
    AGENT_CDP: browser.cdp, BROWSER_FILES: browser.shared, AGENT_UPLOAD: JSON.stringify({ field: 'Statement', path }) } },
  (error, stdout) => resolve({ code: error?.code ?? 0, reply: JSON.parse(stdout || 'null') })));

  for (const path of [join(browser.shared, '.uploads', 'planted', 'cookies.txt'), join(browser.shared, '.uploads', 'up', 'browser-only-cookies'), secret]) {
    const { reply } = await run(path);
    assert.equal(reply?.ok, false, `${path}: ${JSON.stringify(reply)}`);
    assert.match(reply.error, /not a file in the shared folder/);
  }
  assert.equal(await browser.title(), 'Upload', 'nothing was put in the field');
});

// #115: like the sign-in, card and answer fillers, browser_upload acts only on
// the tab visit_website opened (~/.visit-tab), never a tab of the person's own,
// even one in front of the screen with a file field on it.
async function personsUploadInFront(browser, person) {
  await browser.call(person, 'Page.navigate', { url: `https://person.example.com:${browser.port}/upload` });
  await pause(1000);
  await fetch(`${browser.cdp}/json/activate/${person.id}`);
  await pause(500);
  assert.equal(await browser.evaluate(person, 'document.visibilityState'), 'visible', 'the person\'s tab is in front');
  await mkdir(join(browser.home, 'docs'), { recursive: true });
  await writeFile(join(browser.home, 'docs', 'statement.pdf'), Buffer.alloc(1234, 7));
}

test('browser_upload refuses when no tab is visit_website\'s, and never puts the file into the person\'s tab in front', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  await personsUploadInFront(browser, person);
  const refused = await browserUpload.execute({ field: 'Statement', path: 'docs/statement.pdf' }, browser.api, ctx);
  assert.equal(refused.isError, true, text(refused));
  assert.match(text(refused), /visit_website/);
  assert.equal(await browser.evaluate(person, 'document.title'), 'Upload', 'no file was set in the person\'s tab');
});

test('browser_upload refuses when visit_website\'s tab has no file field, though the person\'s tab in front has one', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  await visitWebsite.execute({ url: `https://bank.example.com:${browser.port}/paint/ff0000` }, browser.api, ctx);
  await personsUploadInFront(browser, person);
  const refused = await browserUpload.execute({ field: 'Statement', path: 'docs/statement.pdf' }, browser.api, ctx);
  assert.equal(refused.isError, true, text(refused));
  assert.match(text(refused), /visit_website/);
  assert.equal(await browser.evaluate(person, 'document.title'), 'Upload', 'no file was set in the person\'s tab');
});

test('browser_upload puts the file into visit_website\'s tab, not the person\'s tab in front of it', async t => {
  const browser = await screen(t);
  const [person] = await browser.pages();
  await visitWebsite.execute({ url: `https://bank.example.com:${browser.port}/upload` }, browser.api, ctx);
  const visit = (await browser.pages()).find(each => each.id !== person.id);
  await personsUploadInFront(browser, person);
  const done = await browserUpload.execute({ field: 'Statement', path: 'docs/statement.pdf' }, browser.api, ctx);
  assert.equal(done.isError, undefined, text(done));
  assert.match(text(done), /bank\.example\.com/);
  assert.equal(await browser.evaluate(visit, 'document.title'), 'statement.pdf 1234', 'visit_website\'s tab has the file');
  assert.equal(await browser.evaluate(person, 'document.title'), 'Upload', 'the person\'s tab does not');
});
