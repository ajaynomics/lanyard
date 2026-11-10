import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { readFile, lstat, unlink, chmod } from 'node:fs/promises';
import { once } from 'node:events';
import { isAbsolute, dirname, join } from 'node:path';
import { createRuntime, READINESS_REASONS } from './runtime.mjs';
import { lendingServer, validLending } from './subscription-lending.mjs';
import { DEFAULT_APPLICATION } from './subscription-credentials.mjs';
import { ApiError } from './state.mjs';

function bearer(actual, token) {
  if (!token || typeof actual !== 'string') return false;
  const given = Buffer.from(actual), expected = Buffer.from(`Bearer ${token}`);
  return given.length === expected.length && timingSafeEqual(given, expected);
}
// A message may carry four 5 MB images, base64 (a third larger); every other
// body is small.
export const BODY_LIMIT = 1024 * 1024;
export const SUBMISSION_BODY_LIMIT = 32 * 1024 * 1024;
const FILE_LIMIT = 25 * 1024 * 1024;
async function body(request, limit = BODY_LIMIT) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw new ApiError(413, 'request_too_large');
    chunks.push(chunk);
  }
  let input;
  try { input = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new ApiError(400, 'invalid_json'); }
  // Every route reads named fields, so anything but an object is malformed.
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new ApiError(400, 'invalid_json');
  return input;
}
const send = (response, status, data) => {
  response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  response.end(JSON.stringify(data));
};
export function railsCallbacks(config, fetchTransport = fetch) {
  const base = new URL(config.railsUrl);
  if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password || !config.railsToken) throw new Error('rails_callback_configuration');
  async function call(path, data, signal) {
    const response = await fetchTransport(new URL(path, base), { method: 'POST', redirect: 'error',
      headers: { authorization: `Bearer ${config.railsToken}`, 'content-type': 'application/json' },
      body: JSON.stringify(data), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(10000)]) : AbortSignal.timeout(10000) });
    if (!response.ok) throw new Error('rails_callback_failed');
    // Frames and syncs answer 204 with no body.
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }
  // A file's bytes (agent/files.mjs): up to 25 MB, given a minute.
  async function fetchFile(data, signal) {
    const response = await fetchTransport(new URL('/agent/files', base), { method: 'POST', redirect: 'error',
      headers: { authorization: `Bearer ${config.railsToken}`, 'content-type': 'application/json' },
      body: JSON.stringify(data), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(60000)]) : AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error('rails_callback_failed');
    if (Number(response.headers.get('content-length')) > FILE_LIMIT) throw new Error('file_too_large');
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > FILE_LIMIT) throw new Error('file_too_large');
      chunks.push(chunk);
    }
    return new Uint8Array(Buffer.concat(chunks));
  }
  return { authorize: scope => call('/agent/accesses', scope), invoke: (invocation, signal) => call('/agent/invocations', invocation, signal),
    frame: data => call('/agent/frames', data), sync: data => call('/agent/syncs', data),
    signIn: (data, signal) => call('/agent/sign_ins', data, signal), fetchFile };
}

