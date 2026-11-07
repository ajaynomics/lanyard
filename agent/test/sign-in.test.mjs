// Saved sign-ins: agent/sign-in.mjs (the sidecar's half) with a stand-in
// Sprite, and agent/guest/fill.mjs against a fake Chromium DevTools endpoint.
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

const FILL = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest', 'fill.mjs');
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
  assert.deepEqual(JSON.parse(runs[0].env.AGENT_SIGN_IN), { host: 'bank.example', username: 'maya', password: PASSWORD });
  assert.equal(result.isError, undefined);
  assert.match(text(result), /^Filled the username and password for Bank on https:\/\/bank\.example\/login\./);
  assert.equal(JSON.stringify(result).includes(PASSWORD), false);
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
  for (const result of [used, refused, local]) assert.equal(JSON.stringify(result).includes(PASSWORD), false);
});

// A fake browser with the agent's tab on `url`. The page's own answer to the
// fill script is `filled`; every expression it was sent is kept.
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
    socket.send(JSON.stringify({ id, result: { result: { value: filled } } }));
  }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
  t.after(() => new Promise(resolve => { sockets.close(); server.close(resolve); server.closeAllConnections?.(); }));
  return { expressions, url: `http://127.0.0.1:${port}` };
}

const fill = (home, cdp, signIn) => new Promise(resolve => {
  execFile(process.execPath, [FILL], { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, AGENT_SIGN_IN: JSON.stringify(signIn) } },
    (error, stdout, stderr) => resolve({ code: error?.code ?? 0, reply: stdout ? JSON.parse(stdout) : null, stdout, stderr }));
});

test('fill.mjs fills the agent\'s tab on the sign-in\'s site, and prints which fields, not their values', async t => {
  const home = await privateDir('omakase-fill-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  const chromium = await fakeChromium(t, 'https://accounts.bank.example/login?next=%2F#top', ['username', 'password']);
  const result = await fill(home, chromium.url, { host: 'bank.example', username: 'maya', password: PASSWORD });

  assert.deepEqual(result.reply, { ok: true, filled: ['username', 'password'], url: 'https://accounts.bank.example/login' });
  assert.equal(result.stdout.includes(PASSWORD) || result.stderr.includes(PASSWORD), false);
  assert.equal(chromium.expressions.length, 1);
  assert.match(chromium.expressions[0], /sameSite\(location, host\)/, 'the page checks its own address again');
});

test('fill.mjs fills nothing on another site, over http, or without the agent\'s tab', async t => {
  const home = await privateDir('omakase-fill-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  for (const url of ['https://bank.example.evil.test/login', 'https://evilbank.example/', 'http://bank.example/login', 'https://example/']) {
    const chromium = await fakeChromium(t, url, ['password']);
    const result = await fill(home, chromium.url, { host: 'bank.example', username: 'maya', password: PASSWORD });
    assert.equal(result.reply.ok, false, url);
    assert.match(result.reply.error, /not on bank\.example/);
    assert.deepEqual(chromium.expressions, [], `${url}: nothing was sent to the page`);
  }

  const elsewhere = await privateDir('omakase-fill-');
  const chromium = await fakeChromium(t, 'https://bank.example/', ['password']);
  const untold = await fill(elsewhere, chromium.url, { host: 'bank.example', password: PASSWORD });
  assert.match(untold.reply.error, /visit_website first/);

  const moved = await fakeChromium(t, 'https://bank.example/', null);
  assert.match((await fill(home, moved.url, { host: 'bank.example', password: PASSWORD })).reply.error, /page changed/);
});

// The script fill.mjs sends, run against a small stand-in page: the visible
// field before the password is the username, hidden ones are skipped, and a
// page that moved to another site is left alone.
test('in the page, the visible username and password fields are filled as typing would', async t => {
  const home = await privateDir('omakase-fill-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  const chromium = await fakeChromium(t, 'https://bank.example/login', ['username', 'password']);
  await fill(home, chromium.url, { host: 'bank.example', username: 'maya', password: PASSWORD });
  const { runInNewContext } = await import('node:vm');

  const page = hostname => {
    class HTMLInputElement {
      constructor(type, shown = true) { Object.assign(this, { type, shown, events: [], disabled: false, readOnly: false, autocomplete: '' }); }
      getClientRects() { return this.shown ? [{}] : []; }
      dispatchEvent(event) { this.events.push(event.type); }
    }
    Object.defineProperty(HTMLInputElement.prototype, 'value', { set(value) { this.typed = value; } });
    const fields = [new HTMLInputElement('search'), new HTMLInputElement('email', false), new HTMLInputElement('email'), new HTMLInputElement('password')];
    const context = { location: new URL(`https://${hostname}/login`), HTMLInputElement, Event: class { constructor(type) { this.type = type; } },
      document: { querySelectorAll: () => fields } };
    return { fields, filled: runInNewContext(chromium.expressions[0], context) };
  };

  const bank = page('bank.example');
  assert.deepEqual([...bank.filled], ['username', 'password']);
  assert.deepEqual(bank.fields.map(field => field.typed), [undefined, undefined, 'maya', PASSWORD]);
  assert.deepEqual([...bank.fields[3].events], ['input', 'change']);

  const moved = page('evil.test');
  assert.equal(moved.filled, null);
  assert.equal(moved.fields.some(field => field.typed), false);
});
