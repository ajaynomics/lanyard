// Custody of a subscription grant (Claude's, ChatGPT's), ported from an
// earlier implementation. Changes here: the storage is
// fileStorage below (one encrypted file beside the sidecar's store) rather
// than a Durable Object's transactional storage, and the protocol owns what
// differs between providers: what a valid grant looks like (validate,
// readable) and how the owner's pasted completion reads (parse).
import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const UNAVAILABLE = 'Subscription connection unavailable; reconnect required; no fallback';
const CUSTODY = 'Subscription custody unavailable; no fallback';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const FAILURES = new Set([null, 'exchange_uncertain', 'refresh_uncertain', 'access_rejected']);
const empty = () => ({ version: 0, credential: null, pending: null, operation: null, failure: null });
const encode = bytes => btoa(String.fromCharCode(...bytes));
const decode = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');

// AES-GCM under the vault key, bound to the record's namespace, so a record
// copied to another namespace (another provider, environment or kind of
// credential) never opens. Shared by every custody in the file.
const importKey = vaultKey => crypto.subtle.importKey('raw', Uint8Array.from(vaultKey.match(/../g), b => parseInt(b, 16)),
  'AES-GCM', false, ['encrypt', 'decrypt']);
export async function seal(vaultKey, namespace, record) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: encoder.encode(namespace) },
    await importKey(vaultKey), encoder.encode(JSON.stringify(record)));
  return { format: 1, iv: encode(iv), ciphertext: encode(new Uint8Array(ciphertext)) };
}
export async function unseal(vaultKey, namespace, sealed) {
  if (!sealed || sealed.format !== 1 || typeof sealed.iv !== 'string' || sealed.iv.length !== 16
    || typeof sealed.ciphertext !== 'string' || sealed.ciphertext.length > 65536) throw Error(CUSTODY);
  const bytes = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: decode(sealed.iv), additionalData: encoder.encode(namespace) },
    await importKey(vaultKey), decode(sealed.ciphertext));
  return JSON.parse(decoder.decode(bytes));
}

/** Exact, code-owned tuple: no defaults, trimming, aliases or caller-selected namespace.
 * The host MUST authenticate/authorise the principal separately and must not accept
 * this tuple from start/finish/model requests. Each application supplies its own key.
 * `provider` keeps a second provider's grant apart from the first in the same
 * storage; the Claude grant predates it and keeps its three-part namespace, so
 * a record sealed before it still opens.
 */
function namespace(scope) {
  const keys = scope ? Object.keys(scope).sort().join(',') : '';
  const fields = keys === 'application,environment,principal' ? ['application', 'environment', 'principal']
    : keys === 'application,environment,principal,provider' ? ['application', 'environment', 'principal', 'provider'] : null;
  if (!fields || !fields.every(k => typeof scope[k] === 'string'
      && scope[k].length > 0 && scope[k].length <= 128 && scope[k].trim() === scope[k]
      && !/[\u0000-\u001f\u007f]/.test(scope[k]))) return null;
  return 'subscription:oauth:v1:' + JSON.stringify(fields.map(k => scope[k]));
}

/**
 * Native storage must provide durable, atomic transaction(async tx => ...), with
 * tx.get/put. Failed transactions must not commit. No emulated get/put CAS.
 * A successor owner may invalidate an interrupted reservation; an old continuation
 * can never commit over that successor (reservation compare+write is transactional).
 * storage/protocol/clock/scope/key are trusted server dependencies, not request data.
 * No token-import API. Only successful OAuth exchanges populate credentials.
 */
