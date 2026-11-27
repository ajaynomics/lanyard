// visit_website on an agent's Sprite: shows a page in the screen's Chromium
// over CDP (127.0.0.1:9222), so the agent's logins apply and the person sees
// the page. Prints one JSON line: {title, text, screenshot} (a base64 JPEG of
// the page). Exits 3 when the screen's browser cannot be reached, so the
// caller falls back to a headless browser; 1 for any other failure, among
// them a tab left on a page other than the one asked for.
//
//   node /opt/agent/visit.mjs <url>
//
// The page opens as a tab in the screen's window, brought to the front, so
// the person sees what the agent sees and ctrl+Tab reaches it; its id is kept
// in ~/.visit-tab, and answer.mjs, fill.mjs and pay.mjs act on that same tab.
// Chromium paints only the tab in front of a window, and a screenshot of any
// other never answers, so the visit's tab is in front when it is read.
//
// A visit navigates only a tab of its own that is on the site asked for (the
// same host, or one a subdomain of the other) or still blank; any other site
// gets a new tab. A site may hold its tab as a session ("another instance is
// open") and lock the person out when it is taken away (agent b10, 16 Nov).
// Its own tabs are those it opened, whose history starts with FIRST_PAGE, which
// survives a browser restart where ids do not, and the one ~/.visit-tab names.
// A tab the person or a site opened is never navigated or closed.
//
// A Sprite made before this kept the visit's tab in a window of its own,
// behind the person's, where neither the person nor ctrl+Tab reached it. A
// window holding only the visit's own tabs, other than the one in front, is
// closed, so no page is left in a hidden window.
//
// A tab of its own that no longer answers (its page crashed, or hangs) is
// closed and a new tab opened in its place. A renderer wedged after memory
// kills is still listed, and the browser still answers for it, while its
// page answers nothing; so the test is a script run in the page, within
// seconds.
//
// The caller has already checked the address is a public web page.
import { readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CDP = process.env.AGENT_CDP ?? 'http://127.0.0.1:9222';
const TAB_FILE = join(homedir(), '.visit-tab');
// A visit's tab's first page: no person or site opens it.
const FIRST_PAGE = 'about:blank#visit_website';
const MAX_TEXT = 6000;
const url = process.argv[2];
const fail = (code, message) => { process.stderr.write(`${message}\n`); process.exit(code); };
// Choosing the tab has a bound of its own, and the page its 40 seconds after
// that, so a browser with many tabs never spends the page's time. Both inside
// the caller's 55 seconds (browser.mjs), so a stuck page is reported as a
// failure rather than the call timing out.
const TAB_SECONDS = 10;
const PAGE_SECONDS = 40;
const choosing = setTimeout(() => fail(1, `The browser could not open ${url} (its tabs did not answer within ${TAB_SECONDS} s).`), TAB_SECONDS * 1000);
choosing.unref();

async function connect(address) {
  const socket = new WebSocket(address);
  const waiting = new Map(), listeners = new Set();
  let next = 0;
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.id && waiting.has(message.id)) {
      const { resolve, reject } = waiting.get(message.id);
      waiting.delete(message.id);
      message.error ? reject(new Error(message.error.message)) : resolve(message.result);
    } else if (message.method) for (const listener of listeners) listener(message.method, message.params ?? {});
  });
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', () => reject(new Error('no connection'))); });
  // A browser that exits mid-call closes its socket and never answers; its
  // calls fail at once, saying so, rather than reading as a hang (#575).
  let closed;
  socket.addEventListener('close', () => {
    closed = new Error('the browser closed its connection');
    for (const { reject } of waiting.values()) reject(closed);
    waiting.clear();
  });
  const send = (method, params = {}, ms) => new Promise((resolve, reject) => {
    if (closed) return reject(closed);
    const id = ++next;
    waiting.set(id, { resolve, reject });
    if (ms) setTimeout(() => { waiting.delete(id); reject(new Error(`${method} took too long`)); }, ms).unref();
    socket.send(JSON.stringify({ id, method, params }));
  });
  const listen = listener => listeners.add(listener);
  return { send, listen, close: () => socket.close() };
}

const pages = async () => {
  const listed = await fetch(`${CDP}/json/list`, { signal: AbortSignal.timeout(5000) });
  if (!listed.ok) throw new Error(`status ${listed.status}`);
  return (await listed.json()).filter(open => open.type === 'page' && open.webSocketDebuggerUrl);
};
const close = id => fetch(`${CDP}/json/close/${id}`, { signal: AbortSignal.timeout(5000) }).catch(() => {});
const left = by => Math.max(1, by - Date.now());
const windowOf = async (id, by) => (await browser.send('Browser.getWindowForTarget', { targetId: id }, left(by)).catch(() => null))?.windowId;

