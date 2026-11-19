// A saved sign-in's security question, on an agent's Sprite (agent/sign-in.mjs
// sends this file with the call and runs it with `node`, so computers made
// from an older image have it too). It reads the question on the page
// visit_website last opened, finds the saved answer whose question is the
// same, and fills and sends only that one, only if the page is on the
// sign-in's own site or under it, as fill.mjs does.
//
//   AGENT_SIGN_IN='{"host":…,"answers":[{"question":…,"answer":…}]}' node answer.mjs
//
// The questions are the same when they differ only in case or spacing (the
// spaces around them, and runs of spaces as one): no closer guessing, so
// punctuation counts. Its form is sent as the site set it, every box ticked
// or not as it was. Prints one
// JSON line that never holds an answer: {ok: true, url, sent}, {ok: false,
// question} when no saved question is the page's, or {ok: false, error}.
// Exits 3 when the screen's browser is not there.
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
const saved = Array.isArray(signIn?.answers) ? signIn.answers.filter(it => typeof it?.question === 'string' && typeof it.answer === 'string') : [];
if (!host) answer({ ok: false, error: 'No sign-in was given.' }, 1);

const same = text => String(text).trim().replace(/\s+/g, ' ').toLowerCase();

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
// The refusal names the tab and the site it saw, so the agent knows which page to open.
if (!sameSite(page, host)) answer({ ok: false, error: `The tab visit_website last opened, ${JSON.stringify(String(tab.title ?? '').slice(0, 100))}, ` +
  `is on ${page.hostname ? `${page.protocol}//${page.hostname}` : tab.url || 'no page'}, not on ${host} over https, so nothing was filled.` });

// Runs in the page, and is given no answer: the visible fields an answer
// could go in, each with the words that name it, and the page's short lines
// of text, for a question that is not a field's label.
function read(sameSite, host) {
  if (!sameSite(location, host)) return null;
  const visible = node => node.getClientRects().length > 0;
  const fields = [...document.querySelectorAll('input')]
    .filter(field => ['text', 'password', 'search'].includes(field.type) && !field.disabled && !field.readOnly && visible(field));
  const words = id => document.getElementById(id)?.innerText ?? '';
  const names = fields.map(field => [...field.labels ?? []].map(label => label.innerText)
    .concat(field.getAttribute('aria-label') ?? '', (field.getAttribute('aria-labelledby') ?? '').split(/\s+/).map(words), field.placeholder ?? '')
    .filter(name => name.trim()));
  const texts = [...document.body.querySelectorAll('*')]
    .filter(node => node.children.length === 0 && visible(node) && node.innerText && node.innerText.length <= 300)
    .map(node => node.innerText);
  return { names, texts, url: location.href, fields: fields.map(field => ({
    id: field.id ?? '', name: field.name ?? '', type: field.type,
    form: field.form ? { id: field.form.id ?? '', name: field.form.name ?? '', method: field.form.method ?? '', action: field.form.action ?? '' } : null
  })) };
}

// The page may change between the read and this command. Bind the answer to
// the same question, unambiguous field and form before any write or event.
function fill(sameSite, read, same, host, index, question, expected, text) {
  const shown = read(sameSite, host);
  if (!shown || shown.url !== expected.url) return null;
  const named = shown.names.flatMap((names, i) => names.some(name => same(name) === same(question)) ? [i] : []);
  if (expected.named ? named.length !== 1 || named[0] !== index :
    shown.names.length !== 1 || index !== 0 || !shown.texts.some(text => same(text) === same(question))) return null;
  if (JSON.stringify(shown.names[index].map(same)) !== JSON.stringify(expected.names) ||
    JSON.stringify(shown.fields[index]) !== JSON.stringify(expected.field)) return null;
  const visible = node => node.getClientRects().length > 0;
  const field = [...document.querySelectorAll('input')]
    .filter(field => ['text', 'password', 'search'].includes(field.type) && !field.disabled && !field.readOnly && visible(field))[index];
  if (!field) return null;
  field.type = 'password';
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, text);
  field.dispatchEvent(new Event('input', { bubbles: true }));
  field.dispatchEvent(new Event('change', { bubbles: true }));
  if (!field.form) return { sent: false };
  field.form.requestSubmit();
  return { sent: true };
}

const socket = new WebSocket(tab.webSocketDebuggerUrl);
let sent = 0;
const evaluate = expression => new Promise((resolve, reject) => {
  const id = ++sent;
  const heard = event => {
    const message = JSON.parse(event.data);
    if (message.id !== id) return;
    socket.removeEventListener('message', heard);
    message.error ? reject(new Error('the page refused')) : resolve(message.result?.result?.value);
  };
  socket.addEventListener('message', heard);
  socket.send(JSON.stringify({ id, method: 'Runtime.evaluate', params: { returnByValue: true, expression } }));
});

try {
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve); socket.addEventListener('error', reject); });
  const shown = await evaluate(`(${read})(${sameSite}, ${JSON.stringify(host)})`);
  if (!Array.isArray(shown?.names) || !Array.isArray(shown?.texts)) answer({ ok: false, error: 'The page changed while reading it, so nothing was filled.' });
  const savedFor = text => saved.find(it => same(it.question) && same(it.question) === same(text));

  // A field named by a saved question; else a saved question in the page's
  // text, and the one field there is to answer it in.
  const named = shown.names.flatMap((names, index) => names.some(savedFor) ? [index] : []);
  if (named.length > 1) answer({ ok: false, error: 'No answer field was found on the page, so nothing was filled.' });
  let index = named[0] ?? -1;
  let match = index >= 0 ? shown.names[index].map(savedFor).find(Boolean) : null;
  if (!match) {
    match = shown.texts.map(savedFor).find(Boolean);
    if (match && shown.names.length !== 1) answer({ ok: false, error: 'No answer field was found on the page, so nothing was filled.' });
    index = 0;
  }
  if (!match) {
    const question = shown.names.flat().concat(shown.texts).map(text => text.trim()).find(text => text.endsWith('?')) ?? shown.names.flat()[0]?.trim();
    answer({ ok: false, question: question ?? null });
  }
  const expected = { url: shown.url, field: shown.fields[index], names: shown.names[index].map(same), named: named.length === 1 };
  const filled = await evaluate(`(${fill})(${sameSite}, ${read}, ${same}, ${JSON.stringify(host)}, ${index}, ${JSON.stringify(match.question)}, ${JSON.stringify(expected)}, ${JSON.stringify(match.answer)})`);
  socket.close();
  if (!filled) answer({ ok: false, error: 'The page changed while filling, so nothing was filled.' });
  answer({ ok: true, url: `${page.origin}${page.pathname}`, sent: filled.sent === true });
} catch (error) {
  answer({ ok: false, error: `The page could not be filled (${error.message}).` });
}
