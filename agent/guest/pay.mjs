// An approved payment's one-time card on an agent's Sprite (agent/card.mjs):
// fills the checkout page visit_website last opened (the tab named in
// ~/.visit-tab) over CDP (127.0.0.1:9222), in the page and in each of its
// frames, a payment provider's card frames included. Only where the page is
// on the checkout's own site over https: the tab is checked first, then each
// frame checks again, itself and the pages it sits in, as it fills. Each field filled is masked, so a screenshot shows dots, not the
// number. Never submits: the agent presses the pay button.
//
//   AGENT_CARD='{"site":…,"number":…,"cvc":…,"expMonth":…,"expYear":…,"name":…,"postalCode":…}' node /opt/agent/pay.mjs
//
// Prints one JSON line, {ok: true, filled: [...], url} or {ok: false, error},
// that never holds the card. Exits 3 when the screen's browser is not there.
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const CDP = process.env.AGENT_CDP ?? 'http://127.0.0.1:9222';
const TAB_FILE = join(homedir(), '.visit-tab');
const answer = (reply, code = 0) => { process.stdout.write(`${JSON.stringify(reply)}\n`); process.exit(code); };

let card;
try { card = JSON.parse(process.env.AGENT_CARD ?? ''); } catch { answer({ ok: false, error: 'No card was given.' }, 1); }
delete process.env.AGENT_CARD;
const site = String(card?.site ?? '').toLowerCase().replace(/\.$/, '');
if (!site || typeof card.number !== 'string' || !card.number) answer({ ok: false, error: 'No card was given.' }, 1);

// The checkout's site, or a name under it (pay.example.com for example.com);
// never a look-alike or a parent.
function onSite(url, siteHost) {
  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  return url.protocol === 'https:' && (host === siteHost || host.endsWith(`.${siteHost}`));
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
if (!tab) answer({ ok: false, error: 'Open the checkout page with visit_website first.' });
let page;
try { page = new URL(tab.url); } catch { page = new URL('about:blank'); }
if (!onSite(page, site)) answer({ ok: false, error: `The page is not on ${site} over https, so nothing was filled.` });

// Runs in one frame. It fills only if this frame is https and every page it
// sits in (location.ancestorOrigins), or the frame itself when it is the page,
// is on the checkout's site: a payment provider's card frame inside the
// checkout fills, a frame inside some other site's frame does not. Fields are
// found as browsers' autofill finds them: by autocomplete first, then by name.
// A value is set as a person's typing would be (the native setter, then input
// and change events), so the page's own scripts see it. Returns what it
// filled, or null when this frame is not one to fill. Beside the card (the
// second pass, once the number is in) it fills only the name on the card and
// the billing postal code, where the page marks them so and they are empty: a
// checkout's own form around a payment provider's card frame.
function fill(onSite, siteHost, card, beside) {
  const around = location.ancestorOrigins?.length ? [...location.ancestorOrigins] : [location.href];
  if (location.protocol !== 'https:' || !around.every(origin => onSite(new URL(origin), siteHost))) return null;
  const visible = field => !field.disabled && !field.readOnly && field.getClientRects().length > 0;
  const fields = [...document.querySelectorAll('input, select')].filter(visible);
  const words = field => [field.name, field.id, field.getAttribute('aria-label'), field.placeholder, field.labels?.[0]?.textContent]
    .filter(Boolean).join(' ').toLowerCase();
  const find = (autocomplete, pattern) => fields.find(field => field.autocomplete === autocomplete) ??
    fields.find(field => !field.autocomplete?.startsWith('cc-') && pattern.test(words(field)));
  const set = (field, value) => {
    const prototype = field instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    if (field instanceof HTMLSelectElement) {
      const option = [...field.options].find(each => [each.value, each.text].some(text => text.trim() === value || Number(text) === Number(value)));
      if (!option) return false;
      value = option.value;
    }
    Object.getOwnPropertyDescriptor(prototype, 'value').set.call(field, value);
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
    if (!(field instanceof HTMLSelectElement) && !beside) field.style.setProperty('-webkit-text-security', 'disc', 'important');
    return true;
  };
  const filled = [];
  if (beside) {
    const name = fields.find(field => field.autocomplete === 'cc-name');
    if (name && !name.value && card.name && set(name, card.name)) filled.push('name');
    const postal = fields.find(field => field.autocomplete === 'billing postal-code');
    if (postal && !postal.value && card.postalCode && set(postal, card.postalCode)) filled.push('postal code');
    return filled;
  }
  const month = String(card.expMonth).padStart(2, '0'), year = String(card.expYear);
  const number = find('cc-number', /card.?num|cc.?num|cardnumber/);
  if (number && set(number, card.number)) filled.push('number');
  const expiry = find('cc-exp', /expir|exp.?date|mm ?\/ ?yy/);
  if (expiry) {
    const long = /yyyy/i.test(expiry.placeholder) || expiry.maxLength >= 9;
    const value = `${month}${expiry.maxLength >= 7 || expiry.maxLength < 0 ? ' / ' : '/'}${long ? year : year.slice(-2)}`;
    if (set(expiry, value)) filled.push('expiry');
  } else {
    const expMonth = find('cc-exp-month', /exp.*month|month/), expYear = find('cc-exp-year', /exp.*year|year/);
    if (expMonth && set(expMonth, month)) filled.push('expiry month');
    if (expYear && (set(expYear, year) || set(expYear, year.slice(-2)))) filled.push('expiry year');
  }
  const cvc = find('cc-csc', /cvc|cvv|csc|security.?code/);
  if (cvc && card.cvc && set(cvc, card.cvc)) filled.push('security code');
  // The name and postal code only beside the card's own fields, and only when empty.
  if (filled.length) {
    const name = find('cc-name', /name.?on.?card|card.?holder|card.?name/);
    if (name && !name.value && card.name && set(name, card.name)) filled.push('name');
    const postal = find('postal-code', /postal|zip/);
    if (postal && !postal.value && card.postalCode && set(postal, card.postalCode)) filled.push('postal code');
  }
  return filled;
}

// One DevTools connection to the tab. Frames from another site run in their
// own process, reached as their own target (Target.setAutoAttach, flattened
// into this connection); every frame is filled in an isolated world of its own.
const socket = new WebSocket(tab.webSocketDebuggerUrl);
const waiting = new Map(), sessions = [undefined];
let next = 0;
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = ++next;
  waiting.set(id, { resolve, reject });
  socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
});
socket.addEventListener('message', event => {
  const message = JSON.parse(event.data);
  if (message.method === 'Target.attachedToTarget' && message.params.targetInfo?.type === 'iframe') {
    sessions.push(message.params.sessionId);
    send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true }, message.params.sessionId).catch(() => {});
  }
  const waiter = waiting.get(message.id);
  if (!waiter) return;
  waiting.delete(message.id);
  message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result);
});
const framesOf = tree => [tree.frame.id, ...(tree.childFrames ?? []).flatMap(framesOf)];

