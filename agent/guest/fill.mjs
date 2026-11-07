// A saved sign-in on an agent's Sprite (agent/sign-in.mjs): fills the page
// visit_website last opened (the tab named in ~/.visit-tab) with a username
// and password, over CDP (127.0.0.1:9222), only if that page is on the
// sign-in's own site or under it. Never submits: the agent presses the button.
//
//   AGENT_SIGN_IN='{"host":…,"username":…,"password":…}' node /opt/agent/fill.mjs
//
// Prints one JSON line, {ok: true, filled: [...], url} or {ok: false, error},
// that never holds the username or password. Exits 3 when the screen's
// browser is not there.
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CDP = process.env.AGENT_CDP ?? 'http://127.0.0.1:9222';
const TAB_FILE = join(homedir(), '.visit-tab');
const answer = (reply, code = 0) => { process.stdout.write(`${JSON.stringify(reply)}\n`); process.exit(code); };

let signIn;
try { signIn = JSON.parse(process.env.AGENT_SIGN_IN ?? ''); } catch { answer({ ok: false, error: 'No sign-in was given.' }, 1); }
delete process.env.AGENT_SIGN_IN;
const host = String(signIn?.host ?? '').toLowerCase().replace(/\.$/, '');
if (!host || typeof signIn.password !== 'string') answer({ ok: false, error: 'No sign-in was given.' }, 1);

// The page's host is the sign-in's, or a name under it (accounts.example.com
// for example.com); never a look-alike or a parent. Asked of the tab before
// filling, and again inside the page, which may have moved since.
function sameSite(url, siteHost) {
  const page = url.hostname.toLowerCase().replace(/\.$/, '');
  return url.protocol === 'https:' && (page === siteHost || page.endsWith(`.${siteHost}`));
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
if (!tab) answer({ ok: false, error: 'Open the sign-in page with visit_website first.' });
let page;
try { page = new URL(tab.url); } catch { page = new URL('about:blank'); }
if (!sameSite(page, host)) answer({ ok: false, error: `The page is not on ${host} over https, so nothing was filled.` });

// Runs in the page: the visible password field, and the visible text or email
// field before it as the username. A value set as a person's typing would be
// (the native setter, then input and change events), so the page's own
// scripts see it.
function fill(sameSite, host, username, password) {
  if (!sameSite(location, host)) return null;
  const visible = field => !field.disabled && !field.readOnly && field.getClientRects().length > 0;
  const fields = [...document.querySelectorAll('input')].filter(visible);
  const passwordField = fields.find(field => field.type === 'password');
  const before = passwordField ? fields.slice(0, fields.indexOf(passwordField)) : fields;
  const usernameField = before.reverse().find(field => field.autocomplete === 'username' || ['email', 'text', 'tel'].includes(field.type));
  const set = (field, value) => {
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, value);
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
  };
  const filled = [];
  if (usernameField && username) { set(usernameField, username); filled.push('username'); }
  if (passwordField) { set(passwordField, password); filled.push('password'); }
  return filled;
}

const socket = new WebSocket(tab.webSocketDebuggerUrl);
try {
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', reject); });
  const reply = await new Promise((resolve, reject) => {
    socket.addEventListener('message', event => {
      const message = JSON.parse(event.data);
      if (message.id === 1) message.error ? reject(new Error('the page refused')) : resolve(message.result);
    });
    socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { returnByValue: true,
      expression: `(${fill})(${sameSite}, ${JSON.stringify(host)}, ${JSON.stringify(signIn.username ?? '')}, ${JSON.stringify(signIn.password)})` } }));
  });
  socket.close();
  const filled = reply?.result?.value;
  if (!Array.isArray(filled)) answer({ ok: false, error: 'The page changed while filling, so nothing was filled.' });
  if (filled.length === 0) answer({ ok: false, error: 'There is no sign-in field on the page.' });
  answer({ ok: true, filled, url: `${page.origin}${page.pathname}` });
} catch (error) {
  answer({ ok: false, error: `The page could not be filled (${error.message}).` });
}
