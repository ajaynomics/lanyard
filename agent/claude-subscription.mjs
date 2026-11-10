// Claude through a Claude subscription, not an API key, as Pi does after
// `/login anthropic` with the pi-anthropic-auth extension.
//
// The application owns its own grant: the owner signs in once from Rails'
// owner console, which calls this sidecar's /v1/subscriptions/anthropic
// routes (server.mjs). subscription-credentials.mjs keeps the grant encrypted with SUBSCRIPTION_VAULT_KEY in one file beside the store,
// records each exchange and refresh before it is sent, and never replays one
// whose outcome is unknown: the owner reconnects instead.
//
// pi-ai does the rest of the request for an `sk-ant-oat` token: the bearer,
// Claude Code's identity, beta flags and tool names. What it leaves to the
// extension, and so to us, is the billing block: a first system block derived
// from the first user message and the Claude Code version (shapePayload). The
// extension also rewrites Pi's own coding-agent prompt, which this sidecar
// never sends.
import { createHash } from 'node:crypto';
import { createProvider } from '@earendil-works/pi-ai/models';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { anthropicMessagesApi } from '@earendil-works/pi-ai/api/anthropic-messages.lazy';
import { DEFAULT_APPLICATION, SubscriptionCredentials, fileStorage } from './subscription-credentials.mjs';
import { anthropicOAuthProtocol } from './anthropic-oauth.mjs';

// pi-ai's own claudeCodeVersion, as the extension pins it. Anthropic
// refuses a model to an older Claude Code with `claude_code_version_too_old`;
// raise this deliberately when that happens.
export const CLAUDE_CODE_VERSION = '2.1.322';
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

// The grant's custody: this install (AGENT_APPLICATION, application and
// principal both), this environment. Another install's key or file is never
// accepted.
export function subscriptionCustody({ file, vaultKey, environment, application = DEFAULT_APPLICATION }) {
  return new SubscriptionCredentials({ storage: fileStorage(file), vaultKey, enabled: true, protocol: anthropicOAuthProtocol(),
    scope: { application, environment, principal: application } });
}

// Pi's Anthropic models and endpoint, authenticated only by the custody
// (never an environment variable), with the billing block on every request.
export function subscriptionProvider() {
  const base = anthropicProvider();
  const api = anthropicMessagesApi();
  const shaped = call => (model, context, options = {}) => call(model, context, {
    ...options,
    onPayload: async (payload, model) => shapePayload((await options.onPayload?.(payload, model)) ?? payload)
  });
  return createProvider({
    id: base.id, name: 'Anthropic (Claude subscription)', baseUrl: base.baseUrl, models: base.getModels(),
    auth: { apiKey: { name: 'Claude subscription', resolve: async ({ credential }) =>
      credential?.key ? { auth: { apiKey: credential.key }, source: 'Claude subscription' } : undefined } },
    api: { stream: shaped(api.stream), streamSimple: shaped(api.streamSimple) }
  });
}
