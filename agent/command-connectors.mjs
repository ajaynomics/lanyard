// Command connectors (docs/connectors.md, PARITY.md Round 7): a pi `command`
// MCP server, run on a conversation's own computer. Rails is the MCP client and
// keeps the entry, the tool list and every decision; this holds the process.
//
// One process per conversation and connector, started on the first message for it,
// with the MCP handshake made here. Each message from Rails is passed on
// under an id of ours, and its reply comes back under Rails' id. A process
// that died is started again on the next message; one whose entry changed
// (another digest) is replaced; one without a message for IDLE_MS is
// stopped, which lets a Sprite go to sleep.
//
// `start(spec)` gives { stdin, stdout, kill } for the command, wherever it
// runs. stdout carries the server's JSON-RPC lines and, when the command has
// exited, one closing line: {"method":"avery/exit","params":{"stderr":…}}.
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createInterface } from 'node:readline';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { PassThrough } from 'node:stream';

export const CALL_MS = 30000;
export const IDLE_MS = 10 * 60 * 1000;
export const STDERR_CHARS = 500;
export const CONNECTOR_NAME = /^[a-z][a-z0-9_]{0,19}$/;
const PROTOCOL = '2025-06-18';
const EXIT = 'avery/exit';

// The entry as Rails sends it, or undefined: pi's command, args, env and cwd.
export function validSpec({ command, args = [], env = {}, cwd = null }) {
  const text = value => typeof value === 'string' && value.length > 0 && value.length <= 4096 && !value.includes('\0');
  if (!text(command) || !Array.isArray(args) || args.length > 100 || !args.every(arg => typeof arg === 'string' && !arg.includes('\0'))) return undefined;
  if (!env || typeof env !== 'object' || Array.isArray(env) || Object.keys(env).length > 100) return undefined;
  if (!Object.entries(env).every(([key, value]) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(key) && typeof value === 'string' && !value.includes('\0'))) return undefined;
  if (cwd !== null && !text(cwd)) return undefined;
  return { command, args, env, cwd };
}

// The closing line, the same here and in the Sprite's relay.
export const exitLine = (code, stderr) =>
  `\n${JSON.stringify({ jsonrpc: '2.0', method: EXIT, params: { code, stderr: stderr.slice(-STDERR_CHARS) } })}\n`;

// The command in the conversation's folder on this machine (development's local
// computer). The PATH is this machine's, so `node` and `npx` resolve as they
// do for the developer; nothing else of the sidecar's environment goes along.
export async function localCommand(spec, folder) {
  await mkdir(folder, { recursive: true, mode: 0o700 });
  // As in pi, a leading ~/ names the home folder: here, the conversation's folder.
  const homed = value => value.replace(/^~\//, `${folder}/`);
  // Its own process group, so a wrapper's server (npx, uvx) stops with it.
  const child = spawn(homed(spec.command), spec.args.map(homed), { cwd: resolve(folder, homed(spec.cwd ?? '.')), detached: true,
    stdio: ['pipe', 'pipe', 'pipe'], env: { PATH: process.env.PATH ?? '/usr/bin:/bin', LANG: 'C.UTF-8', HOME: folder, ...spec.env } });
  const stdout = new PassThrough();
  let stderr = '', ended = false;
  child.stdout.pipe(stdout, { end: false });
  child.stderr.setEncoding('utf8').on('data', text => { stderr = (stderr + text).slice(-STDERR_CHARS * 4); });
  const end = code => { if (!ended) { ended = true; stdout.end(exitLine(code, stderr)); } };
  child.on('error', error => { stderr += error.message; end(null); });
  child.on('close', end);
  return { stdin: child.stdin, stdout, kill: () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } };
}

export function commandConnectors({ callMs = CALL_MS, idleMs = IDLE_MS } = {}) {
  const running = new Map();

  function stop(key, entry) {
    clearTimeout(entry.idle);
    entry.ready.then(process => process.child.kill(), () => {});
    if (running.get(key) === entry) running.delete(key);
  }

  // Starts the command and makes the handshake; resolves with the process.
  async function open(start, spec) {
    const child = await start(spec);
    const process = { child, pending: new Map(), next: 1, stderr: '', done: false };
    child.stdin.on('error', () => {});
    const write = message => child.stdin.write(`${JSON.stringify(message)}\n`);
    createInterface({ input: child.stdout }).on('line', line => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (!message || typeof message !== 'object') return;
      if (message.method === EXIT) return void (process.stderr = String(message.params?.stderr ?? '').trim());
      // The server asking us: a ping is answered, anything else refused.
      if (message.method && message.id !== undefined) {
        return void write(message.method === 'ping' ? { jsonrpc: '2.0', id: message.id, result: {} }
          : { jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'Method not found' } });
      }
      const waiter = process.pending.get(message.id);
      if (waiter) { process.pending.delete(message.id); waiter(message); }
    }).on('close', () => {
      process.done = true;
      for (const waiter of process.pending.values()) waiter(null);
      process.pending.clear();
    });
    process.request = (method, params) => new Promise((resolve, reject) => {
      if (process.done) return reject(exited(process));
      const id = process.next++;
      const timer = setTimeout(() => { process.pending.delete(id); reject(new Error(`did not answer within ${callMs / 1000} seconds`)); }, callMs);
      process.pending.set(id, reply => { clearTimeout(timer); reply ? resolve(reply) : reject(exited(process)); });
      write({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) });
    });
    const hello = await process.request('initialize', { protocolVersion: PROTOCOL, capabilities: {},
      clientInfo: { name: 'durable-assistants', version: '1' } }).catch(error => { child.kill(); throw error; });
    if (hello.error) { child.kill(); throw new Error(`refused to start: ${hello.error.message}`); }
    write({ jsonrpc: '2.0', method: 'notifications/initialized' });
    return process;
  }

  return {
    // One JSON-RPC request to the connector `key`, answered with the server's
    // reply or a JSON-RPC error saying in one sentence what went wrong.
    // `start` is only called when no live process has this spec.
    async message(key, spec, message, start) {
      const digest = createHash('sha256').update(JSON.stringify(spec)).digest('hex');
      let entry = running.get(key);
      const live = entry && entry.digest === digest && !(await entry.ready.then(process => process.done, () => true));
      if (entry && !live) stop(key, entry);
      if (!live) running.set(key, entry = { digest, ready: open(start, spec) });
      clearTimeout(entry.idle);
      entry.idle = setTimeout(() => stop(key, entry), idleMs);
      entry.idle.unref?.();
      try {
        const reply = await (await entry.ready).request(message.method, message.params);
        return { ...reply, jsonrpc: '2.0', id: message.id };
      } catch (error) {
        // The computer itself could not be had (an HTTP answer of its own).
        if (Number.isInteger(error?.status)) { stop(key, entry); throw error; }
        return { jsonrpc: '2.0', id: message.id, error: { code: -32000, message: String(error?.message ?? error).slice(0, STDERR_CHARS * 2) } };
      }
    },
    close() { for (const [key, entry] of running) stop(key, entry); }
  };
}

function exited(process) {
  return new Error(process.stderr ? `exited: ${process.stderr}` : 'exited');
}
