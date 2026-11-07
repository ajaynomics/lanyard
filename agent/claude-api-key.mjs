// Claude through an Anthropic API key, beside the Claude subscription, never
// instead of it: a provider of its own, `anthropic-api`, so a bot's model
// names which one pays (`anthropic/…` the subscription, `anthropic-api/…`
// the key) and one never silently stands in for the other.
//
// The owner pastes the key into Rails' owner console, which passes it
// straight here and keeps nothing. This sidecar checks it with Anthropic's
// free model list, then seals it with SUBSCRIPTION_VAULT_KEY in the
// subscriptions' file, under a namespace of its own. Only the last four
// characters ever leave, as a hint.
//
// pi-ai sends any key that is not an `sk-ant-oat` token as `x-api-key`, with
// pi's own identity and none of Claude Code's: no billing block, no betas.
import { createProvider } from '@earendil-works/pi-ai/models';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { anthropicMessagesApi } from '@earendil-works/pi-ai/api/anthropic-messages.lazy';
import { fileStorage, seal, unseal } from './subscription-credentials.mjs';

export const API_KEY_PROVIDER = 'anthropic-api';
const MODELS_URL = 'https://api.anthropic.com/v1/models';
const CUSTODY = 'API key custody unavailable; no fallback';

// Any Anthropic key that is not a subscription's own token (`sk-ant-oat`
// access, `sk-ant-ort` refresh): those belong to the sign-in, and pi-ai
// would send an `oat` one as Claude Code. Whether Anthropic accepts the rest
// is Anthropic's answer, not a prefix list here.
export function validApiKey(key) {
  return typeof key === 'string' && /^[\x21-\x7e]{20,512}$/.test(key) && key.startsWith('sk-ant-')
    && !key.startsWith('sk-ant-oat') && !key.startsWith('sk-ant-ort');
}

// Anthropic's free model list answers whether a key is good: 'ok', 'invalid'
// (refused), or 'unverified' (no clear answer, so nothing is kept).
export async function verifyWithAnthropic(key, fetch = globalThis.fetch) {
  try {
    const response = await fetch(MODELS_URL, { method: 'GET', redirect: 'error', signal: AbortSignal.timeout(10000),
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01' } });
    await response.body?.cancel();
    return response.ok ? 'ok' : response.status === 401 || response.status === 403 ? 'invalid' : 'unverified';
  } catch {
    return 'unverified';
  }
}

// One key for this application, environment and principal, sealed in the
// same file as the subscriptions' grants. Each change names the version it
// saw, as theirs do.
export class ApiKeyCredentials {
  #storage; #vaultKey; #namespace; #verify;
  #tail = Promise.resolve();
  constructor({ storage, vaultKey, scope, verify = verifyWithAnthropic }) {
    this.#storage = storage; this.#vaultKey = vaultKey; this.#verify = verify;
    const fields = [scope?.application, scope?.environment, scope?.principal, scope?.provider];
    this.#namespace = fields.every(field => typeof field === 'string' && /^[a-z0-9-]{1,64}$/.test(field))
      ? 'api-key:v1:' + JSON.stringify(fields) : null;
  }
  configured() {
    return this.#namespace !== null && /^[a-f0-9]{64}$/.test(this.#vaultKey ?? '') && typeof this.#storage?.transaction === 'function';
  }
  #run(work) {
    const result = this.#tail.then(work);
    this.#tail = result.then(() => undefined, () => undefined);
    // Storage or crypto failures never carry a record or the key out.
    return result.catch(() => { throw Error(CUSTODY); });
  }
  async #read(tx) {
    const sealed = await tx.get(this.#namespace);
    if (sealed === undefined) return { version: 0, key: null };
    const record = await unseal(this.#vaultKey, this.#namespace, sealed);
    if (!record || !Number.isSafeInteger(record.version) || record.version < 0
      || (record.key !== null && !validApiKey(record.key))) throw Error(CUSTODY);
    return record;
  }
  async #write(tx, record) { await tx.put(this.#namespace, await seal(this.#vaultKey, this.#namespace, record)); }
  #projection(record) {
    return { configured: this.configured(), connected: record.key !== null, version: record.version,
      hint: record.key ? record.key.slice(-4) : null };
  }
  // Inside a transaction: the record, or the 412 when the caller saw another version.
  async #current(tx, expected) {
    const record = await this.#read(tx);
    const conflict = !Number.isSafeInteger(expected) || expected !== record.version
      ? { status: 412, data: { error: 'subscription_changed', ...this.#projection(record) } } : null;
    return { record, conflict };
  }
  #disabled() { return { status: 503, data: { error: 'subscription_not_configured' } }; }
  status() {
    return this.#run(async () => this.#projection(this.configured()
      ? await this.#storage.transaction(tx => this.#read(tx)) : { version: 0, key: null }));
  }
  // Checked with Anthropic before it is kept; the version is checked again
  // after, so a change made meanwhile in another tab wins.
  save(key, expected) {
    return this.#run(async () => {
      if (!this.configured()) return this.#disabled();
      if (!validApiKey(key)) return { status: 422, data: { error: 'invalid_api_key' } };
      const before = await this.#storage.transaction(tx => this.#current(tx, expected));
      if (before.conflict) return before.conflict;
      const verdict = await this.#verify(key);
      if (verdict === 'invalid') return { status: 422, data: { error: 'invalid_api_key' } };
      if (verdict !== 'ok') return { status: 503, data: { error: 'api_key_unverified' } };
      return this.#storage.transaction(async tx => {
        const { record, conflict } = await this.#current(tx, expected);
        if (conflict) return conflict;
        const saved = { version: record.version + 1, key };
        await this.#write(tx, saved);
        return { status: 200, data: this.#projection(saved) };
      });
    });
  }
  remove(expected) {
    return this.#run(async () => {
      if (!this.configured()) return this.#disabled();
      return this.#storage.transaction(async tx => {
        const { record, conflict } = await this.#current(tx, expected);
        if (conflict) return conflict;
        const removed = { version: record.version + 1, key: null };
        await this.#write(tx, removed);
        return { status: 200, data: this.#projection(removed) };
      });
    });
  }
  /** Internal host capability only: NEVER expose over RPC, a tool, model data or status. */
  async key() {
    const record = await this.#run(async () => this.configured() ? this.#storage.transaction(tx => this.#read(tx)) : { key: null });
    if (!record.key) throw Error('the API key is not set');
    return record.key;
  }
}

export function apiKeyCustody({ file, vaultKey, environment, verify }) {
  return new ApiKeyCredentials({ storage: fileStorage(file), vaultKey, verify,
    scope: { application: 'durable-assistants', environment, principal: 'avery', provider: API_KEY_PROVIDER } });
}

// Pi's Anthropic models and endpoint under a provider id of their own, so the
// key's routes never resolve to the subscription's provider. Authenticated
// only by the custody, never an environment variable.
export function apiKeyProvider() {
  const base = anthropicProvider();
  return createProvider({
    id: API_KEY_PROVIDER, name: 'Anthropic (API key)', baseUrl: base.baseUrl,
    models: base.getModels().map(model => ({ ...model, provider: API_KEY_PROVIDER })),
    auth: { apiKey: { name: 'Claude API key', resolve: async ({ credential }) =>
      credential?.key ? { auth: { apiKey: credential.key }, source: 'Claude API key' } : undefined } },
    api: anthropicMessagesApi()
  });
}
