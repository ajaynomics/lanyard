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
import { parseSize } from './computers.mjs';

function bearer(actual, token) {
  if (!token || typeof actual !== 'string') return false;
  const given = Buffer.from(actual), expected = Buffer.from(`Bearer ${token}`);
  return given.length === expected.length && timingSafeEqual(given, expected);
}
// A message may carry four 5 MB images, base64 (a third larger); every other
// body is small.
export const BODY_LIMIT = 1024 * 1024;
export const SUBMISSION_BODY_LIMIT = 32 * 1024 * 1024;
// A file's bytes stop arriving for this long: Rails or its source has stalled.
// There is no total time, so a big file is never cut for being big.
export const FILE_IDLE_MS = 60000;
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
  async function call(path, data, signal, timeout = 10000) {
    const response = await fetchTransport(new URL(path, base), { method: 'POST', redirect: 'error',
      headers: { authorization: `Bearer ${config.railsToken}`, 'content-type': 'application/json' },
      body: JSON.stringify(data), signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeout)]) : AbortSignal.timeout(timeout) });
    // The status lets a caller tell a refusal that will not change (404) from a hiccup.
    if (!response.ok) throw Object.assign(new Error('rails_callback_failed'), { status: response.status });
    // Frames and syncs answer 204 with no body.
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }
  // A file's bytes (agent/files.mjs), of any size: its length when Rails
  // says it, and its body as it arrives, never held whole. It fails when no
  // bytes come for fileIdleMs, however long the whole takes.
  async function fetchFile(data, signal) {
    const idleMs = config.fileIdleMs ?? FILE_IDLE_MS;
    const idle = new AbortController();
    let timer;
    const wait = () => { clearTimeout(timer); timer = setTimeout(() => idle.abort(new Error('file_stalled')), idleMs); timer.unref?.(); };
    wait();
    let response;
    try {
      response = await fetchTransport(new URL('/agent/files', base), { method: 'POST', redirect: 'error',
        headers: { authorization: `Bearer ${config.railsToken}`, 'content-type': 'application/json' },
        body: JSON.stringify(data), signal: signal ? AbortSignal.any([signal, idle.signal]) : idle.signal });
    } catch (error) { clearTimeout(timer); throw error; }
    if (!response.ok || !response.body) { clearTimeout(timer); throw new Error('rails_callback_failed'); }
    clearTimeout(timer);
    const length = response.headers.get('content-length');
    // The clock runs only while waiting on Rails, not while the computer
    // takes a chunk. Returning early (a refusal) cancels the rest.
    const chunks = response.body[Symbol.asyncIterator]();
    const body = { [Symbol.asyncIterator]() { return this; },
      async next() { wait(); try { return await chunks.next(); } finally { clearTimeout(timer); } },
      async return() { clearTimeout(timer); await chunks.return?.().catch(() => {}); return { done: true, value: undefined }; } };
    return { size: length === null ? undefined : Number(length), body };
  }
  return { authorize: scope => call('/agent/accesses', scope), invoke: (invocation, signal) => call('/agent/invocations', invocation, signal),
    frame: data => call('/agent/frames', data), sync: data => call('/agent/syncs', data),
    signIn: (data, signal) => call('/agent/sign_ins', data, signal), fetchFile,
    card: (data, signal) => call('/agent/cards', data, signal),
    helper: data => call('/agent/helpers', data),
    // A file for a call, up to the tool's limit in base64: given a minute.
    uploadFile: (data, signal) => call('/agent/uploads', data, signal, 60000) };
}

// The subscriptions signed in now. Rails offers a ChatGPT model only once its
// subscription is (ModelCatalog); a status that can't be read counts as not.
async function signedIn(subscriptions = {}) {
  const connected = await Promise.all(Object.entries(subscriptions).map(async ([provider, custody]) =>
    (await custody.status().catch(() => null))?.connected === true ? provider : null));
  return connected.filter(Boolean);
}

