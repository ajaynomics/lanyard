import { allows, LineSocket } from './wire.mjs';

function refuse(reason) {
  console.error(`browser hold: refused: ${reason}`);
  return false;
}

export class Decision {
  #channel;
  #queued = 0;
  #tail = Promise.resolve();

  constructor(key) { this.key = key; }

  attach(socket) {
    if (this.#channel && !this.#channel.socket.destroyed) {
      console.error('browser hold: control closed: another relay is attached');
      return void socket.destroy();
    }
    const channel = this.#channel = new LineSocket(socket);
    socket.on('close', () => console.error(`browser hold: control closed: ${channel.closeReason}`));
    channel.send({ status: 'ready' });
  }

  async wait(ticket, signal) {
    const channel = this.#channel;
    if (!channel || channel.socket.destroyed) return refuse('control unavailable');
    if (signal.aborted) return refuse('browser disconnected');
    if (this.#queued >= 32) return refuse('decision queue full');
    this.#queued++;
    // A relay handles one card at a time. Waiting requests keep their own
    // deadline and cannot move onto a replacement relay.
    const turn = this.#tail.then(() => this.#next(channel, ticket, signal));
    this.#tail = turn;
    try { return await turn; } finally { this.#queued--; }
  }

  async #next(channel, ticket, signal) {
    const remaining = ticket.expiresAt - Date.now();
    if (channel.socket.destroyed) return refuse('control unavailable');
    if (remaining <= 0) return refuse('decision expired');
    if (signal.aborted) return refuse('browser disconnected');
    try {
      const bound = AbortSignal.any([signal, AbortSignal.timeout(remaining)]);
      const answer = channel.next(bound);
      channel.send(ticket);
      const reply = await answer;
      if (signal.aborted) return refuse('browser disconnected');
      if (bound.aborted || Date.now() >= ticket.expiresAt) return refuse('decision expired');
      if (channel.socket.destroyed) return refuse('control unavailable');
      return allows(this.key, ticket, reply) || refuse('no valid allow');
    } catch {
      channel.close('decision exchange failed');
      return refuse('decision exchange failed');
    }
  }
}
