// A bot's computer: where its file and shell tools run. Rails' Computer record
// says whether a bot has one and which (it arrives in the bot's definition);
// this sidecar says which kinds it can offer at all.
//
// - `local`: a directory on this machine, only in the trusted single-tenant
//   execution mode (not isolation; see EXECUTION_MODES in runtime.mjs).
// - `sprites`: a Fly.io Sprite, reached through the pi-env daemon running
//   inside it (agent/sprites-bridge.mjs). Offered only with SPRITES_TOKEN.
//
// One computer per bot; each conversation works in its own directory on it.
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir, mkdtemp } from 'node:fs/promises';
import { NodeExecutionEnv } from '@earendil-works/pi-durable/env/node';
import { ok as envOk, err as envErr } from '@earendil-works/pi-durable/env';
import { Connection, RemoteExecutionEnv } from '@earendil-works/pi-env';

export const COMPUTER_PROVIDERS = Object.freeze(['local', 'sprites']);
export const SPRITE_NAME = /^[a-z0-9][a-z0-9-]{0,62}$/;
const BRIDGE = join(dirname(fileURLToPath(import.meta.url)), 'sprites-bridge.mjs');

// null (no computer), { provider: 'local' } or { provider: 'sprites', name }.
// Anything else is not a computer description.
export function validComputer(value) {
  if (value === null || value === undefined) return null;
  if (!value || typeof value !== 'object' || Array.isArray(value)) return undefined;
  const keys = Object.keys(value).sort().join(',');
  if (value.provider === 'local' && keys === 'provider') return { provider: 'local' };
  if (value.provider === 'sprites' && keys === 'name,provider' && typeof value.name === 'string' && SPRITE_NAME.test(value.name))
    return { provider: 'sprites', name: value.name };
  return undefined;
}

export function offeredComputers({ execution, sprites }) {
  return Object.freeze({ local: execution === 'trusted-local-single-tenant', sprites: typeof sprites?.token === 'string' && sprites.token.length > 0 });
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
// process exits when the daemon has been idle, which closes the WebSocket and
// lets the Sprite sleep (an open connection keeps it awake and billing); the
// connection starts a new bridge on its next request.
export function spritesComputers({ token, onLog } = {}) {
  if (!token) throw new Error('sprites_token_required');
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
