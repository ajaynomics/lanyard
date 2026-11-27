import { createHash } from 'node:crypto';
import { openProcess } from '@earendil-works/pi-env';
import { ApiError } from './state.mjs';

export const FORGE_CHUNK_BYTES = 1024 * 1024;
const LIMIT = 50 * FORGE_CHUNK_BYTES;
const DEADLINE = 120000;
const UPLOAD_DEADLINE = 60000;
const MORE = Buffer.from([1]);
const PROGRAM = '/opt/agent/forge-file.py';
const ROOT = '/home/agent/.forge';
const invalid = () => new Error('forge_file_transfer_failed');
const sha = value => typeof value === 'string' && value.length === 64 && /^[0-9a-f]+$/.test(value);

export function forgeFileRequest(id, input) {
  const { actorId, workspaceId, taskId, callId, digest, forge } = input;
  const named = value => typeof value === 'string' && value.length >= 1 && value.length <= 512 && /^[\w.:|+/=-]+$/.test(value);
  if (Object.keys(input).length !== 6 || ![actorId, workspaceId, taskId, callId].every(named) || !sha(digest) ||
      !forge || Object.keys(forge).sort().join(',') !== 'bytes,id,mode,sha256' || !['stage', 'push'].includes(forge.mode) ||
      typeof forge.id !== 'string' || forge.id.length !== 32 || !/^[0-9a-f]+$/.test(forge.id) || !sha(forge.sha256) ||
      !Number.isSafeInteger(forge.bytes) || forge.bytes <= 0 || forge.bytes > LIMIT) throw new ApiError(422, 'invalid_forge_file');
  return { actorId, workspaceId, conversationId: String(id), taskId, callId, digest, forge };
}

export function forgeFileCallbacks(base, token, fetchTransport, fetchFile) {
  const headers = (call, mode) => ({ 'x-forge-mode': mode, 'x-forge-transfer': call.forge.id,
    'x-forge-actor': call.actorId, 'x-forge-agent': call.workspaceId, 'x-forge-conversation': call.conversationId,
    'x-forge-task': call.taskId, 'x-forge-call': call.callId });
  const upload = async (call, mode, signal, body) => {
    const response = await fetchTransport(new URL('/agent/uploads', base), { method: 'POST', redirect: 'error', signal,
      headers: { authorization: `Bearer ${token}`, ...headers(call, mode),
        ...(body ? { 'content-type': 'application/octet-stream', 'content-length': String(call.forge.bytes) } : {}) },
      ...(body ? { body, duplex: 'half' } : {}) });
    if (response.status !== 204) { await response.body?.cancel(); throw invalid(); }
  };
  return { download: (call, signal) => fetchFile(null, signal, { ...headers(call, 'stage'), 'content-type': 'application/octet-stream' }),
    check: (call, signal) => upload(call, 'push-check', signal),
    upload: (call, body, signal) => upload(call, 'push', AbortSignal.any([signal, AbortSignal.timeout(UPLOAD_DEADLINE)]), body) };
}

// The computer is allowed one response frame per request. No unbounded stdout
// queue, even if the process writes unexpected output or a transfer is cancelled.
class GuestOutput {
  #pending;
  #closed = false;

