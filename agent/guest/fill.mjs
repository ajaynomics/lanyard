// A saved sign-in on an agent's Sprite (agent/sign-in.mjs): fills the tab
// visit_website last opened (the tab named in ~/.visit-tab, which it brought
// to the front of the screen's window) with a username and password, over
// CDP (127.0.0.1:9222), in the page or in one of its frames, a frame from
// another site included, but only one whose own address is on the sign-in's
// site or under it, and the
// sign-in's account number too when the page has a box for it. Or, given
// `boxes`, the password into just the password boxes the agent named by CSS
// selector (a new password and its confirmation, say), and nothing else. Never submits:
// the agent presses the button. Never a tab of the person's own, even one in
// front: answer.mjs and pay.mjs act on the same tab.
//
//   AGENT_SIGN_IN='{"host":…,"username":…,"password":…,"account":…}' node /opt/agent/fill.mjs
//   AGENT_SIGN_IN='{"host":…,"boxes":{"selectors":[…],"password":…}}' node /opt/agent/fill.mjs
//
// Prints one JSON line, {ok: true, filled: [...], url, accountUnused?} or
// {ok: false, error}, that never holds the username, password or account. Exits 3 when the screen's
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
// Named boxes carry the password under `boxes`, not `password`, so a fill.mjs
// from before them finds no password and fills nothing, rather than typing the
// username into whatever text box precedes the first password box.
const boxes = signIn?.boxes;
const named = Array.isArray(boxes?.selectors) && boxes.selectors.length > 0 && boxes.selectors.every(each => typeof each === 'string' && each) &&
  typeof boxes.password === 'string' && Boolean(boxes.password);
if (!host || !(named || typeof signIn.password === 'string')) answer({ ok: false, error: 'No sign-in was given.' }, 1);

// The address's host is the sign-in's, or a name under it (accounts.example.com
// for example.com); never a look-alike or a parent.
function sameSite(url, siteHost) {
  const page = url.hostname.toLowerCase().replace(/\.$/, '');
  return url.protocol === 'https:' && (page === siteHost || page.endsWith(`.${siteHost}`));
}

// One DevTools connection. Frames from another site run in their own process,
// reached as their own target (Target.setAutoAttach, flattened into this
// connection).
async function connect(url) {
  const socket = new WebSocket(url);
  const waiting = new Map(), attached = [];
  let next = 0;
  const send = (method, params = {}, sessionId, ms = 5000) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { waiting.delete(id); reject(new Error(`${method} took too long`)); }, ms);
    waiting.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
    socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Target.attachedToTarget' && message.params.targetInfo?.type === 'iframe') {
      attached.push(message.params.sessionId);
      send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, message.params.sessionId).catch(() => {});
    }
    const waiter = waiting.get(message.id);
    if (!waiter) return;
    waiting.delete(message.id);
    message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
  });
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', () => reject(new Error('no connection'))); });
  return { send, attached, close: () => socket.close() };
}

let tab;
try {
  const id = (process.env.AGENT_TAB ?? await readFile(TAB_FILE, 'utf8').catch(() => '')).trim();
  const listed = await fetch(`${CDP}/json/list`, { signal: AbortSignal.timeout(5000) });
  if (!listed.ok) throw new Error(`status ${listed.status}`);
  tab = (await listed.json()).find(open => open.id === id && open.type === 'page' && open.webSocketDebuggerUrl);
} catch (error) {
  process.stderr.write(`The screen's browser is not running (${error.message}).\n`);
  process.exit(3);
}
// A sandboxed agent's own browser has no visit_website; its tab is the one used last.
const own = process.env.AGENT_TAB !== undefined, TAB = own ? 'The tab your browser used last' : 'The tab visit_website last opened';
if (!tab) answer({ ok: false, error: own ? 'Your browser has no tab open.' : 'Open the sign-in page with visit_website first.' });
const hostOf = tab => { try { const url = new URL(tab.url); return url.hostname ? `${url.protocol}//${url.hostname}` : tab.url || 'no page'; } catch { return tab.url || 'no page'; } };