try {
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', reject); });
  await send('Target.setAutoAttach', { autoAttach: true, waitForDebuggerOnStart: false, flatten: true });
  await new Promise(resolve => setTimeout(resolve, 500));
  const worlds = [];
  for (const sessionId of sessions) {
    const tree = await send('Page.getFrameTree', {}, sessionId).catch(() => null);
    for (const frameId of tree ? framesOf(tree.frameTree) : []) {
      // A frame in another process is filled through its own target, not here.
      const world = await send('Page.createIsolatedWorld', { frameId, worldName: 'agent-pay' }, sessionId).catch(() => null);
      if (world) worlds.push({ sessionId, contextId: world.executionContextId });
    }
  }
  const filled = [];
  const pass = async beside => {
    const expression = `(${fill})(${onSite}, ${JSON.stringify(site)}, ${JSON.stringify(card)}, ${beside})`;
    for (const { sessionId, contextId } of worlds) {
      const reply = await send('Runtime.evaluate', { contextId, returnByValue: true, expression }, sessionId).catch(() => null);
      const value = reply?.result?.value;
      if (Array.isArray(value)) filled.push(...value.filter(each => !filled.includes(each)));
    }
  };
  await pass(false);
  if (filled.includes('number')) await pass(true);
  card = undefined;
  socket.close();
  if (filled.length === 0) answer({ ok: false, error: 'There is no card field on the page, so nothing was filled.' });
  if (!filled.includes('number')) answer({ ok: false, error: `Only the ${filled.join(', ')} could be filled; the card number field wasn't found.` });
  answer({ ok: true, filled, url: `${page.origin}${page.pathname}` });
} catch (error) {
  answer({ ok: false, error: `The page could not be filled (${error.message}).` });
}
