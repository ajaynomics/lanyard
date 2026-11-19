// A conversation's computer: where its file and shell tools run. Rails' Computer
// record says whether an agent's conversations have one and which kind
// (it arrives in the agent's definition); this sidecar says which kinds it can
// offer at all.
//
// - `local`: a directory on this machine, only in the trusted single-tenant
//   execution mode (not isolation; see EXECUTION_MODES in runtime.mjs).
// - `sprites`: a microVM on a Sprites platform, reached through the
//   pi-env daemon its image runs (agent/sprites-bridge.mjs,
//   agent/sprite-relay.mjs). Offered only with a token and an image.
// - `ssh`: a folder on a real machine, as one Unix user, over SSH
//   (agent/ssh-computers.mjs). Offered with a folder for its key and hosts.
//
// What each must do is in docs/computers.md.
//
// One computer per conversation: the agent's computer is a template, and each
// conversation gets its own, made the first time it is used. A branch is a new
// conversation, so it starts with a fresh, empty computer.
import { join, dirname, posix } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { NodeExecutionEnv } from '@earendil-works/pi-durable/env/node';
import { ok as envOk, err as envErr } from '@earendil-works/pi-durable/env';
import { Connection, RemoteExecutionEnv } from '@earendil-works/pi-env';
import { validSsh } from './ssh-computers.mjs';

export const SPRITE_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;
const BRIDGE = join(dirname(fileURLToPath(import.meta.url)), 'sprites-bridge.mjs');

// null (no computer), { provider: 'local' }, { provider: 'sprites', name, size? } or
// { provider: 'ssh', host, user, folder, keyring }, each with `notesFile`, a boolean: whether the agent's notes file is read,
// and `held: true` while an operator rebuilds it (Computer#hold!): nothing may wake or make it then.
// A Sprite's `name` is the agent's prefix; each conversation's Sprite is
// spriteName(prefix, id). Its `size` is what a new one is made with
// (Computer::Size), sent only when it is not the install's default, which
// the bridge makes otherwise. Anything else is not a computer description.
export function validComputer(value) {
  if (value === null || value === undefined) return null;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const { notesFile, held, ...rest } = value;
  if (notesFile !== undefined && typeof notesFile !== 'boolean') return undefined;
  if (held !== undefined && held !== true) return undefined;
  const notes = { ...(notesFile === undefined ? {} : { notesFile }), ...(held ? { held } : {}) };
  const keys = Object.keys(rest).sort().join(',');
  if (rest.provider === 'local' && keys === 'provider') return { provider: 'local', ...notes };
  if (rest.provider === 'sprites' && keys === 'name,provider' && typeof rest.name === 'string' && SPRITE_NAME.test(rest.name))
    return { provider: 'sprites', name: rest.name, ...notes };
  if (rest.provider === 'sprites' && keys === 'name,provider,size' && typeof rest.name === 'string' && SPRITE_NAME.test(rest.name) && validSize(rest.size))
    return { provider: 'sprites', name: rest.name, size: { ...rest.size }, ...notes };
  if (rest.provider === 'ssh' && keys === 'folder,host,keyring,provider,user' && validSsh(rest))
    return { provider: 'ssh', host: rest.host, user: rest.user, folder: rest.folder, keyring: rest.keyring, ...notes };
  return undefined;
}

// Whole CPUs and MiB of memory and of disk; Rails holds them within the
// install's maximum, and this only that they are sizes at all.
const PART = /^[1-9][0-9]{0,8}$/;
const validSize = size => !!size && typeof size === 'object' && !Array.isArray(size) &&
  Object.keys(size).sort().join(',') === 'cpus,diskMib,memoryMib' && Object.values(size).every(part => Number.isInteger(part) && PART.test(String(part)));

// A size as the bridge and the screen's query take it, "4,8192,16384", and back; undefined when it is not one.
export const sizeArgument = ({ cpus, memoryMib, diskMib }) => `${cpus},${memoryMib},${diskMib}`;
export function parseSize(text) {
  const parts = typeof text === 'string' ? text.split(',') : [];
  if (parts.length !== 3 || !parts.every(part => PART.test(part))) return undefined;
  const [cpus, memoryMib, diskMib] = parts.map(Number);
  return { cpus, memoryMib, diskMib };
}

