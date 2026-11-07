// visit_website on an agent's Sprite: shows a page in the screen's Chromium
// over CDP (127.0.0.1:9222), so the agent's logins apply and the person sees
// the page. Prints one JSON line: {title, text, screenshot} (a base64 JPEG of
// the page). Exits 3 when the screen's browser is not there, so the caller
// falls back to a headless browser; 1 for any other failure.
//
//   node /opt/avery/visit.mjs <url>
//
// One tab, reused: its id is kept in ~/.visit-tab. The page stays showing
// after the call. Tabs the person opened are never navigated or closed.
//
// The caller has already checked the address is a public web page.
import { readFile, writeFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CDP = process.env.AVERY_CDP ?? 'http://127.0.0.1:9222';
const TAB_FILE = join(homedir(), '.visit-tab');
const MAX_TEXT = 6000;
const url = process.argv[2];
const fail = (code, message) => { process.stderr.write(`${message}\n`); process.exit(code); };

let tab;
try {
  const listed = await fetch(`${CDP}/json/list`, { signal: AbortSignal.timeout(5000) });
  if (!listed.ok) throw new Error(`status ${listed.status}`);
  const id = (await readFile(TAB_FILE, 'utf8').catch(() => '')).trim();
  tab = (await listed.json()).find(open => open.id === id && open.type === 'page' && open.webSocketDebuggerUrl);
  if (!tab) {
    const opened = await fetch(`${CDP}/json/new?about:blank`, { method: 'PUT', signal: AbortSignal.timeout(5000) });
    if (!opened.ok) throw new Error(`status ${opened.status}`);
    tab = await opened.json();
    // Without the file the next call opens another tab; still better than failing.
    await writeFile(TAB_FILE, tab.id).catch(() => {});
  }
} catch (error) {
  fail(3, `The screen's browser is not running (${error.message}).`);
}

const socket = new WebSocket(tab.webSocketDebuggerUrl);
let next = 0;
const waiting = new Map(), listeners = new Map();
socket.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  if (message.id && waiting.has(message.id)) {
    const { resolve, reject } = waiting.get(message.id);
    waiting.delete(message.id);
    message.error ? reject(new Error(message.error.message)) : resolve(message.result);
  } else if (message.method) listeners.get(message.method)?.();
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = ++next;
  waiting.set(id, { resolve, reject });
  socket.send(JSON.stringify({ id, method, params }));
});
const once = (method, ms) => new Promise(resolve => {
  const timer = setTimeout(resolve, ms);
  listeners.set(method, () => { clearTimeout(timer); resolve(); });
});

// The harness that reads this output cuts it off at about 64 KB, and the line
// must stay whole JSON, so the picture shrinks until it fits beside the text.
// A full-size tab at 1280 pixels can take 60 KB at the first try.
const SHOT_LIMIT = 40_000;
const SHOT_TRIES = [ { quality: 80, scale: 1 }, { quality: 60, scale: 0.75 }, { quality: 45, scale: 0.6 }, { quality: 35, scale: 0.45 }, { quality: 30, scale: 0.3 } ];
async function smallEnoughScreenshot() {
  const { cssVisualViewport: view } = await send('Page.getLayoutMetrics').catch(() => ({}));
  let data = '';
  for (const { quality, scale } of SHOT_TRIES) {
    const clip = view ? { x: 0, y: 0, width: view.clientWidth, height: view.clientHeight, scale } : undefined;
    ({ data } = await send('Page.captureScreenshot', { format: 'jpeg', quality, ...(clip ? { clip } : {}) }));
    if (data.length <= SHOT_LIMIT) return data;
  }
  return data.length <= SHOT_LIMIT ? data : '';
}

try {
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', reject); });
  await send('Page.enable');
  const loaded = once('Page.loadEventFired', 30000);
  const navigated = await send('Page.navigate', { url });
  if (navigated.errorText) fail(1, `The browser could not open ${url} (${navigated.errorText}).`);
  await loaded;
  // Let scripts draw the page.
  await new Promise(resolve => setTimeout(resolve, 1000));
  const read = await send('Runtime.evaluate', { returnByValue: true,
    expression: 'JSON.stringify({ title: document.title, text: document.body ? document.body.innerText : "" })' });
  const { title, text } = JSON.parse(read.result.value);
  const screenshot = await smallEnoughScreenshot();
  await fetch(`${CDP}/json/activate/${tab.id}`).catch(() => {});
  const trimmed = text.replace(/[ \t]+/g, ' ').replace(/\n\s*\n\s*/g, '\n\n').trim();
  process.stdout.write(JSON.stringify({ title, text: trimmed.length > MAX_TEXT ? `${trimmed.slice(0, MAX_TEXT)}…` : trimmed, screenshot }) + '\n');
  socket.close();
  process.exit(0);
} catch (error) {
  fail(1, `The browser could not open ${url} (${error.message}).`);
}