// One call on a tab's own socket; undefined when it has not answered by `by`,
// the deadline every tab is asked to. A background tab seldom answers a
// script in time: asked one by one, 34 tabs took 40 seconds.
function ask(tab, method, params, by) {
  const asking = connect(tab.webSocketDebuggerUrl)
    .then(each => each.send(method, params).finally(() => each.close()))
    .catch(() => undefined);
  return Promise.race([asking, new Promise(resolve => setTimeout(resolve, left(by)).unref())]);
}

// The page in front of the screen: the visible one with the keyboard's focus,
// else the first visible one, in the browser's order (on a Sprite since #60,
// that order is not the last used first: agent/guest/cdp.mjs). None when
// there is no page.
async function inFront(open, by) {
  const seen = await Promise.all(open.map(tab =>
    ask(tab, 'Runtime.evaluate', { expression: '[document.visibilityState, document.hasFocus()]', returnByValue: true }, by)));
  const states = seen.map(answer => answer?.result?.value ?? []);
  return open.find((_, i) => states[i][0] === 'visible' && states[i][1]) ?? open.find((_, i) => states[i][0] === 'visible') ?? null;
}

// The tabs the visit opened: its first page is in their history, or
// ~/.visit-tab names them.
async function ownOf(open, by) {
  const remembered = (await readFile(TAB_FILE, 'utf8').catch(() => '')).trim();
  const histories = await Promise.all(open.map(tab => tab.id === remembered ? null : ask(tab, 'Page.getNavigationHistory', {}, by)));
  const own = open.filter((tab, i) => tab.id === remembered || histories[i]?.entries?.[0]?.url === FIRST_PAGE);
  // The one it used last first.
  return own.sort((a, b) => (b.id === remembered) - (a.id === remembered));
}

// The same site: the same host, or one a subdomain of the other, www. included.
const parse = address => { try { const parsed = new URL(address); return /^https?:$/.test(parsed.protocol) ? parsed : null; } catch { return null; } };
const site = parsed => parsed.hostname.toLowerCase().replace(/\.$/, '').replace(/^www\./, '');
function sameSite(one, other) {
  const [a, b] = [parse(one), parse(other)];
  if (!a || !b) return false;
  const [x, y] = [site(a), site(b)];
  return x === y || x.endsWith(`.${y}`) || y.endsWith(`.${x}`);
}
const blank = tab => tab.url === FIRST_PAGE || tab.url === 'about:blank';

// A new tab in the screen's window: Chromium puts it in the window last in
// front, and brings it forward.
async function newTab() {
  const { targetId } = await browser.send('Target.createTarget', { url: FIRST_PAGE }, 5000);
  const made = (await pages()).find(open => open.id === targetId);
  if (!made) throw new Error('the new tab is not listed');
  return made;
}

// The tab for the visit: one of its own on the site asked for, or blank;
// else a new one. The screen's window is the person's: the one in front if
// it holds a tab the visit did not open, else the first that does. Windows
// holding only the visit's own tabs are closed first, so a new tab cannot
// land in one; with no window of the person's, the one in front stays.
// Every tab is asked at once, all by one deadline, so the choosing does not
// grow with the number of tabs.
async function choose() {
  const open = await pages();
  const by = Date.now() + 3000;
  const [own, placed, front] = await Promise.all([ownOf(open, by), Promise.all(open.map(tab => windowOf(tab.id, by))), inFront(open, by)]);
  const windows = new Map();
  open.forEach((tab, i) => windows.set(placed[i], [...windows.get(placed[i]) ?? [], tab]));
  const inFrontWindow = front ? placed[open.indexOf(front)] : undefined;
  const persons = [...windows].filter(([, tabs]) => tabs.some(tab => !own.includes(tab))).map(([id]) => id);
  const screen = persons.includes(inFrontWindow) ? inFrontWindow : persons[0] ?? inFrontWindow;
  const hidden = new Set();
  if (screen !== undefined) for (const [id, tabs] of windows) {
    if (id !== screen && tabs.every(tab => own.includes(tab))) for (const tab of tabs) hidden.add(tab.id);
  }
  await Promise.all([...hidden].map(close));
  return own.find(tab => !hidden.has(tab.id) && (sameSite(url, tab.url) || blank(tab))) ?? await newTab();
}

// Only a browser that cannot be reached exits 3, for the headless fallback.
// One that answers but is slow or short of memory is there on the screen:
// a headless page would be reported as visited while the screen kept the
// page before it (#73).
let browser, tab;
try {
  const version = await fetch(`${CDP}/json/version`, { signal: AbortSignal.timeout(5000) });
  if (!version.ok) throw new Error(`status ${version.status}`);
  browser = await connect((await version.json()).webSocketDebuggerUrl);
} catch (error) {
  fail(3, `The screen's browser is not running (${error.message}).`);
}
try {
  tab = await choose();
} catch (error) {
  fail(1, `The browser could not open ${url} (no tab for it: ${error.message}).`);
}
clearTimeout(choosing);
setTimeout(() => fail(1, `The browser could not open ${url} (it took too long).`), PAGE_SECONDS * 1000).unref();