// The conversation's own Sprite: the agent's prefix and the conversation's durable id.
export const spriteName = (prefix, conversationId) => {
  const name = `${prefix}-c${conversationId}`;
  if (!SPRITE_NAME.test(name)) throw new Error('invalid_sprite_name');
  return name;
};

// The conversation's notes file: AGENTS.md in its computer's home folder, which the
// owner may drop there and the agent may keep. Each conversation has its own. Read
// whole or not at all: a file over the limit is reported by size only.
export const NOTES_FILE = 'AGENTS.md';
export const NOTES_LIMIT = 32 * 1024;
// The agent works in its home folder (localEnv and spritesComputers below),
// so the file is in the env's cwd, read through the env: on a Sprite, the
// Sprite reads it. A symbolic link is not followed. null when there is no file.
export async function readNotes(env, context) {
  const opened = await env.openBinaryReader(posix.join(env.cwd, NOTES_FILE), { noFollow: true }, context);
  if (!opened.ok) { if (opened.error.code === 'not_found') return null; throw opened.error; }
  const reader = opened.value;
  try {
    const info = await reader.info(context);
    if (!info.ok) throw info.error;
    const bytes = info.value.size;
    if (bytes > NOTES_LIMIT) return { bytes, text: null };
    const read = await reader.read(0, bytes, context);
    if (!read.ok) throw read.error;
    return { bytes, text: new TextDecoder().decode(read.value) };
  } finally { await reader.close(context); }
}

export function offeredComputers({ execution, sprites, ssh }) {
  const given = value => typeof value === 'string' && value.length > 0;
  return Object.freeze({ local: execution === 'trusted-local-single-tenant', sprites: given(sprites?.token) && given(sprites?.image),
    ssh: given(ssh?.dir) });
}

// The conversation's directory on this machine, <agent folder>/<conversation id>,
// under the agent's root that Rails returned at admission. The shell sees a
// minimal environment, never the sidecar's own (tokens, provider keys).
export async function localEnv({ root, conversationId, shellNetwork, shellTmpDir, isolate }) {
  const cwd = join(root, String(conversationId));
  await mkdir(cwd, { recursive: true, mode: 0o700 });
  if (shellTmpDir) await mkdir(shellTmpDir, { recursive: true, mode: 0o700 });
  const shellEnv = { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', HOME: cwd, TMPDIR: shellTmpDir ?? '/tmp' };
  const env = new NodeExecutionEnv({ cwd, shellPath: '/bin/bash', shellEnv });
  const exec = env.exec.bind(env);
  // shellEnv overlays process.env unless a call passes inheritEnv: false.
  const wrap = command => shellNetwork !== 'isolated' ? command : isolate(command);
  env.exec = (command, options, ctx) => exec(wrap(command), { ...options, inheritEnv: false, env: shellEnv }, ctx);
  // Spilled tool output (the full text behind a truncated result) goes to
  // shellTmpDir when one is configured, rather than the host temp directory.
  if (shellTmpDir) env.createTempDir = async (prefix, ctx) => {
    if (ctx?.abortSignal?.aborted) return envErr(new Error('aborted'));
    try {
      await mkdir(shellTmpDir, { recursive: true, mode: 0o700 });
      return envOk(await mkdtemp(join(shellTmpDir, prefix ?? 'tmp-')));
    } catch (error) { return envErr(error); }
  };
  return env;
}

// Wakes the Sprite (looks it up, creates or starts it, waits for its
// entrypoint) in a bridge of its own before the daemon connection starts:
// pi-env gives a starting daemon 60 seconds, and a wake may take 120. At the
// platform's awake cap (429 scope_capacity_exceeded) it fails as
// `computers_busy`; nothing is queued and no other agent is put to sleep.
// A missing Sprite is made at `size`, or the install's default without one;
// one that exists keeps the size it was made with.
export function wakeSprite(name, size) {
  if (!SPRITE_NAME.test(name)) return Promise.reject(new Error('invalid_sprite_name'));
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [BRIDGE, name, 'wake', ...(size ? ['--size', sizeArgument(size)] : [])], { stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    child.stderr.setEncoding('utf8').on('data', text => { stderr = (stderr + text).slice(-2000); });
    child.on('error', reject);
    child.on('close', code => {
      if (code === 0) return resolve();
      reject(new Error(/scope_capacity_exceeded/.test(stderr) ? 'computers_busy' : stderr.trim().split('\n').pop() || 'sprite_unavailable'));
    });
  });
}

