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
    return response.json();
  }
  return { authorize: scope => call('/agent/accesses', scope), railsEffect: (effect, signal) => call('/agent/effects', effect, signal) };
}

export async function createServer(config, dependencies = {}) {
  let runtime, readiness = { ready: false, reason: 'configuration_required' };
  try {
    if (!config.sidecarToken || config.sidecarToken.length < 16 || config.sidecarToken === config.railsToken) throw new Error('transport_configuration');
    const callbacks = dependencies.authorize && dependencies.railsEffect ? {} : railsCallbacks(config, dependencies.fetch);
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
      if (request.method === 'POST' && url.pathname === '/v1/mcp-grants') return send(response, 200, await runtime.setMcpGrant(await body(request)));
      const match = url.pathname.match(/^\/v1\/conversations\/(\d+)(?:\/(submissions|answers\/([^/]+)|cancellations|events))?$/);
      if (!match) throw new ApiError(404, 'not_found');
      const [, id, action, inputId] = match;
      const scope = { actorId: url.searchParams.get('actorId'), workspaceId: url.searchParams.get('workspaceId') };
      if (request.method === 'GET' && !action) return send(response, 200, await runtime.snapshot(id, scope));
      if (request.method === 'POST' && action === 'submissions') return send(response, 202, await runtime.submit(id, await body(request)));
      if (request.method === 'POST' && action?.startsWith('answers/')) return send(response, 200, await runtime.answer(id, decodeURIComponent(inputId), await body(request)));
      if (request.method === 'POST' && action === 'cancellations') return send(response, 200, await runtime.cancel(id, await body(request)));
      if (request.method === 'GET' && action === 'events') {
        const watch = await runtime.watch(id, scope);
        response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' });
        // Every event replaces the full snapshot, whole history included. Last-Event-ID
        // is deliberately ignored: no process-local sequence can suppress post-restart frames.
        const emit = async () => {
          try { response.write(`event: snapshot\ndata: ${JSON.stringify(await watch.snapshot())}\n\n`); }
          catch { response.end(); await watch.stop(); }
        };
        // The Harness closed or failed: end the stream; the client reconnects.
        watch.closed.then(() => response.end(), () => response.end());
        response.on('close', () => { void watch.stop(); });
        await emit();
        watch.start(emit);
        return;
      }
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
    openaiApiKey: process.env.OPENAI_API_KEY, sidecarToken: process.env.SIDECAR_TOKEN,
    railsToken: process.env.RAILS_TOKEN, railsUrl: process.env.RAILS_URL ?? file.railsUrl,
    // Unset means `none`: no file/shell tools. See EXECUTION_MODES in runtime.mjs.
    execution: process.env.AGENT_EXECUTION_MODE ?? file.execution,
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