export async function createServer(config, dependencies = {}) {
  let runtime, readiness = { ready: false, reason: 'configuration_required' };
  try {
    if (!config.sidecarToken || config.sidecarToken.length < 16 || config.sidecarToken === config.railsToken) throw new Error('transport_configuration');
    const callbacks = dependencies.authorize && dependencies.invoke ? {} : railsCallbacks(config, dependencies.fetch);
    runtime = await createRuntime({ ...config, ...callbacks }, dependencies);
    // Lending needs a grant of its own to lend, and is never borrowed onward.
    if (config.claudeLend && (!validLending(config.claudeLend) || !runtime.subscriptions.anthropic || runtime.subscriptions.anthropic.borrowed))
      throw new Error('claude_lending_invalid');
    readiness = { ready: true };
  } catch (error) {
    // Only a fixed category leaves the process: no path, token, stack or raw error.
    readiness = { ready: false, reason: READINESS_REASONS.includes(error?.message) ? error.message : 'configuration_or_storage_failure' };
  }
  const sockets = new Set();
  const server = http.createServer(async (request, response) => {
    try {
      const url = new URL(request.url, 'http://sidecar.local');
      if (request.method === 'GET' && url.pathname === '/up') return send(response, readiness.ready ? 200 : 503, readiness);
      if (!bearer(request.headers.authorization, config.sidecarToken)) throw new ApiError(401, 'unauthorized');
      if (!runtime || !readiness.ready) throw new ApiError(503, 'not_ready');
      if (request.method === 'POST' && url.pathname === '/v1/conversations') return send(response, 201, await runtime.create(await body(request)));
      if (request.method === 'GET' && url.pathname === '/v1/models') return send(response, 200, runtime.catalogue());
      if (request.method === 'GET' && url.pathname === '/v1/computers/ssh/key') return send(response, 200, await runtime.sshKey(url.searchParams.get('keyring')));
      if (url.pathname === '/v1/computers/ssh/host') {
        if (request.method === 'GET') return send(response, 200,
          await runtime.sshHost({ host: url.searchParams.get('host'), user: url.searchParams.get('user'), keyring: url.searchParams.get('keyring') }));
        if (request.method === 'POST') { const { host, user, keyring, fingerprints } = await body(request);
          return send(response, 200, await runtime.trustSshHost({ host, user, keyring }, fingerprints)); }
      }
      // The owner console's calls (Rails decides who is the owner), one grant
      // per provider. Each change names the version it saw, so two tabs cannot
      // undo each other. The sign-in link is in start's answer only, never in status.
      const owner = url.pathname.match(/^\/v1\/subscriptions\/(anthropic|openai-codex)(?:\/(start|finish|disconnect))?$/);
      if (owner) {
        const [, provider, step] = owner;
        const subscription = runtime.subscriptions[provider];
        if (!subscription) throw new ApiError(404, 'subscription_not_configured');
        if (request.method === 'GET' && !step) return send(response, 200, await subscription.status());
        if (request.method !== 'POST' || !step) throw new ApiError(404, 'not_found');
        const input = await body(request);
        const answer = step === 'start' ? await subscription.start(input.version)
          : step === 'finish' ? await subscription.finish({ id: input.id, code: input.code }, input.version)
          : await subscription.disconnect(input.version);
        return send(response, answer.status, answer.data);
      }
      // The owner's pasted API key: set (checked with the provider first) or
      // removed, by version. Only its last four characters ever come back.
      const keyed = url.pathname.match(/^\/v1\/subscriptions\/(anthropic-api)(\/key)?$/);
      if (keyed) {
        const [, provider, key] = keyed;
        const custody = runtime.apiKeys[provider];
        if (!custody) throw new ApiError(404, 'subscription_not_configured');
        if (request.method === 'GET' && !key) return send(response, 200, await custody.status());
        if (!key || !['PUT', 'DELETE'].includes(request.method)) throw new ApiError(404, 'not_found');
        const input = await body(request);
        const answer = request.method === 'PUT' ? await custody.save(input.key, input.version) : await custody.remove(input.version);
        return send(response, answer.status, answer.data);
      }
      // One JSON-RPC message to a command connector on the conversation's computer.
      const connector = url.pathname.match(/^\/v1\/conversations\/(\d+)\/connectors\/([a-z][a-z0-9_]{0,19})\/rpc$/);
      if (connector && request.method === 'POST') return send(response, 200, await runtime.connector(connector[1], connector[2], await body(request)));
      // A message waiting for the agent: changed (PATCH) or taken back (DELETE).
      const queued = url.pathname.match(/^\/v1\/conversations\/(\d+)\/queued\/(\d+)$/);
      if (queued && request.method === 'PATCH') return send(response, 200, await runtime.changeQueued(queued[1], { ...(await body(request)), id: queued[2] }));
      if (queued && request.method === 'DELETE') return send(response, 200, await runtime.withdrawQueued(queued[1],
        { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId'), id: queued[2] }));
      const match = url.pathname.match(/^\/v1\/conversations\/(\d+)(?:\/(submissions|wakes|entries|cancellations|forks|compactions|export|computer))?$/);
      if (!match) throw new ApiError(404, 'not_found');
      const [, id, action] = match;
      const scope = { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId') };
      if (request.method === 'GET' && !action) return send(response, 200, await runtime.snapshot(id, scope));
      if (request.method === 'POST' && action === 'submissions') return send(response, 202, await runtime.submit(id, await body(request, SUBMISSION_BODY_LIMIT)));
      if (request.method === 'POST' && action === 'forks') return send(response, 201, await runtime.fork(id, await body(request)));
      if (request.method === 'POST' && action === 'compactions') return send(response, 202, await runtime.compact(id, await body(request)));
      if (request.method === 'POST' && action === 'wakes') return send(response, 200, await runtime.wake(id, await body(request)));
      if (request.method === 'GET' && action === 'computer') return send(response, 200, await runtime.computer(id, scope, url.searchParams.get('computer')));
      if (request.method === 'DELETE' && action === 'computer') return send(response, 200, await runtime.removeComputer(id, scope, url.searchParams.get('computer')));
      if (request.method === 'GET' && action === 'entries') return send(response, 200,
        await runtime.entries(id, scope, url.searchParams.get('after'), url.searchParams.get('limit')));
      if (request.method === 'GET' && action === 'export') {
        const lines = await runtime.export(id, { ...scope, title: url.searchParams.get('title') });
        response.writeHead(200, { 'content-type': 'application/jsonl; charset=utf-8', 'cache-control': 'no-store' });
        // One line at a time: a line with pictures is megabytes.
        for await (const line of lines) if (!response.write(`${JSON.stringify(line)}\n`)) await once(response, 'drain');
        return response.end();
      }
      if (request.method === 'POST' && action === 'cancellations') return send(response, 200, await runtime.cancel(id, await body(request)));
      throw new ApiError(404, 'not_found');
    } catch (error) {
      // A body already begun cannot say it failed: cut it, so a reader sees it is incomplete.
      if (response.headersSent) response.destroy();
      else send(response, error.status ?? 500, { error: error instanceof ApiError ? error.category : 'operation_failed' });
    }
  });
  // The conversation's screen (GET /v1/conversations/:id/screen, a websocket
  // upgrade): Rails' bearer, the scope and the computer prefix in the query.
  // The request goes on to the screen's websockify as `GET /websockify`,
  // without the bearer, and then bytes are piped both ways; the sidecar never
  // reads the websocket's frames.
  server.on('upgrade', async (request, socket, head) => {
    socket.on('error', () => {});
    const refuse = (status, category) => socket.end(`HTTP/1.1 ${status} ${http.STATUS_CODES[status]}\r\n` +
      `content-type: application/json\r\ncache-control: no-store\r\nconnection: close\r\n\r\n${JSON.stringify({ error: category })}`);
    try {
      const url = new URL(request.url, 'http://sidecar.local');
      if (!bearer(request.headers.authorization, config.sidecarToken)) return refuse(401, 'unauthorized');
      if (!runtime || !readiness.ready) return refuse(503, 'not_ready');
      const match = url.pathname.match(/^\/v1\/conversations\/(\d+)\/screen$/);
      if (request.method !== 'GET' || !match) return refuse(404, 'not_found');
      const scope = { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId') };
      const pipe = await runtime.screen(match[1], scope, url.searchParams.get('computer'));
      if (socket.destroyed) return void pipe.kill();
      const headers = [];
      for (let i = 0; i < request.rawHeaders.length; i += 2) {
        if (!['authorization', 'host'].includes(request.rawHeaders[i].toLowerCase())) headers.push(`${request.rawHeaders[i]}: ${request.rawHeaders[i + 1]}`);
      }
      pipe.stdin.write(`GET /websockify HTTP/1.1\r\nHost: 127.0.0.1:6080\r\n${headers.join('\r\n')}\r\n\r\n`);
      if (head.length) pipe.stdin.write(head);
      pipe.stdin.on('error', () => {});
      pipe.stdout.pipe(socket);
      socket.pipe(pipe.stdin);
      socket.on('close', () => pipe.kill());
      pipe.on('close', () => socket.destroy());
    } catch (error) {
      refuse(error instanceof ApiError ? error.status : 500, error instanceof ApiError ? error.category : 'operation_failed');
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  runtime?.harness.closed.then(end => { if (end.kind === 'failed') readiness = { ready: false, reason: 'storage_failed' }; });
  const lending = config.claudeLend && readiness.ready ? lendingServer({ ...config.claudeLend,
    custody: runtime.subscriptions.anthropic, lender: config.claudeLend.lender ?? DEFAULT_APPLICATION }) : null;
  return { server, runtime, readiness: () => readiness,
    // Loopback TCP by default. With `socketPath` (absolute), a Unix socket with
    // mode 0600 instead, for a co-located Rails container sharing the volume.
    // A leftover socket file is replaced only when it is a socket: this process
    // already holds the store, so its previous owner has exited.
    async listen(port = config.port ?? 4397) {
      if (config.socketPath !== undefined) {
        if (typeof config.socketPath !== 'string' || !isAbsolute(config.socketPath)) throw new Error('invalid_socket_path');
        const existing = await lstat(config.socketPath).catch(error => { if (error.code === 'ENOENT') return null; throw error; });
        if (existing && !existing.isSocket()) throw new Error('socket_path_occupied');
        if (existing && readiness.ready) await unlink(config.socketPath);
        await new Promise((resolve, reject) => { server.once('error', reject); server.listen(config.socketPath, resolve); });
        await chmod(config.socketPath, 0o600);
        await lending?.listen();
        return { socketPath: config.socketPath };
      }
      await lending?.listen();
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
      return server.address();
    },
    async close() { const closed = new Promise(resolve => server.close(resolve)); for (const socket of sockets) socket.destroy();
      await closed; await lending?.close(); await runtime?.close(); }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  // The scope a subscription grant is sealed for, beside the install's name:
  // SUBSCRIPTION_VAULT_SCOPE, else DEPLOYMENT_ENVIRONMENT as before, so renaming
  // the environment need not lock the agents out of their models.
  const vaultScope = process.env.SUBSCRIPTION_VAULT_SCOPE || process.env.DEPLOYMENT_ENVIRONMENT || 'development';
  let file = {};
  if (process.env.AGENT_CONFIG) file = JSON.parse(await readFile(process.env.AGENT_CONFIG, 'utf8'));
  const app = await createServer({ ...file, storePath: process.env.AGENT_STORE ?? file.storePath,
    openaiApiKey: process.env.OPENAI_API_KEY, anthropicApiKey: process.env.ANTHROPIC_API_KEY,
    // Claude through a Claude subscription, signed in from Rails' owner console.
    claudeSubscription: process.env.CLAUDE_SUBSCRIPTION_FILE ? { file: process.env.CLAUDE_SUBSCRIPTION_FILE,
      vaultKey: process.env.SUBSCRIPTION_VAULT_KEY, environment: vaultScope,
      application: process.env.AGENT_APPLICATION || undefined } : undefined,
    // Two installs on one Claude subscription (subscription-lending.mjs): the
    // owner lends on one socket, the other borrows from it, both with the secret.
    claudeLend: process.env.CLAUDE_SUBSCRIPTION_LEND_SOCKET ? { socketPath: process.env.CLAUDE_SUBSCRIPTION_LEND_SOCKET,
      secret: process.env.CLAUDE_SUBSCRIPTION_LENDING_SECRET, lender: process.env.AGENT_APPLICATION || undefined } : undefined,
    claudeBorrow: process.env.CLAUDE_SUBSCRIPTION_BORROW_SOCKET ? { socketPath: process.env.CLAUDE_SUBSCRIPTION_BORROW_SOCKET,
      secret: process.env.CLAUDE_SUBSCRIPTION_LENDING_SECRET } : undefined,
    // OpenAI's Codex models through a ChatGPT subscription, signed in the same
    // way and sealed with the same vault key.
    chatgptSubscription: process.env.CHATGPT_SUBSCRIPTION_FILE ? { file: process.env.CHATGPT_SUBSCRIPTION_FILE,
      vaultKey: process.env.SUBSCRIPTION_VAULT_KEY, environment: vaultScope,
      application: process.env.AGENT_APPLICATION || undefined } : undefined,
    // `local` offers the free scripted stand-in model (agent/local-model.mjs).
    modelMode: process.env.AGENT_MODEL_MODE ?? file.modelMode, sidecarToken: process.env.SIDECAR_TOKEN,
    railsToken: process.env.RAILS_TOKEN, railsUrl: process.env.RAILS_URL ?? file.railsUrl,
    // Unset means `none`: no file/shell tools. See EXECUTION_MODES in runtime.mjs.
    execution: process.env.AGENT_EXECUTION_MODE ?? file.execution,
    // An agent may use a Sprite as its computer only with a token and an image
    // (agent/computers.mjs). The bridge reads SPRITES_* from this environment.
    sprites: process.env.SPRITES_TOKEN ? { token: process.env.SPRITES_TOKEN, image: process.env.SPRITES_IMAGE } : undefined,
    // An agent may use a folder on a machine over SSH (agent/ssh-computers.mjs);
    // its key pair and trusted hosts live here, beside the store.
    ssh: (process.env.AGENT_STORE ?? file.storePath) ? { dir: join(dirname(process.env.AGENT_STORE ?? file.storePath), 'ssh') } : undefined,
    // Where conversations are summarised, in tokens; see COMPACT_AT_TOKENS.
    compactAtTokens: process.env.AGENT_COMPACT_AT_TOKENS ? Number(process.env.AGENT_COMPACT_AT_TOKENS) : file.compactAtTokens,
    // A turn's guards (agent/README.md, Run policy); the config file's limits otherwise.
    limits: { ...file.limits,
      ...(process.env.AGENT_MAX_REQUESTS ? { maxRequests: Number(process.env.AGENT_MAX_REQUESTS) } : {}),
      ...(process.env.AGENT_REQUEST_IDLE_MS ? { requestIdleMs: Number(process.env.AGENT_REQUEST_IDLE_MS) } : {}) },
    // `isolated` runs tool shells without a network; see SHELL_NETWORK_MODES.
    shellNetwork: process.env.AGENT_SHELL_NETWORK ?? file.shellNetwork,
    port: Number(process.env.PORT ?? file.port ?? 4397),
    // Absolute Unix socket path instead of loopback TCP; see listen().
    socketPath: process.env.AGENT_SOCKET ?? file.socketPath });
  await app.listen();
  process.stdout.write(JSON.stringify({ category: app.readiness().ready ? 'ready' : 'not_ready' }) + '\n');
  let stopping = false;
  const stop = async () => { if (stopping) return; stopping = true; await app.close(); };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
}
