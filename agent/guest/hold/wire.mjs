import { createHmac, timingSafeEqual } from 'node:crypto';

export const MAX_FRAME = 128 * 1024;
export const HOLD_MS = 90_000;
export const MUTATIONS = new Set(['POST', 'PUT', 'PATCH', 'DELETE']);
const hex = (text, length) => typeof text === 'string' && text.length === length && /^[a-f0-9]+$/.test(text);
const binding = ticket => [ticket.id, ticket.site, ticket.method, ticket.targetDigest, ticket.digest, ticket.expiresAt];
const mac = (key, ticket, answer) => createHmac('sha256', key)
  .update(JSON.stringify(['browser-hold-v1', ...binding(ticket), answer])).digest('hex');
export const decisionKey = relaySecret => createHmac('sha256', relaySecret).update('browser hold decision v1').digest();

export function validTicket(ticket) {
  return ticket && hex(ticket.id, 48) && hex(ticket.targetDigest, 64) && hex(ticket.digest, 64) &&
    MUTATIONS.has(ticket.method) && typeof ticket.site === 'string' && ticket.site.startsWith('https://') &&
    typeof ticket.path === 'string' && ticket.path.startsWith('/') && Number.isSafeInteger(ticket.expiresAt) &&
    Array.isArray(ticket.fields) && ticket.fields.every(row => Array.isArray(row) && row.length === 2 &&
      row.every(text => typeof text === 'string'));
}

export function signedDecision(key, ticket, answer) {
  return { binding: binding(ticket), answer, mac: mac(key, ticket, answer) };
}

export function allows(key, ticket, reply) {
  return reply?.answer === 'allow' && hex(reply.mac, 64) &&
    JSON.stringify(reply.binding) === JSON.stringify(binding(ticket)) &&
    timingSafeEqual(Buffer.from(reply.mac, 'hex'), Buffer.from(mac(key, ticket, 'allow'), 'hex'));
}

// The protocol has one outstanding frame per connection. Extra bytes are
// ambiguous (including two decisions in one write) and close the connection.
export class LineSocket {
  #waiting;
  #parts = [];
  #size = 0;
  #closeReason;
  constructor(socket) {
    this.socket = socket;
    socket.on('data', chunk => this.#read(chunk));
    socket.on('end', () => this.close('peer ended'));
    socket.on('error', () => this.close('socket error'));
    socket.on('close', () => {
      this.#closeReason ??= 'socket closed';
      this.#settle(null);
    });
  }

  get closeReason() { return this.#closeReason; }

  next(signal) {
    if (this.socket.destroyed || this.#waiting || signal?.aborted) return Promise.resolve(null);
    return new Promise(resolve => {
      const abort = () => {
        this.close(signal.reason?.name === 'TimeoutError' ? 'read deadline' : 'read cancelled');
        this.#settle(null);
      };
      signal?.addEventListener('abort', abort, { once: true });
      this.#waiting = value => {
        signal?.removeEventListener('abort', abort);
        resolve(value);
      };
    });
  }

  send(data) {
    const line = JSON.stringify(data) + '\n';
    if (Buffer.byteLength(line) > MAX_FRAME || this.socket.destroyed) throw new Error('hold channel unavailable');
    this.socket.write(line);
  }

  close(reason = 'local close') {
    this.#closeReason ??= reason;
    this.socket.destroy();
  }

  #read(chunk) {
    this.#size += chunk.length;
    const end = chunk.indexOf(10);
    if (!this.#waiting) return this.close('unexpected bytes without a read');
    if (this.#size > MAX_FRAME) return this.close('oversized frame');
    if (end >= 0 && end !== chunk.length - 1) return this.close('extra bytes after frame');
    this.#parts.push(chunk);
    if (end < 0) return;
    let result;
    try { result = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(this.#parts))); }
    catch { return this.close('invalid frame'); }
    this.#settle(result);
  }

  #settle(data) {
    const waiting = this.#waiting;
    this.#parts = [];
    this.#size = 0;
    this.#waiting = undefined;
    waiting?.(data);
  }
}
