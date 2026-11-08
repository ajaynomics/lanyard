// Two installs on one Claude subscription (docs/agent.md, "Lending the
// Claude subscription"). Copying the grant would not work: every refresh
// rotates the refresh token, so two holders sign each other out. Instead one
// install owns the grant and refreshes it as ever, and lends only its current
// access token; the other borrows it, keeps it a few minutes, and never holds
// or uses a refresh token.
//
// The lender answers one route on a Unix socket of its own, in a host folder
// mounted into both installs' sidecar containers: never on a network. The
// borrower presents the shared secret; nothing else is served there.
import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { isAbsolute } from 'node:path';
import { lstat, unlink, chmod } from 'node:fs/promises';

export const LEND_PATH = '/v1/lend/anthropic';
const UNAVAILABLE = 'Subscription connection unavailable; reconnect required; no fallback';
// The lender refreshes when a token has five minutes left (subscription-credentials.mjs),
// so a borrowed token is put down before then, and in any case after five minutes,
// so a sign-out or a new sign-in at the lender reaches the borrower soon.
const KEEP_MS = 5 * 60 * 1000, BEFORE_EXPIRY_MS = 6 * 60 * 1000, TIMEOUT_MS = 10000;

export const validLending = setting => !!setting && typeof setting.socketPath === 'string' && isAbsolute(setting.socketPath)
  && typeof setting.secret === 'string' && setting.secret.length >= 32;

const matches = (actual, secret) => {
  if (typeof actual !== 'string') return false;
  const given = Buffer.from(actual), expected = Buffer.from(`Bearer ${secret}`);
  return given.length === expected.length && timingSafeEqual(given, expected);
};

// The lender's side: `custody` is its own grant (claude-subscription.mjs).
export function lendingServer({ socketPath, secret, custody, lender }) {
  const send = (response, status, data) => {
    response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    response.end(JSON.stringify(data));
  };
  const server = http.createServer(async (request, response) => {
    try {
      if (!matches(request.headers.authorization, secret)) return send(response, 401, { error: 'unauthorized' });
      if (request.method !== 'GET' || request.url !== LEND_PATH) return send(response, 404, { error: 'not_found' });
      const access = await custody.accessToken();
      const { expiresAt } = await custody.status();
      send(response, 200, { access, expiresAt, lender });
    } catch {
      send(response, 503, { error: 'subscription_unavailable', lender });
    }
  });
  const sockets = new Set();
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  return {
    async listen() {
      const existing = await lstat(socketPath).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
      if (existing && !existing.isSocket()) throw new Error('socket_path_occupied');
      if (existing) await unlink(socketPath);
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socketPath, resolve); });
      await chmod(socketPath, 0o600);
    },
    async close() { const closed = new Promise(resolve => server.close(resolve)); for (const socket of sockets) socket.destroy(); await closed; }
  };
}

function ask({ socketPath, secret }) {
  return new Promise((resolve, reject) => {
    const request = http.request({ socketPath, path: LEND_PATH, method: 'GET', timeout: TIMEOUT_MS,
      headers: { authorization: `Bearer ${secret}` } }, response => {
      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => {
        let data = {};
        try { data = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch {}
        resolve({ status: response.statusCode, data });
      });
    });
    request.on('timeout', () => request.destroy(new Error('timeout')));
    request.on('error', reject);
    request.end();
  });
}

// The borrower's side, in place of its own custody: the same accessToken()
// and status(), and no sign-in of its own.
export function borrowedCustody({ socketPath, secret, now = Date.now }) {
  let kept = null, asking = null, lender = null;
  const borrow = async () => {
    if (kept && now() < kept.until) return kept.access;
    asking ??= (async () => {
      try {
        const { status, data } = await ask({ socketPath, secret });
        if (typeof data?.lender === 'string') lender = data.lender;
        const expires = Date.parse(data?.expiresAt ?? '');
        if (status !== 200 || typeof data.access !== 'string' || !data.access) throw Error(UNAVAILABLE);
        const until = Math.min(now() + KEEP_MS, Number.isFinite(expires) ? expires - BEFORE_EXPIRY_MS : 0);
        kept = until > now() ? { access: data.access, until } : null;
        return data.access;
      } catch {
        kept = null;
        throw Error(UNAVAILABLE);
      } finally { asking = null; }
    })();
    return asking;
  };
  const refused = async () => ({ status: 409, data: { error: 'subscription_borrowed', lender } });
  return {
    borrowed: true,
    accessToken: borrow,
    async status() {
      const connected = await borrow().then(() => true, () => false);
      return { configured: true, connected, borrowed: true, lender, version: 0, expiresAt: null, reconnectRequired: false,
        failure: null, pending: null, credentialSource: 'borrowed', secretsExposed: false, fallback: false };
    },
    start: refused, finish: refused, disconnect: refused
  };
}
