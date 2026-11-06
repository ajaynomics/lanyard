import { fork } from 'node:child_process';
import { once } from 'node:events';
import { writeFile, mkdtemp } from 'node:fs/promises';
import { rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

// Every test process gets its own private parent directory (mode 0700) and
// creates its temporary directories inside it, so no path is shared with
// another test run or agent using the host temp directory. The parent is
// removed when this process exits, after cases closed their runtimes and
// stopped their processes.
let parent;
process.on('exit', () => { if (parent) rmSync(parent, { recursive: true, force: true }); });
export async function privateDir(prefix) {
  parent ??= mkdtempSync(join(tmpdir(), 'omakase-agent-test-'));
  return mkdtemp(join(parent, prefix));
}

// Every sidecar process this module started, so callers can prove cleanup and
// never signal a process they did not start.
const started = new Map();
export const startedProcesses = () => [...started.values()].map(({ pid, exited }) => ({ pid, exited: exited() }));

// options.env: extra environment for this process only (synthetic sentinels in
// tests); the base is PATH/HOME/LANG, never the caller's environment.
export async function launch(config, directory, suffix = '', options = {}) {
  const file = join(directory, `process${suffix}.json`);
  await writeFile(file, JSON.stringify(config), { mode: 0o600 });
  const child = fork(new URL('./process-entry.mjs', import.meta.url), [file], {
    execArgv: ['--import', new URL('./local-only.mjs', import.meta.url).pathname],
    env: { PATH: '/usr/bin:/bin', HOME: directory, LANG: 'C.UTF-8', ...options.env },
    stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
  const exited = () => child.exitCode !== null || child.signalCode !== null;
  started.set(child.pid, { pid: child.pid, exited });
  let logs = '';
  child.stdout.on('data', chunk => { logs += chunk; });
  child.stderr.on('data', chunk => { logs += chunk; });
  const ready = await Promise.race([once(child, 'message').then(([message]) => message),
    once(child, 'exit').then(([code]) => { throw new Error(`fixture_exit_${code}: ${logs}`); })]);
  return { child, pid: child.pid, ...ready, logs: () => logs,
    url: `http://127.0.0.1:${ready.port}`,
    inspect(id) { return this.ipc({ type: 'inspect', id }); },
    /** Scripted-model calls and refused non-local attempts, even when not ready. */
    stats() { return this.ipc({ type: 'stats' }); },
    async ipc(request) {
      const nonce = randomUUID();
      const reply = new Promise((resolve, reject) => {
        const listener = message => {
          if (message?.type !== 'inspection' || message.nonce !== nonce) return;
          child.off('message', listener);
          message.error ? reject(new Error(message.error)) : resolve(message.value);
        };
        child.on('message', listener);
      });
      child.send({ ...request, nonce });
      return reply;
    },
    async stop(signal = 'SIGTERM') {
      if (exited()) return;
      const done = once(child, 'exit');
      child.kill(signal);
      await done;
    }
  };
}
export function client(process, config, scope = { actorId: 'alice', workspaceId: 'one' }) {
  return async (path, data, method) => {
    const request = await fetch(process.url + path, { method: method ?? (data ? 'POST' : 'GET'),
      headers: { authorization: `Bearer ${config.sidecarToken}`, 'content-type': 'application/json' },
      ...(data ? { body: JSON.stringify({ ...scope, ...data }) } : {}) });
    return { status: request.status, body: await request.json() };
  };
}
export async function eventually(fn, timeoutMs = 8000) {
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) { const result = await fn(); if (result) return result; await new Promise(resolve => setTimeout(resolve, 10)); }
  throw new Error('fixture_deadline');
}
