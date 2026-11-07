// A conversation's computer: where its file and shell tools run. Rails' Computer
// record says whether an agent's conversations have one and which kind
// (it arrives in the agent's definition); this sidecar says which kinds it can
// offer at all.
//
// - `local`: a directory on this machine, only in the trusted single-tenant
//   execution mode (not isolation; see EXECUTION_MODES in runtime.mjs).
// - `sprites`: a microVM on Ajay's Sprites platform, reached through the
//   pi-env daemon its image runs (agent/sprites-bridge.mjs,
//   agent/sprite-relay.mjs). Offered only with a token and an image.
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

export const COMPUTER_PROVIDERS = Object.freeze(['local', 'sprites']);
export const SPRITE_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;
const BRIDGE = join(dirname(fileURLToPath(import.meta.url)), 'sprites-bridge.mjs');

// null (no computer), { provider: 'local' } or { provider: 'sprites', name },
// either with `notesFile`, a boolean: whether the agent's notes file is read.
// A Sprite's `name` is the agent's prefix; each conversation's Sprite is
// spriteName(prefix, id). Anything else is not a computer description.
export function validComputer(value) {
  if (value === null || value === undefined) return null;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const { notesFile, ...rest } = value;
  if (notesFile !== undefined && typeof notesFile !== 'boolean') return undefined;
  const notes = notesFile === undefined ? {} : { notesFile };
  const keys = Object.keys(rest).sort().join(',');
  if (rest.provider === 'local' && keys === 'provider') return { provider: 'local', ...notes };
  if (rest.provider === 'sprites' && keys === 'name,provider' && typeof rest.name === 'string' && SPRITE_NAME.test(rest.name))
    return { provider: 'sprites', name: rest.name, ...notes };
  return undefined;
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

export function offeredComputers({ execution, sprites }) {
  const given = value => typeof value === 'string' && value.length > 0;
  return Object.freeze({ local: execution === 'trusted-local-single-tenant', sprites: given(sprites?.token) && given(sprites?.image) });
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
export function wakeSprite(name) {
  if (!SPRITE_NAME.test(name)) return Promise.reject(new Error('invalid_sprite_name'));
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [BRIDGE, name, 'wake'], { stdio: ['ignore', 'ignore', 'pipe'] });
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

// One daemon connection per Sprite, that is per conversation. The bridge process
// exits when the daemon has been idle, which closes its connection and stops
// it keeping the Sprite awake; the connection wakes the Sprite and starts a
// new bridge on its next request. The bridges read SPRITES_TOKEN, SPRITES_URL
// and SPRITES_IMAGE from the environment this process passes on.
export function spritesComputers({ token, image, onLog } = {}) {
  if (!token) throw new Error('sprites_token_required');
  if (!image) throw new Error('sprites_image_required');
  const connections = new Map();
  const connection = name => {
    if (!SPRITE_NAME.test(name)) throw new Error('invalid_sprite_name');
    if (!connections.has(name)) connections.set(name, new Connection({ onLog,
      command: async () => { await wakeSprite(name); return [process.execPath, BRIDGE, name]; } }));
    return connections.get(name);
  };
  const pipe = async (name, mode) => {
    await wakeSprite(name);
    const child = spawn(process.execPath, [BRIDGE, name, mode], { stdio: ['pipe', 'pipe', 'pipe'] });
    child.stderr.setEncoding('utf8').on('data', text => onLog?.(text));
    return child;
  };
  return {
    state: spriteState,
    // The agent works in the Sprite's home folder.
    async env(name) {
      const link = connection(name);
      const { home } = await link.info();
      return new RemoteExecutionEnv({ connection: link, id: `sprites:${name}`, cwd: home, shellEnv: { HOME: home, LANG: 'C.UTF-8' } });
    },
    // The conversation's screen: wakes the Sprite, then a bridge whose stdin and
    // stdout are a byte pipe to the screen's websockify, keeping the Sprite
    // awake until either end closes.
    screen: name => pipe(name, 'screen'),
    // A command connector's process (command-connectors.mjs): the same pipe,
    // to the command the relay starts from the entry sent as its first line.
    async command(name, spec) {
      const child = await pipe(name, 'command');
      child.stdin.write(`${JSON.stringify(spec)}\n`);
      return { stdin: child.stdin, stdout: child.stdout, kill: () => child.kill() };
    },
    close() { for (const link of connections.values()) link.close(); connections.clear(); }
  };
}
