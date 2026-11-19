// browser_upload's half on an agent's Sprite (agent/browser-upload.mjs), run
// as `browser`: puts a file the agent copied into the shared folder
// (/home/agent/browser-files) into a file field of the tab visit_website last
// opened (the tab named in ~/.visit-tab), over CDP (DOM.setFileInputFiles), the
// trusted side; the agent never reaches the browser's DevTools (#60). Never a
// tab of the person's own, even one in front (#115): fill.mjs, pay.mjs and
// answer.mjs act on the same tab.
//
//   AGENT_UPLOAD='{"field": <CSS selector or label text>, "path": <file in the shared folder>}' node /opt/agent/upload.mjs
//
// Prints one JSON line, {ok: true, name, size, url} or {ok: false, error}.
// Exits 3 when the screen's browser is not there.
//
// The agent may write the shared folder, and so plant a link there to a file
// only this user may read (the browser's cookies, say), or swap the file after
// it is checked. So only a plain file that is really in the folder is taken
// (opened without following a link, its real path read back from the open
// file, one name only), and the page is given a copy in this user's own
// folder, which the agent can neither read nor change.
import { constants, createReadStream, createWriteStream, fstatSync, openSync, readlinkSync, realpathSync } from 'node:fs';
import { mkdir, readFile, readdir, rm, stat } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import { homedir } from 'node:os';
import { basename, join } from 'node:path';
import { randomUUID } from 'node:crypto';

const CDP = process.env.AGENT_CDP ?? 'http://127.0.0.1:9222';
// Named only for the tests: the spawner on a Sprite passes no such variable.
const SHARED = process.env.BROWSER_FILES ?? '/home/agent/browser-files';
const OWN = join(homedir(), 'uploads');
const TAB_FILE = join(homedir(), '.visit-tab');
const MAX_BYTES = 100 * 1024 * 1024;
const DAY = 24 * 60 * 60 * 1000;
const answer = (reply, code = 0) => { process.stdout.write(`${JSON.stringify(reply)}\n`); process.exit(code); };
const refuse = error => answer({ ok: false, error });

let asked;
try { asked = JSON.parse(process.env.AGENT_UPLOAD ?? ''); } catch {}
if (typeof asked?.field !== 'string' || !asked.field.trim() || typeof asked?.path !== 'string') refuse('No field or file was given.');

// The file, as this user's own copy.
async function own(path) {
  const notShared = 'That is not a file in the shared folder.';
  let fd;
  try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW); } catch { refuse(notShared); }
  const info = fstatSync(fd);
  const real = readlinkSync(`/proc/self/fd/${fd}`);
  if (!info.isFile() || info.nlink !== 1 || !real.startsWith(`${realpathSync(SHARED)}/`)) refuse(notShared);
  if (info.size > MAX_BYTES) refuse(`The file is ${info.size} bytes; the most is ${MAX_BYTES}.`);
  // Earlier copies, a day after they were made: a page reads its file when its form is sent.
  for (const old of await readdir(OWN).catch(() => [])) {
    if (Date.now() - (await stat(join(OWN, old)).catch(() => ({ mtimeMs: Date.now() }))).mtimeMs > DAY) await rm(join(OWN, old), { recursive: true, force: true });
  }
  const dir = join(OWN, randomUUID());
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const copy = join(dir, basename(real));
  await pipeline(createReadStream(null, { fd }), createWriteStream(copy, { mode: 0o600 }));
  return { copy, name: basename(real), size: info.size };
}

async function connect(address) {
  const socket = new WebSocket(address);
  const waiting = new Map();
  let next = 0;
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    const waiter = waiting.get(message.id);
    if (!waiter) return;
    waiting.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  });
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', () => reject(new Error('no connection'))); });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { waiting.delete(id); reject(new Error(`${method} took too long`)); }, 5000);
    waiting.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
    socket.send(JSON.stringify({ id, method, params }));
  });
  return { send, close: () => socket.close() };
}

// Runs in the page: the field a CSS selector names (a label it names stands
// for its field), else the file field whose label, aria-label or title reads
// as the text, wholly or else in part. A string when there is none.
function field(wanted) {
  const words = text => String(text ?? '').replace(/\s+/g, ' ').trim().toLowerCase();
  let named = null;
  try { named = document.querySelector(wanted); } catch {}
  if (named instanceof HTMLLabelElement) named = named.control;
  if (named) return named instanceof HTMLInputElement && named.type === 'file' ? named : `${JSON.stringify(wanted)} is not a file field.`;
  const fields = [...document.querySelectorAll('input[type=file]')];
  const said = input => [...(input.labels ?? [])].map(label => label.textContent).concat(input.getAttribute('aria-label'), input.title).map(words).filter(Boolean);
  const want = words(wanted);
  const found = fields.filter(input => said(input).includes(want));
  const partly = found.length ? found : fields.filter(input => said(input).some(text => text.includes(want)));
  if (partly.length === 1) return partly[0];
  if (partly.length > 1) return `${partly.length} file fields are labelled ${JSON.stringify(wanted)}; name one with a CSS selector.`;
  return `No file field labelled ${JSON.stringify(wanted)} on this page${fields.length ? '' : ', which has no file field'}.`;
}

let tab;
try {
  const id = (await readFile(TAB_FILE, 'utf8').catch(() => '')).trim();
  const listed = await fetch(`${CDP}/json/list`, { signal: AbortSignal.timeout(5000) });
  if (!listed.ok) throw new Error(`status ${listed.status}`);
  tab = (await listed.json()).find(open => open.id === id && open.type === 'page' && open.webSocketDebuggerUrl);
} catch (error) {
  process.stderr.write(`The screen's browser is not running (${error.message}).\n`);
  process.exit(3);
}
if (!tab) refuse('Open the page with the file field with visit_website first: a file goes only into the tab visit_website opened, never one of the person\'s own.');
const file = await own(asked.path);
const onVisitTab = `in the tab visit_website last opened, ${JSON.stringify(String(tab.title ?? '').slice(0, 100))}`;
let page;
try {
  page = await connect(tab.webSocketDebuggerUrl);
  const found = await page.send('Runtime.evaluate', { expression: `(${field})(${JSON.stringify(asked.field)})` });
  if (found.result?.type === 'string') refuse(`${found.result.value} (${onVisitTab}.)`);
  if (!found.result?.objectId) refuse(`No file field ${JSON.stringify(asked.field)} ${onVisitTab}.`);
  await page.send('DOM.setFileInputFiles', { files: [file.copy], objectId: found.result.objectId });
  const { result } = await page.send('Runtime.evaluate', { expression: 'location.origin + location.pathname', returnByValue: true });
  page.close();
  answer({ ok: true, name: file.name, size: file.size, url: result.value });
} catch (error) {
  refuse(`The file could not be put in the field (${error.message}).`);
}