export class SubscriptionCredentials {
  #storage; #vaultKey; #protocol; #now; #namespace; #enabled;
  #tail = Promise.resolve();
  constructor({ storage, vaultKey, enabled = false, protocol, scope, now = Date.now }) {
    this.#storage = storage; this.#vaultKey = vaultKey; this.#protocol = protocol;
    this.#namespace = namespace(scope); this.#now = now; this.#enabled = enabled === true;
  }
  configured() {
    return this.#enabled && this.#namespace !== null && /^[a-f0-9]{64}$/.test(this.#vaultKey ?? '')
      && typeof this.#storage?.transaction === 'function'
      && ['authorize', 'exchange', 'refresh', 'parse', 'validate', 'readable'].every(k => typeof this.#protocol?.[k] === 'function');
  }
  #run(work) {
    const result = this.#tail.then(work);
    this.#tail = result.then(() => undefined, () => undefined);
    // Storage/crypto failures must not leak encrypted/plain records or provider errors.
    return result.catch(() => { throw Error(CUSTODY); });
  }
  async #save(tx, record) {
    if (!this.configured()) throw Error(UNAVAILABLE);
    await tx.put(this.#namespace, await seal(this.#vaultKey, this.#namespace, record));
  }
  async #read(tx) {
    const sealed = await tx.get(this.#namespace);
    if (sealed === undefined) return empty();
    if (!this.configured()) throw Error(UNAVAILABLE);
    const record = await unseal(this.#vaultKey, this.#namespace, sealed);
    if (!record || !Number.isSafeInteger(record.version) || record.version < 0
      || !FAILURES.has(record.failure) || ![null, 'exchange', 'refresh'].includes(record.operation)) throw Error(CUSTODY);
    // Expired tokens may be loaded for refresh, but unbounded expiry is never accepted.
    if (record.credential !== null && !this.#protocol.readable(record.credential, this.#now())) throw Error(CUSTODY);
    if (record.pending !== null) {
      const p = record.pending;
      if (!p || !UUID.test(p.id) || !/^[a-f0-9]{64}$/.test(p.state) || !/^[a-f0-9]{64}$/.test(p.verifier)
        || !Number.isSafeInteger(p.expires)) throw Error(CUSTODY);
    }
    return record;
  }
  async #load(tx) {
    const record = await this.#read(tx);
    if (record.operation) {
      // The previous owner may have dispatched, rotated, or lost a commit. Never replay.
      record.failure = record.operation + '_uncertain';
      record.credential = null; record.pending = null; record.operation = null; record.version++;
      await this.#save(tx, record);
    }
    return record;
  }
  #projection(record) {
    return { configured: this.configured(), connected: !!record.credential && !record.failure && !record.operation && !record.pending,
      version: record.version, expiresAt: record.credential ? new Date(record.credential.expires).toISOString() : null,
      reconnectRequired: !!record.failure, failure: record.failure,
      pending: record.pending ? { id: record.pending.id, expiresAt: new Date(record.pending.expires).toISOString() } : null,
      credentialSource: 'application-owned-oauth', secretsExposed: false, fallback: false };
  }
  #conflict(record, expected) {
    return !Number.isSafeInteger(expected) || expected !== record.version
      ? { status: 412, data: { error: 'subscription_changed', ...this.#projection(record) } } : null;
  }
  #disabled() { return { status: 503, data: { error: 'subscription_not_configured' } }; }
  status() {
    return this.#run(async () => this.#projection(this.configured()
      ? await this.#storage.transaction(tx => this.#load(tx)) : empty()));
  }
  start(expected) {
    return this.#run(async () => {
      if (!this.configured()) return this.#disabled();
      return this.#storage.transaction(async tx => {
        const record = await this.#load(tx), conflict = this.#conflict(record, expected);
        if (conflict) return conflict;
        const verifier = hex(crypto.getRandomValues(new Uint8Array(32)));
        const state = hex(crypto.getRandomValues(new Uint8Array(32)));
        const challenge = encode(new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(verifier))))
          .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
        const authorizationUrl = this.#protocol.authorize({ state, challenge });
        record.pending = { id: crypto.randomUUID(), verifier, state, expires: this.#now() + 10 * 60 * 1000 };
        record.version++;
        await this.#save(tx, record);
        // This one-time owner response is sensitive; never include it in routine status/logs/history.
        return { status: 200, data: { ...this.#projection(record), authorizationUrl } };
      });
    });
  }
  finish(input, expected) {
    return this.#run(async () => {
      if (!this.configured()) return this.#disabled();
      const reservation = await this.#storage.transaction(async tx => {
        const record = await this.#load(tx), conflict = this.#conflict(record, expected);
        if (conflict) return { response: conflict };
        const pending = record.pending;
        const pasted = this.#protocol.parse(input?.code);
        if (!pending || input?.id !== pending.id || pending.expires <= this.#now()
          || !pasted || typeof pasted.code !== 'string' || !pasted.code || pasted.code.length > 4096 || pasted.state !== pending.state)
          return { response: { status: 400, data: { error: 'invalid_or_expired_oauth_completion' } } };
        record.pending = null; record.credential = null; record.failure = null;
        record.operation = 'exchange'; record.version++;
        await this.#save(tx, record); // Durable one-use reservation BEFORE exchange.
        return { version: record.version, code: pasted.code, pending };
      });
      if (reservation.response) return reservation.response;
      try {
        const { code, pending, version } = reservation;
        const credential = this.#protocol.validate(await this.#protocol.exchange({ code, state: pending.state,
          verifier: pending.verifier }), this.#now());
        const committed = await this.#commit(version, 'exchange', credential);
        return committed ? { status: 200, data: this.#projection(committed) }
          : { status: 412, data: { error: 'oauth_operation_superseded' } };
      } catch {
        const current = await this.#uncertain(reservation.version, 'exchange');
        return { status: 503, data: { error: 'oauth_outcome_unconfirmed', ...this.#projection(current) } };
      }
    });
  }
  async #commit(version, operation, credential) {
    return this.#storage.transaction(async tx => {
      const current = await this.#read(tx);
      if (current.version !== version || current.operation !== operation) return null;
      current.credential = credential; current.pending = null; current.operation = null; current.failure = null; current.version++;
      await this.#save(tx, current); // Persist rotated tokens before releasing access.
      return current;
    });
  }
  async #uncertain(version, operation) {
    return this.#storage.transaction(async tx => {
      const current = await this.#read(tx);
      if (current.version === version && current.operation === operation) {
        current.credential = null; current.pending = null; current.operation = null;
        current.failure = operation + '_uncertain'; current.version++;
        await this.#save(tx, current);
      }
      return current;
    });
  }
  disconnect(expected) {
    return this.#run(async () => {
      if (!this.configured()) return this.#disabled();
      return this.#storage.transaction(async tx => {
        const record = await this.#load(tx), conflict = this.#conflict(record, expected);
        if (conflict) return conflict;
        const cleared = { ...empty(), version: record.version + 1 };
        await this.#save(tx, cleared);
        return { status: 200, data: { ...this.#projection(cleared), providerRevoked: false } };
      });
    });
  }
  /** Internal host capability only: NEVER expose over RPC, a tool, model data or status. */
  accessToken() {
    return this.#run(async () => {
      if (!this.configured()) throw Error(UNAVAILABLE);
      const reservation = await this.#storage.transaction(async tx => {
        const record = await this.#load(tx);
        if (!record.credential || record.failure || record.pending) return { unavailable: true };
        if (record.credential.expires > this.#now() + 5 * 60 * 1000) return { access: record.credential.access };
        const refresh = record.credential.refresh;
        record.credential = null; record.operation = 'refresh'; record.version++;
        await this.#save(tx, record);
        return { version: record.version, refresh };
      });
      if (reservation.unavailable) throw Error(UNAVAILABLE);
      if (reservation.access) return reservation.access;
      try {
        const credential = this.#protocol.validate(await this.#protocol.refresh(reservation.refresh), this.#now());
        const committed = await this.#commit(reservation.version, 'refresh', credential);
        if (!committed) throw Error(UNAVAILABLE);
        return credential.access;
      } catch {
        await this.#uncertain(reservation.version, 'refresh');
        throw Error(UNAVAILABLE);
      }
    });
  }
}

