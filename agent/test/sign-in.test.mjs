// Saved sign-ins: agent/sign-in.mjs (the sidecar's half) with a stand-in
// Sprite, and agent/guest/answer.mjs against a fake Chromium DevTools endpoint
// (fill.mjs is tested against real pages in fill.test.mjs).
// The password reaches the fill command's environment and the page, and
// nothing the model reads.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { fillSignIn } from '../sign-in.mjs';
import { privateDir } from './processes.mjs';

const ANSWER_SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest', 'answer.mjs');
const QUESTION = 'What was the name of your first school?';
const ANSWER = 'lighthouse-meadow-4410';
const OTHER = 'harbour-willow-9182';
const PASSWORD = 'correct-horse-battery-staple-7731';
const CALL = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'sign_in_with_saved_password', arguments: { name: 'Bank' } };
const text = result => result.output.map(part => part.text).join('');

function sprite(answer) {
  const runs = [];
  return { runs, api: { env: { id: 'sprites:as-test-b1-c3', async exec(argv, options) {
    runs.push({ argv, env: options.env });
    options.onOutput(JSON.stringify(answer), {}, { stream: 'stdout' });
    return { ok: true, value: { exitCode: 0 } };
  } } } };
}

test('the password goes to the fill command\'s environment, never its arguments or the model\'s result', async () => {
  const { runs, api } = sprite({ ok: true, filled: ['username', 'password'], url: 'https://bank.example/login' });
  const asked = [];
  const signIn = async data => { asked.push(data); return { host: 'bank.example', username: 'maya', password: PASSWORD }; };
  const result = await fillSignIn(signIn, CALL, { signIn: 'Bank' }, api, {});

  assert.deepEqual(asked, [{ actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1' }]);
  assert.deepEqual(runs[0].argv, ['node', '/opt/agent/fill.mjs']);
  assert.deepEqual(Object.keys(runs[0].env), ['AGENT_SIGN_IN'], 'the computer is given the one sign-in and nothing that reaches the vault');
  assert.deepEqual(JSON.parse(runs[0].env.AGENT_SIGN_IN), { host: 'bank.example', username: 'maya', password: PASSWORD });
  assert.equal(result.isError, undefined);
  assert.match(text(result), /^Filled the username and password for Bank on https:\/\/bank\.example\/login\./);
  assert.equal(JSON.stringify(result).includes(PASSWORD), false);
});

test('a saved account goes to the fill command\'s environment with the password, and the model reads only which boxes were filled', async () => {
  const ACCOUNT = '12345';
  const both = sprite({ ok: true, filled: ['account', 'username', 'password'], url: 'https://bank.example/login' });
  const secret = async () => ({ host: 'bank.example', username: 'maya', password: PASSWORD, account: ACCOUNT });
  const filled = await fillSignIn(secret, CALL, { signIn: 'Bank' }, both.api, {});
  assert.deepEqual(both.runs[0].argv, ['node', '/opt/agent/fill.mjs']);
  assert.deepEqual(JSON.parse(both.runs[0].env.AGENT_SIGN_IN), { host: 'bank.example', username: 'maya', password: PASSWORD, account: ACCOUNT });
  assert.match(text(filled), /^Filled the account, username and password for Bank on https:\/\/bank\.example\/login\./);

  const unneeded = sprite({ ok: true, filled: ['username', 'password'], url: 'https://bank.example/login', accountUnused: true });
  const plain = await fillSignIn(secret, CALL, { signIn: 'Bank' }, unneeded.api, {});
  assert.equal(plain.isError, undefined);
  assert.match(text(plain), /^Filled the username and password for Bank .*The page has no box for the saved account number, so it was not needed\./);

  const missing = sprite({ ok: false, error: 'Nothing was filled: the page also asks for an account number, and the saved sign-in has none.' });
  const refused = await fillSignIn(async () => ({ host: 'bank.example', username: 'maya', password: PASSWORD }), CALL, {}, missing.api, {});
  assert.equal(refused.isError, true);
  assert.match(text(refused), /asks for an account number/);
  assert.equal('account' in JSON.parse(missing.runs[0].env.AGENT_SIGN_IN), false, 'no account, none sent');

  for (const result of [filled, plain, refused]) {
    assert.equal(JSON.stringify(result).includes(ACCOUNT), false);
    assert.equal(JSON.stringify(result).includes(PASSWORD), false);
  }
  assert.equal(JSON.stringify(both.runs[0].argv).includes(ACCOUNT), false);
});

test('a computer made before the account fill fills only the username and password, and the model is told the account box was not filled', async () => {
  const ACCOUNT = '12345';
  // fill.mjs from an older image: it ignores the account and says neither that it filled one nor that none was needed.
  const old = sprite({ ok: true, filled: ['username', 'password'], url: 'https://bank.example/login' });
  const result = await fillSignIn(async () => ({ host: 'bank.example', username: 'maya', password: PASSWORD, account: ACCOUNT }), CALL, { signIn: 'Bank' }, old.api, {});
  assert.equal(result.isError, undefined);
  assert.match(text(result), /^Filled the username and password for Bank .*This computer was made before saved account numbers could be filled, so any account box on the page is still empty: type it with the desktop tool, or have the computer made again\./);
  assert.equal(JSON.stringify(result).includes(ACCOUNT), false);
});

// The real case: an API password set from a saved entry, where the site
// would not save until the Confirm Password box matched the New Password box.
test('named password boxes go to the fill command with the password in its environment, and the model reads only the boxes', async () => {
  const boxes = ['#new_password', '#confirm_password'];
  const step = { signIn: 'Phone', step: 'sign_in', passwordFields: boxes };
  const { runs, api } = sprite({ ok: true, filled: boxes.map(box => `password box ${box}`), url: 'https://phone.example/api' });
  const result = await fillSignIn(async () => ({ host: 'phone.example', username: 'maya', password: PASSWORD, account: '12345' }), CALL, step, api, {});

  assert.deepEqual(runs[0].argv, ['node', '/opt/agent/fill.mjs']);
  assert.deepEqual(JSON.parse(runs[0].env.AGENT_SIGN_IN), { host: 'phone.example', boxes: { selectors: boxes, password: PASSWORD } },
    'the password under a name an older fill.mjs does not read, and no username or account');
  assert.equal(result.isError, undefined);
  assert.equal(text(result), 'Filled the password box #new_password and password box #confirm_password for Phone on https://phone.example/api. ' +
    'Press the page\'s own button with the desktop tool.');
  assert.equal(JSON.stringify(result).includes(PASSWORD), false);

  // fill.mjs from an image before named boxes finds no password it reads, and fills nothing.
  const old = sprite({ ok: false, error: 'No sign-in was given.' });
  const older = await fillSignIn(async () => ({ host: 'phone.example', password: PASSWORD }), CALL, step, old.api, {});
  assert.equal(older.isError, true);
  assert.match(text(older), /^This computer was made before password boxes could be named, so nothing was filled/);
  assert.equal(JSON.stringify(older).includes(PASSWORD), false);
});

test('a used or refused sign-in, a page that will not fill, or no screen is an error with no secret in it', async () => {
  const used = await fillSignIn(async () => { throw new Error(`rails_callback_failed ${PASSWORD}`); }, CALL, {}, sprite({}).api, {});
  assert.equal(used.isError, true);
  assert.match(text(used), /already used/);

  const elsewhere = sprite({ ok: false, error: 'The page is not on bank.example over https, so nothing was filled.' });
  const refused = await fillSignIn(async () => ({ host: 'bank.example', username: 'u', password: PASSWORD }), CALL, {}, elsewhere.api, {});
  assert.equal(refused.isError, true);
  assert.match(text(refused), /not on bank\.example/);

  const local = await fillSignIn(async () => ({ host: 'bank.example', password: PASSWORD }), CALL, {}, { env: { id: 'local' } }, {});
  assert.match(text(local), /no screen/);

  const noSite = await fillSignIn(async () => ({ host: null, username: 'u', password: PASSWORD }), CALL, {}, sprite({}).api, {});
  assert.equal(noSite.isError, true);
  assert.match(text(noSite), /no site: its web address/);
  const noPassword = await fillSignIn(async () => ({ host: 'bank.example', username: 'u', password: '' }), CALL, {}, sprite({}).api, {});
  assert.equal(noPassword.isError, true);
  assert.match(text(noPassword), /no password/);
  for (const result of [used, refused, local, noSite, noPassword]) assert.equal(JSON.stringify(result).includes(PASSWORD), false);
});

// A fake browser with the agent's tab on `url`. The page's own answer to the
// fill script is `filled`, or what `filled(expression, count)` gives; every
// expression it was sent is kept.
async function fakeChromium(t, url, filled) {
  const expressions = [];
  let port;
  const tab = { id: 'agent-1', type: 'page', url, get webSocketDebuggerUrl() { return `ws://127.0.0.1:${port}/devtools/page/agent-1`; } };
  const server = createServer((request, response) => {
    if (request.url === '/json/list') return response.end(JSON.stringify([tab]));
    response.writeHead(404).end();
  });
  const sockets = new WebSocketServer({ server });
  sockets.on('connection', socket => socket.on('message', raw => {
    const { id, params } = JSON.parse(raw);
    expressions.push(params.expression);
    const value = typeof filled === 'function' ? filled(params.expression, expressions.length) : filled;
    socket.send(JSON.stringify({ id, result: { result: { value } } }));
  }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
  t.after(() => new Promise(resolve => { sockets.close(); server.close(resolve); server.closeAllConnections?.(); }));
  return { expressions, url: `http://127.0.0.1:${port}` };
}

// The security question's step: the sidecar sends answer.mjs with the call,
// the answers only in its environment, and the model reads the outcome alone.
test('a security question is answered by a command whose environment alone has the answers', async () => {
  const answers = [{ question: QUESTION, answer: ANSWER }];
  const step = { signIn: 'Bank', step: 'security_question' };
  const { runs, api } = sprite({ ok: true, url: 'https://bank.example/verify', sent: true });
  const result = await fillSignIn(async () => ({ host: 'bank.example', answers }), CALL, step, api, {});

  assert.equal(text(result), 'Answered, and sent.');
  assert.deepEqual(runs[0].argv.slice(0, 3), ['node', '--input-type=module', '-e']);
  assert.match(runs[0].argv[3], /function read\(sameSite, host\)/, 'the script travels with the call');
  assert.deepEqual(JSON.parse(runs[0].env.AGENT_SIGN_IN), { host: 'bank.example', answers });
  assert.equal(JSON.stringify(runs[0].argv).includes(ANSWER), false);

  const unknown = await fillSignIn(async () => ({ host: 'bank.example', answers }), CALL, step, sprite({ ok: false, question: 'Your favourite colour?' }).api, {});
  assert.equal(unknown.isError, true);
  assert.match(text(unknown), /^No stored answer for: Your favourite colour\?\. Nothing was filled; ask the person/);

  const noField = await fillSignIn(async () => ({ host: 'bank.example', answers }), CALL, step, sprite({ ok: false, error: 'No answer field was found on the page, so nothing was filled.' }).api, {});
  assert.match(text(noField), /No answer field/);
  for (const each of [result, unknown, noField]) assert.equal(JSON.stringify(each).includes(ANSWER), false);
});

const answerOn = (home, cdp, signIn) => new Promise(resolve => {
  execFile(process.execPath, [ANSWER_SCRIPT], { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, AGENT_SIGN_IN: JSON.stringify(signIn) } },
    (error, stdout, stderr) => resolve({ code: error?.code ?? 0, reply: stdout ? JSON.parse(stdout) : null, stdout, stderr }));
});
const SAVED = { host: 'bank.example', answers: [{ question: 'Your first pet?', answer: OTHER }, { question: QUESTION, answer: ANSWER }] };
// The page reads as `shown`, then answers the fill with `{sent: true}`.
const pageShowing = shown => (_expression, count) => (count === 1 ? {
  url: 'https://bank.example/verify',
  fields: shown.names.map(() => ({ id: '', name: '', type: 'text', form: { id: '', name: '', method: '', action: '' } })),
  ...shown
} : { sent: true });

test('answer.mjs fills only the saved answer whose question is the page\'s, the same but for case and spacing', async t => {
  const home = await privateDir('omakase-answer-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  for (const asked of [QUESTION, '  what was the name of your first school? ', 'WHAT  WAS THE NAME\nOF YOUR   FIRST SCHOOL?']) {
    const chromium = await fakeChromium(t, 'https://login.bank.example/verify?x=1', pageShowing({ names: [['Username'], [asked]], texts: [] }));
    const result = await answerOn(home, chromium.url, SAVED);
    assert.deepEqual(result.reply, { ok: true, url: 'https://login.bank.example/verify', sent: true }, asked);
    assert.equal(chromium.expressions.length, 2);
    assert.equal(chromium.expressions[0].includes(ANSWER) || chromium.expressions[0].includes(OTHER), false, 'reading the page sends no answer');
    assert.ok(chromium.expressions[1].includes(`, 1, "${QUESTION}", `), 'the named field and exact saved question');
    assert.ok(chromium.expressions[1].endsWith(`, "${ANSWER}")`), 'only its answer');
    assert.equal(chromium.expressions[1].includes(OTHER), false, 'no other answer reaches the page');
    assert.equal(result.stdout.includes(ANSWER), false);
  }

  const inText = await fakeChromium(t, 'https://bank.example/verify', pageShowing({ names: [[]], texts: ['Security check', `${QUESTION}`] }));
  assert.equal((await answerOn(home, inText.url, SAVED)).reply.ok, true, 'a question in the page\'s text, with one field to answer in');
  assert.ok(inText.expressions[1].includes(`, 0, "${QUESTION}", `));
  assert.ok(inText.expressions[1].endsWith(`, "${ANSWER}")`));
});

test('answer.mjs fills nothing when no saved question is the page\'s, when the field is unclear, or on another site', async t => {
  const home = await privateDir('omakase-answer-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');

  for (const asked of ['What was the name of your first school', 'What was the name of your first school, exactly?']) {
    const unknown = await fakeChromium(t, 'https://bank.example/verify', pageShowing({ names: [[asked]], texts: [] }));
    assert.deepEqual((await answerOn(home, unknown.url, SAVED)).reply, { ok: false, question: asked }, 'punctuation counts');
    assert.equal(unknown.expressions.length, 1, 'nothing was filled');
  }

  for (const names of [[[], []], [[QUESTION], [QUESTION]], [['Your first pet?'], [QUESTION]]]) {
    const twoFields = await fakeChromium(t, 'https://bank.example/verify', pageShowing({ names, texts: [QUESTION] }));
    assert.match((await answerOn(home, twoFields.url, SAVED)).reply.error, /No answer field/);
    assert.equal(twoFields.expressions.length, 1, 'an ambiguous page receives no answer');
  }

  const noAnswers = await fakeChromium(t, 'https://bank.example/verify', pageShowing({ names: [[QUESTION]], texts: [] }));
  assert.deepEqual((await answerOn(home, noAnswers.url, { host: 'bank.example', answers: [] })).reply, { ok: false, question: QUESTION });

  for (const url of ['https://bank.example.evil.test/verify', 'http://bank.example/verify', 'https://evilbank.example/']) {
    const elsewhere = await fakeChromium(t, url, pageShowing({ names: [[QUESTION]], texts: [] }));
    const result = await answerOn(home, elsewhere.url, SAVED);
    assert.match(result.reply.error, /not on bank\.example over https/, url);
    assert.deepEqual(elsewhere.expressions, [], `${url}: nothing was sent to the page`);
  }
});

function answerPage(hostname = 'bank.example') {
  class HTMLInputElement {
    constructor(type, label, shown = true) {
      Object.assign(this, { type, shown, events: [], disabled: false, readOnly: false, placeholder: '', labels: label ? [{ innerText: label }] : [] });
      this.form = { requestSubmit: () => { this.sent = true; } };
    }
    getAttribute() { return null; }
    getClientRects() { return this.shown ? [{}] : []; }
    dispatchEvent(event) { this.events.push(event.type); }
  }
  Object.defineProperty(HTMLInputElement.prototype, 'value', { set(value) { this.typed = value; } });
  const fields = [new HTMLInputElement('hidden', 'Token'), new HTMLInputElement('text', 'Hidden one', false), new HTMLInputElement('text', QUESTION)];
  const context = { location: new URL(`https://${hostname}/verify`), HTMLInputElement, Event: class { constructor(type) { this.type = type; } },
    document: { querySelectorAll: () => fields, body: { querySelectorAll: () => [] }, getElementById: () => null } };
  return { fields, context };
}

test('in the page, the question is read from labels, and the answer is typed hidden and its form sent', async t => {
  const home = await privateDir('omakase-answer-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  const chromium = await fakeChromium(t, 'https://bank.example/verify', pageShowing({ names: [[QUESTION]], texts: [] }));
  await answerOn(home, chromium.url, SAVED);
  const { runInNewContext } = await import('node:vm');

  const bank = answerPage();
  const { names, texts } = JSON.parse(JSON.stringify(runInNewContext(chromium.expressions[0], bank.context)));
  assert.deepEqual({ names, texts }, { names: [[QUESTION]], texts: [] });
  assert.deepEqual({ ...runInNewContext(chromium.expressions[1], bank.context) }, { sent: true });
  const field = bank.fields[2];
  assert.deepEqual([field.type, field.typed, field.events, field.sent], ['password', ANSWER, ['input', 'change'], true]);

  const moved = answerPage('evil.test');
  assert.equal(runInNewContext(chromium.expressions[1], moved.context), null);
  assert.equal(moved.fields.some(each => each.typed), false);
});

test('the page rechecks the question and field before writing or sending', async t => {
  const home = await privateDir('omakase-answer-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  const chromium = await fakeChromium(t, 'https://bank.example/verify', pageShowing({ names: [[QUESTION]], texts: [] }));
  await answerOn(home, chromium.url, SAVED);
  const { runInNewContext } = await import('node:vm');

  const changes = {
    question: page => { page.fields[2].labels[0].innerText = 'Your first pet?'; },
    association: page => { page.fields[2].labels = []; page.context.document.body.querySelectorAll = () => [{ children: [], innerText: QUESTION, getClientRects: () => [{}] }]; },
    duplicate: page => { page.fields.push(new page.context.HTMLInputElement('text', QUESTION)); },
    reordered: page => { page.fields.unshift(new page.context.HTMLInputElement('text', 'Username')); },
    id: page => { page.fields[2].id = 'replacement'; },
    name: page => { page.fields[2].name = 'replacement'; },
    type: page => { page.fields[2].type = 'search'; },
    hidden: page => { page.fields[2].shown = false; },
    disabled: page => { page.fields[2].disabled = true; },
    readonly: page => { page.fields[2].readOnly = true; },
    form: page => { page.fields[2].form = null; },
    action: page => { page.fields[2].form.action = 'https://bank.example/other'; },
    method: page => { page.fields[2].form.method = 'get'; },
    formId: page => { page.fields[2].form.id = 'replacement'; },
    formName: page => { page.fields[2].form.name = 'replacement'; },
    address: page => { page.context.location.pathname = '/other'; }
  };
  for (const [name, change] of Object.entries(changes)) {
    const page = answerPage();
    change(page);
    assert.equal(runInNewContext(chromium.expressions[1], page.context), null, name);
    assert.equal(page.fields.some(field => field.typed !== undefined || field.sent || field.events.length), false, `${name}: no value, event or submission`);
    assert.equal(page.fields[2].type === 'password', false, `${name}: not even the type was changed`);
  }

  const equivalent = answerPage();
  equivalent.fields[2].labels[0].innerText = '  WHAT was the NAME\n of your FIRST school?  ';
  assert.deepEqual({ ...runInNewContext(chromium.expressions[1], equivalent.context) }, { sent: true }, 'case and spacing still match on the final check');
});