// The tab shows the page asked for when it is on that address (its trailing
// slash, default port and fragment aside), on the same site, or on a page
// this navigation committed, which is where a redirect to another site lands.
// Anything else is a page from before the visit, never reported as visited.
const address = parsed => `${parsed.host}${parsed.pathname.replace(/\/+$/, '')}${parsed.search}`;
function arrived(asked, showing, committed) {
  const have = parse(showing);
  if (!parse(asked) || !have) return false;
  if (sameSite(asked, showing)) return true;
  return committed.some(each => { const landed = parse(each); return landed && address(landed) === address(have); });
}

let page;
// The harness that reads this output cuts it off at about 64 KB, and the line
// must stay whole JSON, so the picture shrinks until it fits beside the text.
// A full-size tab at 1280 pixels can take 60 KB at the first try.
const SHOT_LIMIT = 40_000;
const SHOT_TRIES = [ { quality: 80, scale: 1 }, { quality: 60, scale: 0.75 }, { quality: 45, scale: 0.6 }, { quality: 35, scale: 0.45 }, { quality: 30, scale: 0.3 } ];
async function smallEnoughScreenshot() {
  const { cssVisualViewport: view } = await page.send('Page.getLayoutMetrics').catch(() => ({}));
  let data = '';
  for (const { quality, scale } of SHOT_TRIES) {
    const clip = view ? { x: 0, y: 0, width: view.clientWidth, height: view.clientHeight, scale } : undefined;
    ({ data } = await page.send('Page.captureScreenshot', { format: 'jpeg', quality, ...(clip ? { clip } : {}) }));
    if (data.length <= SHOT_LIMIT) return data;
  }
  return data.length <= SHOT_LIMIT ? data : '';
}

// A crashed page's tab never answers; nor does one stuck in a script or a dialog.
const answers = async page => await page.send('Page.enable', {}, 5000).then(() => true, () => false) &&
  await page.send('Runtime.evaluate', { expression: '1', returnByValue: true }, 3000).then(() => true, () => false);

try {
  page = await connect(tab.webSocketDebuggerUrl);
  if (!await answers(page)) {
    page.close();
    await close(tab.id);
    tab = await newTab();
    page = await connect(tab.webSocketDebuggerUrl);
    if (!await answers(page)) throw new Error('its new tab does not answer either');
  }
  await writeFile(TAB_FILE, tab.id).catch(() => {});
  // In front, so the person sees it and its page is painted.
  await browser.send('Target.activateTarget', { targetId: tab.id }, 5000);
  // The pages the tab's main frame commits from here on, redirects already
  // followed, and the load of the first of them. A load event the earlier
  // page fires late is not this one.
  const committed = [];
  let commit, load;
  const commitment = new Promise(resolve => { commit = resolve; }), loading = new Promise(resolve => { load = resolve; });
  page.listen((method, params) => {
    if (method === 'Page.frameNavigated' && !params.frame?.parentId) { committed.push(params.frame?.url); commit(); }
    else if (method === 'Page.loadEventFired' && committed.length) load();
  });
  const within = (promise, ms) => Promise.race([promise, new Promise(resolve => setTimeout(resolve, ms))]);
  // Chromium answers once the navigation commits, or with errorText when it
  // fails. A move within the page (a fragment) has no loaderId and commits
  // no page.
  const navigated = await page.send('Page.navigate', { url });
  if (navigated.errorText) fail(1, `The browser could not open ${url} (${navigated.errorText}).`);
  if (navigated.loaderId) {
    await within(commitment, 5000);
    if (committed.length) await within(loading, 30000);
  }
  // Let scripts draw the page.
  await new Promise(resolve => setTimeout(resolve, 1000));
  const read = await page.send('Runtime.evaluate', { returnByValue: true,
    expression: 'JSON.stringify({ url: location.href, title: document.title, text: document.body ? document.body.innerText : "" })' });
  const { url: showing, title, text } = JSON.parse(read.result.value);
  if (!arrived(url, showing, committed)) fail(1, `The browser could not open ${url} (the tab is on ${showing} instead).`);
  const screenshot = await smallEnoughScreenshot();
  const trimmed = text.replace(/[ \t]+/g, ' ').replace(/\n\s*\n\s*/g, '\n\n').trim();
  process.stdout.write(JSON.stringify({ title, text: trimmed.length > MAX_TEXT ? `${trimmed.slice(0, MAX_TEXT)}…` : trimmed, screenshot }) + '\n');
  page.close();
  browser.close();
  process.exit(0);
} catch (error) {
  fail(1, `The browser could not open ${url} (${error.message}).`);
}
