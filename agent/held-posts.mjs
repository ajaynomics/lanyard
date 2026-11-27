import { setTimeout as pause } from 'node:timers/promises';
import { decisionKey, LineSocket, signedDecision, validTicket } from './guest/hold/wire.mjs';

// Runs only when a proof caller opens a hold relay explicitly. It owns no
// body and has no way to send a request itself. A lost Rails response is not
// retried: an Allow may already have been consumed there.
export class HeldPosts {
  constructor({ scope, relaySecret, approval, recheckMs = 500 }) {
    if (!/^[a-f0-9]{64}$/.test(relaySecret)) throw new Error('invalid hold relay secret');
    this.scope = scope;
    this.relaySecret = relaySecret;
    this.key = decisionKey(relaySecret);
    this.approval = approval;
    this.recheckMs = recheckMs;
  }

  async listen(socket, stop) {
    const gone = new AbortController();
    socket.once('close', () => gone.abort());
    const signal = stop ? AbortSignal.any([stop, gone.signal]) : gone.signal;
    const channel = new LineSocket(socket);
    try {
      const ready = channel.next(AbortSignal.any([signal, AbortSignal.timeout(5000)]));
      socket.write(`AGENT-HOLD ${this.relaySecret}\n`);
      if ((await ready)?.status !== 'ready') return;
      while (!signal.aborted) {
        const ticket = await channel.next(signal);
        if (!validTicket(ticket)) return;
        const wait = ticket.expiresAt - Date.now();
        if (wait <= 0 || wait > 120_000) return;
        const bounded = AbortSignal.any([signal, AbortSignal.timeout(wait)]);
        const request = { ...this.scope, held_post: ticket };
        const answer = await this.#wait(request, bounded);
        if (answer !== 'allow') void this.#cancel(request);
        if (!signal.aborted) channel.send(signedDecision(this.key, ticket, bounded.aborted ? 'deny' : answer));
      }
    } finally { channel.close(); }
  }

  async #wait(request, signal) {
    try {
      const opened = await this.approval({ ...request, operation: 'open' }, signal);
      if (opened?.status !== 'waiting') return 'deny';
      for (;;) {
        await pause(this.recheckMs, null, { signal });
        const answer = await this.approval({ ...request, operation: 'answer' }, signal);
        if (answer?.status !== 'waiting') return answer?.status === 'allow' && !signal.aborted ? 'allow' : 'deny';
      }
    } catch { return 'deny'; }
  }

  async #cancel(request) {
    try { await this.approval({ ...request, operation: 'cancel' }, AbortSignal.timeout(2000)); } catch {}
  }
}
