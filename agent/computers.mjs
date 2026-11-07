// A bot's computer: where its file and shell tools run. Rails' Computer record
// says whether a bot has one and which (it arrives in the bot's definition);
// this sidecar says which kinds it can offer at all.
//
// - `local`: a directory on this machine, only in the trusted single-tenant
//   execution mode (not isolation; see EXECUTION_MODES in runtime.mjs).
// - `sprites`: a microVM on Ajay's Sprites platform, reached through the
//   pi-env daemon its image runs (agent/sprites-bridge.mjs,
//   agent/sprite-relay.mjs). Offered only with a token and an image.
//
// One computer per bot; each conversation works in its own directory on it.
import { join, dirname, posix } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { NodeExecutionEnv } from '@earendil-works/pi-durable/env/node';
import { ok as envOk, err as envErr } from '@earendil-works/pi-durable/env';
import { Connection, RemoteExecutionEnv } from '@earendil-works/pi-env';

export const COMPUTER_PROVIDERS = Object.freeze(['local', 'sprites']);
export const SPRITE_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;
const BRIDGE = join(dirname(fileURLToPath(import.meta.url)), 'sprites-bridge.mjs');

// null (no computer), { provider: 'local' } or { provider: 'sprites', name },
// either with `notesFile`, a boolean: whether the bot's notes file is read.
// Anything else is not a computer description.
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

// The bot's notes file: AGENTS.md in its computer folder, shared by all of its
// conversations, which the owner may drop there and the bot may keep. Read
// whole or not at all: a file over the limit is reported by size only.
export const NOTES_FILE = 'AGENTS.md';
export const NOTES_LIMIT = 32 * 1024;
// Every conversation works in <bot folder>/conversations/<id> (localEnv and
// spritesComputers below), so the file is two levels above the env's cwd,
// read through the env: on a Sprite, the Sprite reads it. A symbolic link is
// not followed. null when there is no file.
export async function readNotes(env, context) {
  const opened = await env.openBinaryReader(posix.join(env.cwd, '..', '..', NOTES_FILE), { noFollow: true }, context);
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

// The conversation's directory on this machine, under the bot's root that
// Rails returned at admission. The shell sees a minimal environment, never
// the sidecar's own (tokens, provider keys).
export async function localEnv({ root, conversationId, shellNetwork, shellTmpDir, isolate }) {
  const cwd = join(root, 'conversations', String(conversationId));
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

// One daemon connection per Sprite, shared by its conversations. The bridge
// process exits when the daemon has been idle, which closes its connection
// and stops it keeping the Sprite awake; the connection starts a new bridge on
// its next request. The bridge reads SPRITES_TOKEN, SPRITES_URL and
// SPRITES_IMAGE from the environment this process passes on.
export function spritesComputers({ token, image, onLog } = {}) {
  if (!token) throw new Error('sprites_token_required');
  if (!image) throw new Error('sprites_image_required');
  const connections = new Map();
  const connection = name => {
    if (!SPRITE_NAME.test(name)) throw new Error('invalid_sprite_name');
    if (!connections.has(name)) connections.set(name, new Connection({ command: [process.execPath, BRIDGE, name], onLog }));
    return connections.get(name);
  };
  return {
    async env(name, conversationId, context) {
      const link = connection(name);
      const { home } = await link.info();
      const cwd = `${home}/conversations/${conversationId}`;
      const env = new RemoteExecutionEnv({ connection: link, id: `sprites:${name}`, cwd, shellEnv: { HOME: home, LANG: 'C.UTF-8' } });
      const made = await env.createDir(cwd, { recursive: true }, context);
      if (!made.ok) throw made.error;
      return env;
    },
    close() { for (const link of connections.values()) link.close(); connections.clear(); }
  };
}