  read(length) {
    if (this.#closed || this.#pending) throw invalid();
    const { promise, resolve, reject } = Promise.withResolvers();
    promise.catch(() => {});
    this.#pending = { resolve, reject, bytes: Buffer.allocUnsafe(length), offset: 0 };
    return promise;
  }

  receive(chunk) {
    const p = this.#pending;
    if (!p || p.offset + chunk.length > p.bytes.length) return this.close();
    p.bytes.set(chunk, p.offset);
    p.offset += chunk.length;
    if (p.offset === p.bytes.length) { this.#pending = undefined; p.resolve(p.bytes); }
  }

  close() {
    this.#closed = true;
    this.#pending?.reject(invalid());
    this.#pending = undefined;
  }
}

function abortable(signal, fn) {
  signal.throwIfAborted();
  const { promise, reject } = Promise.withResolvers();
  const abort = () => reject(invalid());
  signal.addEventListener('abort', abort, { once: true });
  return Promise.race([Promise.resolve().then(fn), promise]).finally(() => signal.removeEventListener('abort', abort));
}

// Only the conversation's remote execution environment can supply this pipe.
// Neither the caller nor the model can provide a filename, a root or an argv.
async function withGuest(environment, offer, signal, operation) {
  const env = environment();
  if (!env?.id?.startsWith('sprites:') || !env.connection) throw invalid();
  const output = new GuestOutput();
  const ready = output.read(1);
  let child;
  try {
    return await abortable(signal, async () => {
      child = await openProcess(env.connection, { cwd: ROOT.slice(0, ROOT.lastIndexOf('/')),
        argv: ['/usr/bin/python3', '-I', PROGRAM, offer.mode, ROOT, String(offer.bytes), offer.sha256], inheritEnv: false,
        onStdout: chunk => output.receive(chunk) });
      if (signal.aborted) child.close();
      child.exited.then(() => output.close(), () => output.close());
      if ((await ready)[0] !== MORE[0]) throw invalid();
      const exchange = (data, length) => {
        signal.throwIfAborted();
        const response = output.read(length);
        child.write(data);
        return response;
      };
      const finish = async () => {
        signal.throwIfAborted();
        child.write(MORE);
        if (await child.exited !== 0) throw invalid();
      };
      return operation(exchange, finish);
    });
  } finally {
    output.close();
    child?.close();
  }
}

async function stage(callbacks, call, env, signal) {
  const download = await callbacks.download(call, signal);
  const { forge } = call;
  try {
    if (download.size !== forge.bytes) throw invalid();
    const hash = createHash('sha256');
    await withGuest(env, forge, signal, async (exchange, finish) => {
      let total = 0, offset = 0, remaining = forge.bytes;
      const block = Buffer.allocUnsafe(Math.min(FORGE_CHUNK_BYTES, remaining));
      let width = block.length;
      for await (const chunk of download.body) {
        total += chunk.length;
        if (total > forge.bytes) throw invalid();
        hash.update(chunk);
        for (let i = 0; i < chunk.length;) {
          const count = Math.min(chunk.length - i, width - offset);
          block.set(chunk.subarray(i, i + count), offset);
          offset += count;
          i += count;
          if (offset === width) {
            if ((await exchange(block.subarray(0, width), 1))[0] !== MORE[0]) throw invalid();
            remaining -= width;
            width = Math.min(block.length, remaining);
            offset = 0;
          }
        }
      }
      if (total !== forge.bytes || hash.digest('hex') !== forge.sha256) throw invalid();
      await finish();
    });
  } finally { await download.body.return(); }
}

async function push(callbacks, call, env, signal) {
  await callbacks.check(call, signal);
  const { forge } = call;
  await withGuest(env, forge, signal, async (exchange, finish) => {
    const hash = createHash('sha256');
    const body = (async function* () {
      for (let remaining = forge.bytes; remaining > 0;) {
        const chunk = await exchange(MORE, Math.min(FORGE_CHUNK_BYTES, remaining));
        remaining -= chunk.length;
        hash.update(chunk);
        if (remaining === 0) {
          // Rails must not get a complete body if the open file changed.
          if (hash.digest('hex') !== forge.sha256) throw invalid();
          await finish();
        }
        yield chunk;
      }
    })();
    await callbacks.upload(call, body, signal);
  });
}

export async function transferForgeFile(callbacks, call, { env, signal }) {
  const deadline = AbortSignal.any([signal, AbortSignal.timeout(DEADLINE)]);
  try {
    await (call.forge.mode === 'stage' ? stage : push)(callbacks, call, env, deadline);
    return { transferred: true };
  } catch {
    throw new ApiError(422, 'forge_file_transfer_failed');
  }
}
