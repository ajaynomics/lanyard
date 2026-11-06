// Claude through Ajay's Claude subscription, not an API key: what Pi does after
// `/login anthropic` with the pi-anthropic-auth extension, and what an earlier app's
// app/src/claude-subscription.js copies.
//
// pi-ai already does most of it. Given a stored OAuth credential it refreshes
// the token before a request when it has expired (under the store's lock),
// sends it as a bearer, and for an `sk-ant-oat` token adds Claude Code's
// identity, beta flags and tool names. What it leaves to the extension, and so
// to us, is the billing block: a first system block derived from the first
// user message and the Claude Code version (shapePayload below). The
// extension also rewrites Pi's own coding-agent prompt; this sidecar never
// sends that prompt, so there is nothing of it to rewrite.
//
// The credential lives in one file beside the sidecar's store, mode 0600,
// written by `node claude-login.mjs` once and by pi-ai's refresh afterwards.
// A refresh token is single-use: sharing this file with another program, or
// copying another program's credential into it, breaks one of them.
import { createHash } from 'node:crypto';
import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { createProvider } from '@earendil-works/pi-ai/models';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { anthropicMessagesApi } from '@earendil-works/pi-ai/api/anthropic-messages.lazy';

// pi-ai's own claudeCodeVersion, as the extension and an earlier app pin it. Anthropic
// refuses a model to an older Claude Code with `claude_code_version_too_old`;
// raise this deliberately when that happens.
export const CLAUDE_CODE_VERSION = '2.1.280';
const MARKER = 'x-anthropic-billing-header:';
const SALT = '59cf53e54c78';

function firstUserText(messages) {
  const first = messages.find(message => message?.role === 'user');
  if (typeof first?.content === 'string') return first.content;
  const block = Array.isArray(first?.content) && first.content.find(part => part?.type === 'text' && typeof part.text === 'string');
  return block ? block.text : '';
}

const sha256 = text => createHash('sha256').update(text).digest('hex');

// The extension's recipe (billing-header.ts), byte for byte.
export function billingHeader(text, version = CLAUDE_CODE_VERSION) {
  if (!text) return undefined;
  const sampled = [4, 7, 20].map(index => text[index] || '0').join('');
  const suffix = sha256(`${SALT}${sampled}${version}`).slice(0, 3);
  return `${MARKER} cc_version=${version}.${suffix}; cc_entrypoint=sdk-cli; cch=${sha256(text).slice(0, 5)};`;
}

// Prepends the billing block to a built Anthropic payload, once.
export function shapePayload(payload) {
  if (!payload || typeof payload !== 'object' || !Array.isArray(payload.messages)) return payload;
  const header = billingHeader(firstUserText(payload.messages));
  if (!header) return payload;
  const blocks = (Array.isArray(payload.system) ? payload.system : payload.system == null ? [] : [payload.system])
    .map(block => typeof block === 'string' ? { type: 'text', text: block } : block);
  if (blocks.some(block => typeof block?.text === 'string' && block.text.includes(MARKER))) return payload;
  return { ...payload, system: [{ type: 'text', text: header }, ...blocks] };
}

// Pi's Anthropic provider with only its OAuth sign-in (no API key), whose
// requests carry the billing block. Same id, models and endpoint.
export function subscriptionProvider() {
  const base = anthropicProvider();
  const api = anthropicMessagesApi();
  const shaped = call => (model, context, options = {}) => call(model, context, {
    ...options,
    onPayload: async (payload, model) => shapePayload((await options.onPayload?.(payload, model)) ?? payload)
  });
  return createProvider({
    id: base.id, name: 'Anthropic (Claude subscription)', baseUrl: base.baseUrl,
    auth: { oauth: base.auth.oauth }, models: base.getModels(),
    api: { stream: shaped(api.stream), streamSimple: shaped(api.streamSimple) }
  });
}

// pi-ai's CredentialStore over one file, for the `anthropic` provider only.
// Writes are serialized here and atomic on disk; only this process refreshes.
export function fileCredentials(path) {
  let tail = Promise.resolve();
  const read = async () => {
    try {
      const credential = JSON.parse(await readFile(path, 'utf8'));
      return credential?.type === 'oauth' && typeof credential.access === 'string' && typeof credential.refresh === 'string' ? credential : undefined;
    } catch (error) {
      if (error.code === 'ENOENT') return undefined;
      throw new Error('claude_subscription_unreadable');
    }
  };
  const write = async credential => {
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    const temporary = `${path}.${process.pid}.tmp`;
    await writeFile(temporary, JSON.stringify(credential), { mode: 0o600 });
    await rename(temporary, path);
  };
  const serial = work => { const result = tail.then(work); tail = result.catch(() => {}); return result; };
  return {
    read: async id => id === 'anthropic' ? read() : undefined,
    list: async () => (await read()) ? [{ providerId: 'anthropic', type: 'oauth' }] : [],
    modify: (id, fn) => serial(async () => {
      if (id !== 'anthropic') throw new Error('credential_mutation_disabled');
      const current = await read();
      const next = await fn(current);
      if (next === undefined) return current;
      if (next.type !== 'oauth') throw new Error('claude_subscription_oauth_only');
      await write(next);
      return next;
    }),
    delete: () => { throw new Error('credential_mutation_disabled'); }
  };
}