export async function createServer(config, dependencies = {}) {
  let runtime, readiness = { ready: false, reason: 'configuration_required' };
  try {
    if (!config.sidecarToken || config.sidecarToken.length < 16 || config.sidecarToken === config.railsToken) throw new Error('transport_configuration');
    const callbacks = dependencies.authorize && dependencies.invoke ? {} : railsCallbacks(config, dependencies.fetch);
    runtime = await createRuntime({ ...config, ...callbacks }, dependencies);
    // Lending needs a grant of its own to lend, and is never borrowed onward:
    // it lends that grant however the install's own calls are routed.
    if (config.claudeLend && (!validLending(config.claudeLend) || !runtime.lendable))
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
      if (request.method === 'GET' && url.pathname === '/v1/models') return send(response, 200, { ...runtime.catalogue(), signedIn: await signedIn(runtime.subscriptions) });
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
      const owner = url.pathname.match(/^\/v1\/subscriptions\/(anthropic|openai-codex|openai-chatgpt)(?:\/(start|finish|disconnect))?$/);
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
      // A message waiting for the agent: changed (PATCH), taken back (DELETE),
      // or moved one place (PUT its position).
      const position = url.pathname.match(/^\/v1\/conversations\/(\d+)\/queued\/(\d+)\/position$/);
      if (position && request.method === 'PUT') return send(response, 200, await runtime.moveQueued(position[1], { ...(await body(request)), id: position[2] }));
      const queued = url.pathname.match(/^\/v1\/conversations\/(\d+)\/queued\/(\d+)$/);
      if (queued && request.method === 'PATCH') return send(response, 200, await runtime.changeQueued(queued[1], { ...(await body(request)), id: queued[2] }));
      if (queued && request.method === 'DELETE') return send(response, 200, await runtime.withdrawQueued(queued[1],
        { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId'), id: queued[2] }));
      const match = url.pathname.match(/^\/v1\/conversations\/(\d+)(?:\/(submissions|wakes|entries|cancellations|helper_cancellations|helper_messages|helpers|forks|compactions|export|computer|files))?$/);
      if (!match) throw new ApiError(404, 'not_found');
      const [, id, action] = match;
      const scope = { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId') };
      if (request.method === 'GET' && !action) return send(response, 200, await runtime.snapshot(id, scope));
      if (request.method === 'POST' && action === 'submissions') return send(response, 202, await runtime.submit(id, await body(request, SUBMISSION_BODY_LIMIT)));
      if (request.method === 'POST' && action === 'forks') return send(response, 201, await runtime.fork(id, await body(request)));
      if (request.method === 'POST' && action === 'files') return send(response, 200, await runtime.saveFiles(id, await body(request)));
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
      // A background helper Rails starts for a step of a workflow, named by a call of its own.
      if (request.method === 'POST' && action === 'helpers') return send(response, 200, await runtime.startHelper(id, await body(request)));
      // One background helper, named by its call in the body (a call id may hold a slash).
      // Whether one background helper still runs, named by its call in the query.
      if (request.method === 'GET' && action === 'helpers') return send(response, 200, await runtime.helper(id, { ...scope, callId: url.searchParams.get('callId') }));
      if (request.method === 'POST' && action === 'helper_cancellations') return send(response, 200, await runtime.cancelHelper(id, await body(request)));
      if (request.method === 'POST' && action === 'helper_messages') return send(response, 200, await runtime.messageHelper(id, await body(request)));
      throw new ApiError(404, 'not_found');
    } catch (error) {
      // A body already begun cannot say it failed: cut it, so a reader sees it is incomplete.
      if (response.headersSent) response.destroy();
      else send(response, error.status ?? 500, error instanceof ApiError ? { error: error.category, ...(error.detail ? { message: error.detail } : {}) } : { error: 'operation_failed' });
    }
  });
  // The conversation's screen (GET /v1/conversations/:id/screen, a websocket
  // upgrade): Rails' bearer, the scope, the computer prefix and its size in the query.
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
      // The agent's size, when not the install's default: opening the screen first makes the Sprite.
      const size = url.searchParams.has('size') ? parseSize(url.searchParams.get('size')) : null;
      if (size === undefined) return refuse(422, 'invalid_computer');
      const pipe = await runtime.screen(match[1], scope, url.searchParams.get('computer'), size ?? undefined);
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
    custody: runtime.lendable, lender: config.claudeLend.lender ?? DEFAULT_APPLICATION }) : null;
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
    // Or from several lenders, named and in order, falling back from one to
    // the next at a usage limit (claude-routes.mjs): Rails' PI_DURABLE__CLAUDE_ROUTES.
    claudeRoutes: process.env.CLAUDE_ROUTES ? { routes: process.env.CLAUDE_ROUTES,
      secret: process.env.CLAUDE_SUBSCRIPTION_LENDING_SECRET } : undefined,
    // OpenAI's Codex models through a ChatGPT subscription, signed in the same
    // way and sealed with the same vault key.
    chatgptSubscription: process.env.CHATGPT_SUBSCRIPTION_FILE ? { file: process.env.CHATGPT_SUBSCRIPTION_FILE,
      vaultKey: process.env.SUBSCRIPTION_VAULT_KEY, environment: vaultScope,
      application: process.env.AGENT_APPLICATION || undefined } : undefined,
    // Or OpenAI through a lender's "Sign in with ChatGPT" (chatgpt-lending.mjs),
    // borrowed like Claude above, with the same secret.
    chatgptBorrow: process.env.CHATGPT_SUBSCRIPTION_BORROW_SOCKET ? { socketPath: process.env.CHATGPT_SUBSCRIPTION_BORROW_SOCKET,
      secret: process.env.CLAUDE_SUBSCRIPTION_LENDING_SECRET } : undefined,
    // `local` offers the free scripted stand-in model (agent/local-model.mjs).
    modelMode: process.env.AGENT_MODEL_MODE ?? file.modelMode, sidecarToken: process.env.SIDECAR_TOKEN,
    railsToken: process.env.RAILS_TOKEN, railsUrl: process.env.RAILS_URL ?? file.railsUrl,
    // The install's own address: links on it go through masking whole (secret-mask.mjs).
    appUrl: process.env.APP__URL ?? file.appUrl,
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
