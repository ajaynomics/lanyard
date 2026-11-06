import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { readFile, lstat, unlink, chmod } from 'node:fs/promises';
import { isAbsolute } from 'node:path';
import { createRuntime, READINESS_REASONS } from './runtime.mjs';
import { ApiError } from './state.mjs';

function bearer(actual, token) {
  if (!token || typeof actual !== 'string') return false;
  const given = Buffer.from(actual), expected = Buffer.from(`Bearer ${token}`);
  return given.length === expected.length && timingSafeEqual(given, expected);
}
async function body(request) {
  let data = '';
  for await (const chunk of request) {
    data += chunk;
    if (Buffer.byteLength(data) > 1024 * 1024) throw new ApiError(413, 'request_too_large');
  }
  try { return JSON.parse(data); } catch { throw new ApiError(400, 'invalid_json'); }
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
    // Frames and syncs answer 204/202 with no body.
    const text = await response.text();
    return text ? JSON.parse(text) : null;
  }
  return { authorize: scope => call('/agent/accesses', scope), invoke: (invocation, signal) => call('/agent/invocations', invocation, signal),
    frame: data => call('/agent/frames', data), sync: data => call('/agent/syncs', data) };
}

export async function createServer(config, dependencies = {}) {
  let runtime, readiness = { ready: false, reason: 'configuration_required' };
  try {
    if (!config.sidecarToken || config.sidecarToken.length < 16 || config.sidecarToken === config.railsToken) throw new Error('transport_configuration');
    const callbacks = dependencies.authorize && dependencies.invoke ? {} : railsCallbacks(config, dependencies.fetch);
    runtime = await createRuntime({ ...config, ...callbacks }, dependencies);
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
      // The owner console's calls (Rails decides who is the owner). Each change
      // names the version it saw, so two tabs cannot undo each other. The
      // sign-in link is in start's answer only, never in status.
      const owner = url.pathname.match(/^\/v1\/subscription(?:\/(start|finish|disconnect))?$/);
      if (owner) {
        if (!runtime.subscription) throw new ApiError(404, 'subscription_not_configured');
        const [, step] = owner;
        if (request.method === 'GET' && !step) return send(response, 200, await runtime.subscription.status());
        if (request.method !== 'POST' || !step) throw new ApiError(404, 'not_found');
        const input = await body(request);
        const answer = step === 'start' ? await runtime.subscription.start(input.version)
          : step === 'finish' ? await runtime.subscription.finish({ id: input.id, code: input.code }, input.version)
          : await runtime.subscription.disconnect(input.version);
        return send(response, answer.status, answer.data);
      }
      const match = url.pathname.match(/^\/v1\/conversations\/(\d+)(?:\/(submissions|wakes|entries|cancellations))?$/);
      if (!match) throw new ApiError(404, 'not_found');
      const [, id, action] = match;
      const scope = { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId') };
      if (request.method === 'GET' && !action) return send(response, 200, await runtime.snapshot(id, scope));
      if (request.method === 'POST' && action === 'submissions') return send(response, 202, await runtime.submit(id, await body(request)));
      if (request.method === 'POST' && action === 'wakes') return send(response, 200, await runtime.wake(id, await body(request)));
      if (request.method === 'GET' && action === 'entries') return send(response, 200,
        await runtime.entries(id, scope, url.searchParams.get('after'), url.searchParams.get('limit')));
      if (request.method === 'POST' && action === 'cancellations') return send(response, 200, await runtime.cancel(id, await body(request)));
      throw new ApiError(404, 'not_found');
    } catch (error) {
      if (response.headersSent) response.end();
      else send(response, error.status ?? 500, { error: error instanceof ApiError ? error.category : 'operation_failed' });
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  runtime?.harness.closed.then(end => { if (end.kind === 'failed') readiness = { ready: false, reason: 'storage_failed' }; });
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
        return { socketPath: config.socketPath };
      }
      await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
      return server.address();
    },
    async close() { const closed = new Promise(resolve => server.close(resolve)); for (const socket of sockets) socket.destroy();
      await closed; await runtime?.close(); }
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let file = {};
  if (process.env.AGENT_CONFIG) file = JSON.parse(await readFile(process.env.AGENT_CONFIG, 'utf8'));
  const app = await createServer({ ...file, storePath: process.env.AGENT_STORE ?? file.storePath,
    openaiApiKey: process.env.OPENAI_API_KEY, anthropicApiKey: process.env.ANTHROPIC_API_KEY,
    // Claude through a Claude subscription, signed in from Rails' owner console.
    claudeSubscription: process.env.CLAUDE_SUBSCRIPTION_FILE ? { file: process.env.CLAUDE_SUBSCRIPTION_FILE,
      vaultKey: process.env.SUBSCRIPTION_VAULT_KEY, environment: process.env.DEPLOYMENT_ENVIRONMENT || 'development' } : undefined,
    // `local` offers the free scripted stand-in model (agent/local-model.mjs).
    modelMode: process.env.AGENT_MODEL_MODE ?? file.modelMode, sidecarToken: process.env.SIDECAR_TOKEN,
    railsToken: process.env.RAILS_TOKEN, railsUrl: process.env.RAILS_URL ?? file.railsUrl,
    // Unset means `none`: no file/shell tools. See EXECUTION_MODES in runtime.mjs.
    execution: process.env.AGENT_EXECUTION_MODE ?? file.execution,
    // A bot may use a Sprite as its computer only with a token and an image
    // (agent/computers.mjs). The bridge reads SPRITES_* from this environment.
    sprites: process.env.SPRITES_TOKEN ? { token: process.env.SPRITES_TOKEN, image: process.env.SPRITES_IMAGE } : undefined,
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