// Transactions per file, across every custody that opens it: two grants may
// share one file, and each class instance serializes only its own work.
const fileTails = new Map();

// The storage SubscriptionCredentials needs: transaction(async tx => ...) with
// tx.get/put, failing whole. One JSON file holding sealed records only (the
// class encrypts before put), replaced atomically. One sidecar owns its store
// (ownership.mjs), and transactions on one file run one at a time.
// The install a grant belongs to when AGENT_APPLICATION names none.
export const DEFAULT_APPLICATION = 'durable-assistants';

export function fileStorage(path) {
  const read = async () => {
    try { return JSON.parse(await readFile(path, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return {}; throw error; }
  };
  const transaction = async work => {
    const records = await read();
    let changed = false;
    const result = await work({ get: async key => records[key], put: async (key, value) => { records[key] = value; changed = true; } });
    if (changed) {
      await mkdir(dirname(path), { recursive: true, mode: 0o700 });
      const temporary = `${path}.${process.pid}.tmp`;
      await writeFile(temporary, JSON.stringify(records), { mode: 0o600 });
      await rename(temporary, path);
    }
    return result;
  };
  return {
    transaction(work) {
      const result = (fileTails.get(path) ?? Promise.resolve()).then(() => transaction(work));
      const tail = result.then(() => undefined, () => undefined);
      fileTails.set(path, tail);
      tail.then(() => { if (fileTails.get(path) === tail) fileTails.delete(path); });
      return result;
    }
  };
}