// The Sprite's state as the platform says it ("running", "stopped", "cold",
// "missing"), looked up without waking it; null when it cannot be read. "cold"
// is a disk in cold storage, which a wake takes up to a minute to bring back.
export function spriteState(name) {
  if (!SPRITE_NAME.test(name)) return Promise.reject(new Error('invalid_sprite_name'));
  return new Promise(resolve => {
    const child = spawn(process.execPath, [BRIDGE, name, 'state'], { stdio: ['ignore', 'pipe', 'ignore'], timeout: 5000 });
    let out = '';
    child.stdout.setEncoding('utf8').on('data', text => { out = (out + text).slice(-64); });
    child.on('error', () => resolve(null));
    child.on('close', code => resolve(code === 0 ? out.trim() : null));
  });
}

// Deletes the Sprite and its disk, for a deleted agent; one already gone is fine.
export function destroySprite(name) {
  if (!SPRITE_NAME.test(name)) return Promise.reject(new Error('invalid_sprite_name'));
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [BRIDGE, name, 'destroy'], { stdio: ['ignore', 'ignore', 'pipe'], timeout: 30000 });
    let stderr = '';
    child.stderr.setEncoding('utf8').on('data', text => { stderr = (stderr + text).slice(-2000); });
    child.on('error', reject);
    child.on('close', code => code === 0 ? resolve() : reject(new Error(stderr.trim().split('\n').pop() || 'sprite_unavailable')));
  });
}

// One desktop action on the Sprite's screen (desktop.mjs): its JSON line to
// the relay's AGENT-DESK, which posts it to the desktop control server with a
// bearer the agent never sees. Resolves with the answer as it came, '' when
// the relay closed without one (a Sprite made before AGENT-DESK), or null when
// the bridge failed or ran out of time. desktop.mjs tries the old way on either.
export function deskAction(name, action, { timeoutMs = 90000, maxBytes = 16 * 1024 * 1024 } = {}) {
  if (!SPRITE_NAME.test(name)) return Promise.reject(new Error('invalid_sprite_name'));
  return new Promise(resolve => {
    const child = spawn(process.execPath, [BRIDGE, name, 'desk'], { stdio: ['pipe', 'pipe', 'ignore'], timeout: timeoutMs });
    const parts = [];
    let bytes = 0;
    child.stdout.on('data', part => { bytes += part.length; if (bytes <= maxBytes) parts.push(part); else child.kill(); });
    child.stdin.on('error', () => {});
    child.on('error', () => resolve(null));
    child.on('close', code => resolve(code === 0 && bytes <= maxBytes ? Buffer.concat(parts).toString('utf8') : null));
    child.stdin.write(`${JSON.stringify(action)}\n`);
  });
}