// Runs in one frame, in an isolated world of its own, and asks only this
// frame's own address: a frame on the sign-in's site fills inside another
// site's page (Apple's idmsa.apple.com in www.icloud.com), and a page on the
// site never fills another site's frame. Without `values` it only says what it
// would fill (the username only when the sign-in has one), and whether the
// page asks for an account the sign-in lacks.
//
// A field counts only if a person can see and reach it: not disabled, read
// only, hidden, under aria-hidden or inert, nor smaller than 2 pixels, clipped
// away or off the page's top or left. A select's visually hidden input
// (1 pixel, clipped) has client rects, so having them is not enough.
//
// The username is, with a password field, the field before it marked as one
// (autocomplete, type, or a name, id or label saying user, login or email),
// else the nearest text field before it. Without a password field (a
// username-first step, as Google's and Apple's) only a field marked as one;
// any other text box is not a username.
//
// The account box is, with a password field, a text field before it on its
// form, other than the username's, whose name, id, label, placeholder or
// autocomplete says account, firm, company or organisation, or a customer,
// client or member number (Account Number, User ID and Password, as a bank's).
// A page with one is filled only with the sign-in's account: without it,
// nothing is filled. A field marked for the username is never the account's,
// and a field saying account is the username only when no other text field
// before the password could be.
//
// A value is set as a person's typing would be (focus, the native setter,
// then input and change events), so the page's own scripts see it. The focus
// stays on the last box filled, the password: the host's act helper reads and
// types nothing while a password box has it, and its submit sends that form.
function fill(sameSite, reachable, set, host, withUsername, withAccount, values) {
  if (!sameSite(location, host)) return null;
  const fields = [...document.querySelectorAll('input')].filter(reachable);
  const passwordField = fields.find(field => field.type === 'password');
  const typed = field => ['email', 'text', 'tel'].includes(field.type);
  const labelled = field => [field.name, field.id, field.getAttribute('aria-label'), ...[...(field.labels ?? [])].map(label => label.textContent)].join(' ');
  const marked = field => typed(field) && (field.type === 'email' ||
    String(field.getAttribute('autocomplete') ?? '').toLowerCase().split(/\s+/).some(token => token === 'username' || token === 'email') ||
    /user|login|e-?mail/i.test(labelled(field)));
  // accountNumber, account_no and "Account Number" read alike.
  const words = field => [labelled(field), field.placeholder, field.getAttribute('autocomplete')].join(' ')
    .replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[_\-.]+/g, ' ');
  const accountish = field => typed(field) && !marked(field) &&
    /\b(account|acct|firm|company|organi[sz]ation)\b|\b(customer|client|member)\s*(number|no|num|id|#)/i.test(words(field));
  const before = passwordField ? fields.slice(0, fields.indexOf(passwordField)) : [];
  const usernameField = passwordField ? before.findLast(marked) ?? before.findLast(field => typed(field) && !accountish(field)) ?? before.findLast(typed)
    : fields.find(marked);
  const accountField = passwordField && before.find(field => field !== usernameField && field.form === passwordField.form && accountish(field));
  const url = `${location.origin}${location.pathname}`;
  if (accountField && !withAccount) return { filled: [], accountMissing: true, url };
  const filled = [];
  if (accountField) { if (values) set(accountField, values.account); filled.push('account'); }
  if (usernameField && withUsername) { if (values) set(usernameField, values.username); filled.push('username'); }
  if (passwordField) { if (values) set(passwordField, values.password); filled.push('password'); }
  return { filled, url, ...(withAccount && passwordField && !accountField ? { accountUnused: true } : {}) };
}

function reachable(field) {
  if (field.disabled || field.readOnly || field.type === 'hidden' || field.closest('[aria-hidden="true"], [inert]')) return false;
  if (field.checkVisibility && !field.checkVisibility({ visibilityProperty: true })) return false;
  const box = field.getBoundingClientRect(), style = getComputedStyle(field);
  if (box.width < 2 || box.height < 2 || box.right + scrollX <= 0 || box.bottom + scrollY <= 0) return false;
  return !/^rect\(0px,? 0px,? 0px,? 0px\)$/.test(style.clip) && style.clipPath !== 'inset(50%)';
}

function set(field, value) {
  field.focus();
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, value);
  field.dispatchEvent(new Event('input', { bubbles: true }));
  field.dispatchEvent(new Event('change', { bubbles: true }));
}

// The boxes the agent named, in one frame on the sign-in's site, as fill()
// is. Each must be a password box a person can see and reach: a text box would
// show the password on the screen, which the model sees. One that is not, or
// is missing, fills none of them. Without `password` it only says so.
function fillBoxes(sameSite, reachable, set, host, selectors, password) {
  if (!sameSite(location, host)) return null;
  const found = [];
  for (const selector of selectors) {
    let box = null;
    try { box = document.querySelector(selector); } catch {}
    if (!box) return { missing: selector };
    if (box.tagName !== 'INPUT' || box.type !== 'password' || !reachable(box)) return { notPassword: selector };
    found.push(box);
  }
  if (password !== null) for (const box of found) set(box, password);
  return { filled: selectors.map(selector => `password box ${selector}`), url: `${location.origin}${location.pathname}` };
}

const ACCOUNT_MISSING = 'Nothing was filled: the page also asks for an account number (or a customer or member number), and the saved sign-in has none. ' +
  'Ask the person for it, and to add it to the sign-in in the password manager as a line "Account: ..." in its description.';
