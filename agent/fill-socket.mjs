// A sandboxed agent's own browser: the host's headless Chromium, run as its
// sandbox user, with DevTools at /run/agent-browser/<name>/fill.sock. The
// Sprite's fill.mjs fills it, in a worker (fill-worker.mjs). The socket can do
// anything DevTools can, so the limit is here: fillOnly() passes only a fill's
// calls, and in the page only fill.mjs's own fill, exactly as it writes it,
// with plain JSON arguments; never a navigation, a key, a new tab or a script
// reading the page back. Chromium wants Host: localhost.
import { readFileSync } from 'node:fs';
import { request } from 'node:http';
import { join } from 'node:path';
import { Worker } from 'node:worker_threads';
import WebSocket from 'ws';

export const BROWSERS = '/run/agent-browser';
// As the host names them (/etc/agent-browser/agents.tsv), and Rails (Agent#sandbox_browser).
export const NAME = /^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$/;
const FILL_CALLS = new Set(['Target.setAutoAttach', 'Page.getFrameTree', 'Page.createIsolatedWorld', 'Runtime.evaluate']);
// fill.mjs's functions as its `${fill}` writes them, from its own file: each
// from `function name(` to the brace that closes it at the start of a line.
const SOURCE = readFileSync(new URL('./guest/fill.mjs', import.meta.url), 'utf8');
const [sameSite, reachable, set, fill, fillBoxes] = ['sameSite', 'reachable', 'set', 'fill', 'fillBoxes']
  .map(name => SOURCE.match(new RegExp(`^function ${name}\\(.*?^}$`, 'ms'))?.[0]);
// What each of its two calls starts with, before its own arguments; none if fill.mjs is not as read.
export const FILL_SCRIPTS = [sameSite, reachable, set, fill, fillBoxes].every(Boolean) ?
  [fill, fillBoxes].map(page => `(${page})(${sameSite}, ${reachable}, ${set}, `) : [];

// One of them, then only JSON that reads back as written, then the call's end.
function fillScript(expression) {
  const start = FILL_SCRIPTS.find(each => expression.startsWith(each));
  if (!start || !expression.endsWith(')')) return false;
  const values = expression.slice(start.length, -1);
  try { return JSON.parse(`[${values}]`).map(value => JSON.stringify(value)).join(', ') === values; } catch { return false; }
}

const fillCall = ({ method, params }) => FILL_CALLS.has(method) &&
  (method !== 'Runtime.evaluate' || fillScript(String(params?.expression ?? '')));

const listTabs = socketPath => new Promise((resolve, reject) => {
  const asked = request({ socketPath, path: '/json/list', headers: { Host: 'localhost' }, timeout: 5000 }, response => {
    let body = '';
    response.setEncoding('utf8').on('data', part => { body += part; }).on('end', () => resolve(new Response(body, { status: response.statusCode })));
  });
  asked.on('timeout', () => asked.destroy(new Error('timed out'))).on('error', reject).end();
});

// What fill.mjs uses for fetch and WebSocket, over the socket and fill-only.
export function fillOnly(socketPath) {
  return {
    fetch: async url => {
      if (new URL(url).pathname !== '/json/list') throw new Error('only the list of tabs is read');
      return listTabs(socketPath);
    },
    WebSocket: class extends WebSocket {
      constructor(url) {
        const path = new URL(url).pathname;
        if (!/^\/devtools\/page\/[\w-]+$/.test(path)) throw new Error('only a tab is opened');
        super(`ws+unix:${socketPath}:${path}`, { headers: { Host: 'localhost' } });
      }

      send(text) {
        const message = JSON.parse(text);
        if (fillCall(message)) return super.send(text);
        const refusal = { id: message.id, error: { code: -32601, message: `${message.method} is not part of a fill` } };
        queueMicrotask(() => this.emit('message', Buffer.from(JSON.stringify(refusal)), false));
      }
    }
  };
}

// The host can hold an agent's fills by making fill.sock unreadable to Core
// (0600, its owner only), and keeps the hold across restarts. A refused
// socket is that hold, not a browser that is down, so the agent is told so
// and doesn't ask again.
export const PAUSED = 'Sign-ins are paused for this browser, so nothing was filled. Do not try again; tell the person.';
export const workerExit = error => ['EACCES', 'EPERM'].includes(error?.code) ? 4 : 3;

// fill.mjs's one JSON line, or null when the browser is not there. The
// sign-in is in the worker's own copy of the environment: not the process's,
// an argument or a log.
export function fillInBrowser(name, signIn, { root = BROWSERS, timeoutMs = 45000 } = {}) {
  if (!NAME.test(name)) return Promise.resolve({ ok: false, error: 'That is not an agent\'s browser.' });
  const worker = new Worker(new URL('./fill-worker.mjs', import.meta.url), { workerData: { socketPath: join(root, name, 'fill.sock') },
    env: { AGENT_SIGN_IN: JSON.stringify(signIn) }, stdout: true, stderr: true });
  let answer = '';
  worker.stdout.setEncoding('utf8').on('data', text => { answer += text; });
  worker.stderr.resume();
  const timer = setTimeout(() => worker.terminate(), timeoutMs);
  return new Promise(resolve => worker.on('error', () => resolve(null)).on('exit', code => {
    clearTimeout(timer);
    try { resolve(code === 3 ? null : code === 4 ? { ok: false, error: PAUSED } : JSON.parse(answer)); } catch { resolve(null); }
  }));
}
