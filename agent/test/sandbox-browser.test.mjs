// A sandboxed agent's own browser, from the agent's side: whatever socket its
// browser tool uses, the agent's shell can open too. After a sign-in is
// filled, none of them may give the filled password back. Stand-ins only: a
// raw DevTools socket (drive.sock) and the host's act helper (act.sock), with
// act.mjs's refusals. No Chromium, host account or real credential.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer, request } from 'node:http';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import WebSocket, { WebSocketServer } from 'ws';
import { privateDir } from './processes.mjs';
import { sandboxBrowser } from '../sandbox-browser.mjs';

const SECRET = 'made-up-password-7731';
const TAB = 'A'.repeat(32);

// One page, as the host's browser holds it after a fill: the password box has
// the password and the focus, which fill.mjs leaves on the last box it fills.
const page = { url: 'about:blank', title: '', password: '', focus: 'none', text: 'Welcome back' };
const fillSignIn = () => Object.assign(page, { password: SECRET, focus: 'password' });

// drive.sock: Chromium's DevTools, where any script runs.
function devTools() {
  const server = createServer((asked, answer) => {
    const tab = { id: TAB, type: 'page', url: page.url, webSocketDebuggerUrl: `ws://localhost/devtools/page/${TAB}` };
    if (!asked.url.startsWith('/json')) return answer.writeHead(404).end();
    answer.end(JSON.stringify(asked.url.startsWith('/json/new') ? tab : [tab]));
  });
  new WebSocketServer({ server }).on('connection', socket => socket.on('message', text => {
    const { id, method } = JSON.parse(text);
    socket.send(JSON.stringify({ id, result: method === 'Runtime.evaluate' ? { result: { value: page.password } } : {} }));
  }));
  return server;
}

// act.sock: act.mjs's verbs. /open lands on an address with a session in its
// query and fragment; /read skips form values and refuses while a password
// box has focus. `refuse` makes the next action answer with that status.
const helper = { refuse: null };
function act() {
  return createServer((asked, answer) => {
    let body = '';
    asked.setEncoding('utf8').on('data', part => { body += part; }).on('end', () => {
      const reply = (status, value) => answer.writeHead(status, { 'content-type': 'application/json' }).end(JSON.stringify(value));
      const route = `${asked.method} ${asked.url}`;
      if (helper.refuse) { const status = helper.refuse; helper.refuse = null; return reply(status, { error: 'refused: stand-in' }); }
      if (route === 'POST /open') {
        const { url } = JSON.parse(body);
        if (!String(url).startsWith('https:')) return reply(400, { error: 'only https urls' });
        Object.assign(page, { url: `${url}?session=abc123#token=xyz`, title: 'Portal', password: '', focus: 'none' });
        return reply(200, { url: page.url, title: page.title });
      }
      if (route === 'GET /state') return reply(200, { url: page.url, title: page.title });
      if (route === 'POST /read') return page.focus === 'password' ? reply(403, { error: 'refused: the focused field is a password field' }) :
        reply(200, { url: page.url, title: page.title, text: page.text });
      if (route === 'POST /submit') return reply(200, { ok: true, submitted: 'form' });
      reply(404, { error: 'no such action' });
    });
  });
}

const over = (socketPath, method, path, body) => new Promise(resolve => {
  const asked = request({ socketPath, method, path, headers: { Host: 'localhost' } }, answer => {
    let text = '';
    answer.setEncoding('utf8').on('data', part => { text += part; }).on('end', () => resolve(text));
  });
  asked.on('error', () => resolve('')).end(body);
});

// Everything an agent's own program would try on a socket to get a box's value back.
async function tryToRead(socketPath) {
  const replies = [await over(socketPath, 'POST', '/read', '{}'), await over(socketPath, 'GET', '/state')];
  const tabs = await over(socketPath, 'GET', '/json/list');
  let id;
  try { id = JSON.parse(tabs).find(tab => tab.type === 'page')?.id; } catch {}
  if (id) replies.push(await new Promise(resolve => {
    const socket = new WebSocket(`ws+unix:${socketPath}:/devtools/page/${id}`, { headers: { Host: 'localhost' } });
    socket.on('open', () => socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate',
      params: { expression: 'document.querySelector("input[type=password]").value', returnByValue: true } })));
    socket.on('message', text => { socket.close(); resolve(String(text)); }).on('error', () => resolve(''));
  }));
  return replies.join('\n');
}

async function browserOnHost(t) {
  const root = await privateDir('sandbox-browser-');
  await mkdir(join(root, 'avery'));
  const used = new Set();
  for (const [name, server] of [['drive.sock', devTools()], ['act.sock', act()]]) {
    server.on('connection', () => used.add(name));
    await new Promise(resolve => server.listen(join(root, 'avery', name), resolve));
    t.after(() => server.close());
  }
  // The SSH computer runs the tool's command; here, the same Node.
  const env = { id: 'ssh:stand-in', async exec(argv, options) {
    return new Promise(resolve => execFile(process.execPath, argv.slice(1), { env: { PATH: '/usr/bin:/bin' } }, (error, stdout, stderr) => {
      options.onOutput(stdout, {}, { stream: 'stdout' });
      options.onOutput(stderr, {}, { stream: 'stderr' });
      resolve({ ok: true, value: { exitCode: error?.code ?? 0 } });
    }));
  } };
  const visit = sandboxBrowser(async () => ({ name: 'avery', env }), { root }).visit;
  const call = async args => (await visit.execute(args, { conversationId: 1, env }, {})) ;
  return { root, used, call, text: result => result.output.map(part => part.text).join('') };
}

test('after a fill, no socket the sandbox browser tool uses gives the filled password back', async t => {
  const { root, used, call } = await browserOnHost(t);
  await call({ url: 'https://portal.example.test/login' });
  fillSignIn();
  await call({ action: 'submit' });
  assert.ok(used.size > 0, 'the tool reached the browser');
  for (const name of used) {
    const replies = await tryToRead(join(root, 'avery', name));
    assert.ok(!replies.includes(SECRET), `${name} gave the filled password back: ${replies}`);
  }
  assert.deepEqual([...used], ['act.sock']);
});

test('an address from the browser reaches the model without its query or fragment', async t => {
  const { call, text } = await browserOnHost(t);
  const opened = text(await call({ url: 'https://portal.example.test/login' }));
  assert.match(opened, /https:\/\/portal\.example\.test\/login\b/);
  assert.doesNotMatch(opened, /session|abc123|token|xyz|[?#]/);
});

test('the helper\'s refusals read as what the agent can do instead', async t => {
  const { call, text } = await browserOnHost(t);
  helper.refuse = 403;
  const password = await call({ action: 'submit' });
  assert.equal(password.isError, true);
  assert.match(text(password), /password box/);
  assert.match(text(password), /sign_in_with_saved_password/);
  helper.refuse = 404;
  assert.match(text(await call({ action: 'submit' })), /does not offer/);
  helper.refuse = 400;
  assert.match(text(await call({ url: 'https://portal.example.test/' })), /refused/i);
});
