import { request } from 'node:https';
import { pipeline } from 'node:stream/promises';

export class Upstream {
  async send(authority, held, response, signal) {
    signal.throwIfAborted();
    const limit = AbortSignal.any([signal, AbortSignal.timeout(30_000)]);
    const reply = await new Promise((resolve, reject) => {
      const outbound = request({ hostname: authority.host, port: 443, path: held.path, method: held.method,
        headers: { ...held.headers, connection: 'close' }, rejectUnauthorized: true, agent: false,
        ALPNProtocols: ['http/1.1'], autoSelectFamily: false, signal: limit }, resolve);
      outbound.on('error', reject);
      outbound.end(held.body);
    });
    const headers = { ...reply.headers, connection: 'close' };
    for (const name of (reply.headers.connection ?? '').split(',')) delete headers[name.trim().toLowerCase()];
    for (const name of ['keep-alive', 'proxy-connection', 'proxy-authenticate', 'te', 'trailer', 'transfer-encoding', 'upgrade'])
      delete headers[name];
    response.writeHead(reply.statusCode, { ...headers, connection: 'close' });
    await pipeline(reply, response, { signal: limit });
  }
}