// An "Account:" line with a space in it, or long, is a note someone wrote
// beside the number, not the number: typing it would fill a site's account
// box with a sentence. Nothing is typed, and the agent asks for the line to
// be fixed. The value itself is never repeated.
const ACCOUNT_LONGEST = 40;
const ACCOUNT_ODD = 'Nothing was filled: the saved sign-in\'s "Account:" line does not look like an account number ' +
  `(it has a space in it, or is longer than ${ACCOUNT_LONGEST} characters), so it was not typed into the page's account box. ` +
  'Ask the person to keep only the number on that line in the password manager, with any note on a line of its own.';
const framesOf = tree => [tree.frame.id, ...(tree.childFrames ?? []).flatMap(framesOf)];
const withUsername = Boolean(signIn.username);
const withAccount = typeof signIn.account === 'string' && Boolean(signIn.account);
const evaluate = (world, expression) => page.send('Runtime.evaluate', { contextId: world.contextId, returnByValue: true, expression }, world.sessionId)
  .then(reply => reply?.result?.value ?? null, () => null);
const run = (world, values) => evaluate(world,
  `(${fill})(${sameSite}, ${reachable}, ${set}, ${JSON.stringify(host)}, ${withUsername}, ${withAccount}, ${values ? JSON.stringify(values) : 'null'})`);
const runBoxes = (world, password) => evaluate(world,
  `(${fillBoxes})(${sameSite}, ${reachable}, ${set}, ${JSON.stringify(host)}, ${JSON.stringify(boxes.selectors)}, ${password === null ? 'null' : JSON.stringify(password)})`);
const NOT_A_BOX = selector => `${selector} is not a password box a person can see, so nothing was filled. ` +
  'Only a password box is filled, so the password never shows on the screen.';

async function fillNamedBoxes(worlds) {
  const found = [];
  for (const world of worlds) {
    const would = await runBoxes(world, null);
    if (would) found.push({ world, would });
  }
  if (found.length === 0) answer({ ok: false, error: notOnSite() });
  const chosen = found.find(each => each.would.filled);
  if (!chosen) {
    const wrong = found.find(each => each.would.notPassword);
    answer({ ok: false, error: wrong ? NOT_A_BOX(wrong.would.notPassword) : `Nothing on the page matches ${found[0].would.missing}, so nothing was filled.` });
  }
  const done = await runBoxes(chosen.world, boxes.password);
  signIn = undefined;
  page.close();
  if (!done?.filled) answer({ ok: false, error: 'The page changed while filling, so nothing was filled.' });
  answer({ ok: true, filled: done.filled, url: done.url });
}
const notOnSite = () => `${TAB}, ${JSON.stringify(String(tab.title ?? '').slice(0, 100))}, ` +
  `is on ${hostOf(tab)}, not on ${host} over https, so nothing was filled.`;

let page;
try {
  page = await connect(tab.webSocketDebuggerUrl);
  await page.send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
  await new Promise(resolve => setTimeout(resolve, 500));
  const worlds = [];
  for (const sessionId of [undefined, ...page.attached]) {
    const tree = await page.send('Page.getFrameTree', {}, sessionId).catch(() => null);
    for (const frameId of tree ? framesOf(tree.frameTree) : []) {
      // A frame in another process is reached through its own target, not here.
      const world = await page.send('Page.createIsolatedWorld', { frameId, worldName: 'agent-fill' }, sessionId).catch(() => null);
      if (world) worlds.push({ sessionId, contextId: world.executionContextId });
    }
  }
  if (named) await fillNamedBoxes(worlds);
  // First what each frame would fill, with no username or password sent; then
  // the sign-in goes to the one frame chosen: one with a password field
  // first, the page before its frames.
  const found = [];
  for (const world of worlds) {
    const would = await run(world, null);
    if (would) found.push({ world, would });
  }
  if (found.length === 0) answer({ ok: false, error: notOnSite() });
  const chosen = found.find(each => each.would.accountMissing || each.would.filled.includes('password')) ?? found.find(each => each.would.filled.length);
  if (!chosen) answer({ ok: false, error: 'There is no password field on the page, and no field clearly for the username, so nothing was filled.' });
  if (chosen.would.accountMissing) answer({ ok: false, error: ACCOUNT_MISSING });
  if (chosen.would.filled.includes('account') && (/\s/.test(signIn.account) || signIn.account.length > ACCOUNT_LONGEST)) answer({ ok: false, error: ACCOUNT_ODD });
  const done = await run(chosen.world, { username: String(signIn.username ?? ''), password: signIn.password, account: withAccount ? signIn.account : '' });
  signIn = undefined;
  page.close();
  if (done?.accountMissing) answer({ ok: false, error: ACCOUNT_MISSING });
  if (!done?.filled?.length) answer({ ok: false, error: 'The page changed while filling, so nothing was filled.' });
  answer({ ok: true, filled: done.filled, url: done.url, ...(done.accountUnused ? { accountUnused: true } : {}) });
} catch (error) {
  answer({ ok: false, error: `The page could not be filled (${error.message}).` });
}
