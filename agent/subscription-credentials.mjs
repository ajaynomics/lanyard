// Custody of the Claude subscription grant, ported from an earlier app
// src/providers/subscription-credentials.mjs (6bc2819), itself adapted from
// an earlier app f9b801c3. Changes here: the import path, and the storage is
// fileStorage below (one encrypted file beside the sidecar's store) rather
// than a Durable Object's transactional storage.
import { readFile, writeFile, rename, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';
import { MAX_TOKEN_LIFETIME_MS, isSubscriptionAccessToken, validateSubscriptionCredential } from './anthropic-oauth.mjs';

const encoder = new TextEncoder(), decoder = new TextDecoder('utf-8', { fatal: true });
const UNAVAILABLE = 'Subscription connection unavailable; reconnect required; no fallback';
const CUSTODY = 'Subscription custody unavailable; no fallback';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const FAILURES = new Set([null, 'exchange_uncertain', 'refresh_uncertain', 'access_rejected']);
const empty = () => ({ version: 0, credential: null, pending: null, operation: null, failure: null });
const encode = bytes => btoa(String.fromCharCode(...bytes));
const decode = text => Uint8Array.from(atob(text), c => c.charCodeAt(0));
const hex = bytes => Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');

/** Exact, code-owned tuple: no defaults, trimming, aliases or caller-selected namespace.
 * The host MUST authenticate/authorise the principal separately and must not accept
 * this tuple from start/finish/model requests. Each application supplies its own key.
 */
function namespace(scope) {
  if (!scope || Object.keys(scope).sort().join(',') !== 'application,environment,principal'
    || !['application', 'environment', 'principal'].every(k => typeof scope[k] === 'string'
      && scope[k].length > 0 && scope[k].length <= 128 && scope[k].trim() === scope[k]
      && !/[\u0000-\u001f\u007f]/.test(scope[k]))) return null;
  return 'subscription:oauth:v1:' + JSON.stringify([scope.application, scope.environment, scope.principal]);
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
      && ['authorize', 'exchange', 'refresh'].every(k => typeof this.#protocol?.[k] === 'function');
  }
  #run(work) {
    const result = this.#tail.then(work);
    this.#tail = result.then(() => undefined, () => undefined);
    // Storage/crypto failures must not leak encrypted/plain records or provider errors.
    return result.catch(() => { throw Error(CUSTODY); });
  }
  async #key() {
    if (!this.configured()) throw Error(UNAVAILABLE);
    return crypto.subtle.importKey('raw', Uint8Array.from(this.#vaultKey.match(/../g), b => parseInt(b, 16)),
      'AES-GCM', false, ['encrypt', 'decrypt']);
  }
  async #save(tx, record) {
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ciphertext = await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
      additionalData: encoder.encode(this.#namespace) }, await this.#key(), encoder.encode(JSON.stringify(record)));
    await tx.put(this.#namespace, { format: 1, iv: encode(iv), ciphertext: encode(new Uint8Array(ciphertext)) });
  }
  async #read(tx) {
    const sealed = await tx.get(this.#namespace);
    if (sealed === undefined) return empty();
    if (!sealed || sealed.format !== 1 || typeof sealed.iv !== 'string' || sealed.iv.length !== 16
      || typeof sealed.ciphertext !== 'string' || sealed.ciphertext.length > 32768) throw Error(CUSTODY);
    const bytes = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: decode(sealed.iv),
      additionalData: encoder.encode(this.#namespace) }, await this.#key(), decode(sealed.ciphertext));
    const record = JSON.parse(decoder.decode(bytes));
    if (!record || !Number.isSafeInteger(record.version) || record.version < 0
      || !FAILURES.has(record.failure) || ![null, 'exchange', 'refresh'].includes(record.operation)) throw Error(CUSTODY);
    if (record.credential !== null) {
      const c = record.credential;
      // Expired tokens may be loaded for refresh, but unbounded expiry is never accepted.
      if (!c || !Number.isSafeInteger(c.expires) || c.expires < 0 || c.expires > this.#now() + MAX_TOKEN_LIFETIME_MS
        || !isSubscriptionAccessToken(c.access) || typeof c.refresh !== 'string' || !/^sk-ant-ort[!-~]{10,4096}$/.test(c.refresh)) throw Error(CUSTODY);
    }
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
        const pasted = typeof input?.code === 'string' ? input.code.trim().split('#') : [];
        if (!pending || input?.id !== pending.id || pending.expires <= this.#now()
          || pasted.length !== 2 || !pasted[0] || pasted[0].length > 4096 || pasted[1] !== pending.state)
          return { response: { status: 400, data: { error: 'invalid_or_expired_oauth_completion' } } };
        record.pending = null; record.credential = null; record.failure = null;
        record.operation = 'exchange'; record.version++;
        await this.#save(tx, record); // Durable one-use reservation BEFORE exchange.
        return { version: record.version, code: pasted[0], pending };
      });
      if (reservation.response) return reservation.response;
      try {
        const { code, pending, version } = reservation;
        const credential = validateSubscriptionCredential(await this.#protocol.exchange({ code, state: pending.state,
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
  rejectAccessToken(access) {
    return this.#run(async () => {
      if (!this.configured()) return;
      await this.#storage.transaction(async tx => {
        const record = await this.#load(tx);
        if (record.credential?.access !== access) return; // Old requests cannot retire new logins/rotations.
        record.credential = null; record.failure = 'access_rejected'; record.version++;
        await this.#save(tx, record);
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
        const credential = validateSubscriptionCredential(await this.#protocol.refresh(reservation.refresh), this.#now());
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

// The storage SubscriptionCredentials needs: transaction(async tx => ...) with
// tx.get/put, failing whole. One JSON file holding sealed records only (the
// class encrypts before put), replaced atomically. One sidecar owns its store
// (ownership.mjs), and the class serializes its own transactions.
export function fileStorage(path) {
  const read = async () => {
    try { return JSON.parse(await readFile(path, 'utf8')); } catch (error) { if (error.code === 'ENOENT') return {}; throw error; }
  };
  return {
    async transaction(work) {
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
    }
  };
}