// One of the screen's scripts (visit.mjs, fill.mjs, pay.mjs, answer.mjs, upload.mjs) on
// the Sprite, as `browser`, through the relay's AGENT-BROWSER (#60): the only
// user that can reach the screen's DevTools. Called as env.exec is, with the
// same answer, its output given to onOutput once it ends; or null when the
// Sprite's relay predates AGENT-BROWSER (the bridge's exit 3), where the
// caller goes the old way, through the agent's own exec. A sign-in or card in
// `env` goes from here to the script, through no process of the agent's.
const EXIT_LINE = '{"jsonrpc":"2.0","method":"agent/exit"';
export function screenScript(name, argv, { timeout = 45, env = {}, onOutput, maxBytes = 32 * 1024 * 1024 } = {}, context) {
  if (!SPRITE_NAME.test(name)) return Promise.reject(new Error('invalid_sprite_name'));
  const [command, ...args] = argv;
  return new Promise(resolve => {
    // A wake may take two minutes before the script's own time starts.
    const child = spawn(process.execPath, [BRIDGE, name, 'browser'], { stdio: ['pipe', 'pipe', 'ignore'], timeout: (timeout + 150) * 1000 });
    const parts = [];
    let bytes = 0;
    child.stdout.on('data', part => { bytes += part.length; if (bytes <= maxBytes) parts.push(part); else child.kill(); });
    child.stdin.on('error', () => {});
    const failed = message => resolve({ ok: false, error: { code: 'screen_failed', message } });
    child.on('error', error => failed(error.message));
    child.on('close', code => {
      if (code === 3) return resolve(null);
      const text = Buffer.concat(parts).toString('utf8');
      const at = text.lastIndexOf(EXIT_LINE);
      let exit;
      try { exit = at >= 0 ? JSON.parse(text.slice(at)) : null; } catch {}
      if (code !== 0 || bytes > maxBytes || typeof exit?.params?.code !== 'number') return failed('The screen\'s browser did not answer.');
      const output = text.slice(0, at).replace(/\n$/, '');
      if (output) onOutput?.(output, context, { stream: 'stdout' });
      if (exit.params.stderr) onOutput?.(exit.params.stderr, context, { stream: 'stderr' });
      resolve({ ok: true, value: { exitCode: exit.params.code } });
    });
    child.stdin.write(`${JSON.stringify({ command, args, env })}\n`);
  });
}

// One daemon connection per Sprite, that is per conversation. The bridge process
// exits when the daemon has been idle, which closes its connection and stops
// it keeping the Sprite awake; the connection wakes the Sprite and starts a
// new bridge on its next request. The bridges read SPRITES_TOKEN, SPRITES_URL
// and SPRITES_IMAGE from the environment this process passes on.
export function spritesComputers({ token, image, onLog } = {}) {
  if (!token) throw new Error('sprites_token_required');
  if (!image) throw new Error('sprites_image_required');
  const connections = new Map();
  // The size each Sprite was last asked for, which its connection wakes it with.
  const sizes = new Map();
  const connection = (name, size) => {
    if (!SPRITE_NAME.test(name)) throw new Error('invalid_sprite_name');
    sizes.set(name, size);
    if (!connections.has(name)) connections.set(name, new Connection({ onLog,
      command: async () => { await wakeSprite(name, sizes.get(name)); return [process.execPath, BRIDGE, name]; } }));
    return connections.get(name);
  };
  const pipe = async (name, mode, size) => {
    await wakeSprite(name, size);
    const child = spawn(process.execPath, [BRIDGE, name, mode], { stdio: ['pipe', 'pipe', 'pipe'] });
    child.stderr.setEncoding('utf8').on('data', text => onLog?.(text));
    return child;
  };
  return {
    state: spriteState,
    // Its connection closes first, so nothing wakes it again as it goes.
    async destroy(name) {
      connections.get(name)?.close();
      connections.delete(name);
      sizes.delete(name);
      await destroySprite(name);
    },
    // The agent works in the Sprite's home folder.
    async env(name, size) {
      const link = connection(name, size);
      const { home } = await link.info();
      const env = new RemoteExecutionEnv({ connection: link, id: `sprites:${name}`, cwd: home, shellEnv: { HOME: home, LANG: 'C.UTF-8' } });
      // The screen's scripts run as `browser`, not through the agent's exec (#60).
      env.onScreen = (argv, options, context) => screenScript(name, argv, options, context);
      return env;
    },
    // The conversation's screen: wakes the Sprite, then a bridge whose stdin and
    // stdout are a byte pipe to the screen's websockify, keeping the Sprite
    // awake until either end closes.
    screen: (name, size) => pipe(name, 'screen', size),
    // A command connector's process (command-connectors.mjs): the same pipe,
    // to the command the relay starts from the entry sent as its first line.
    async command(name, spec, size) {
      const child = await pipe(name, 'command', size);
      child.stdin.write(`${JSON.stringify(spec)}\n`);
      return { stdin: child.stdin, stdout: child.stdout, kill: () => child.kill() };
    },
    close() { for (const link of connections.values()) link.close(); connections.clear(); sizes.clear(); }
  };
}
