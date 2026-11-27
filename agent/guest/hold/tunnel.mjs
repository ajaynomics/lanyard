import { createServer } from 'node:http';
import { isIP } from 'node:net';
import { createServer as createTLS } from 'node:tls';
import { HEADER_LIMIT, disconnect, refuse, reportRefusal } from './request-reader.mjs';

function destination(target) {
  const parsed = /^(\[[0-9a-f:.]+\]|[a-z0-9.-]+):443$/i.exec(target);
  if (!parsed) throw new Error('unsupported authority');
  const literal = parsed[1].toLowerCase();
  const host = literal.startsWith('[') ? literal.slice(1, -1) : literal;
  if (literal.startsWith('[') ? isIP(host) !== 6 :
    !isIP(host) && (!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(host) || host.length > 253))
    throw new Error('invalid host');
  return { host, site: 'https://' + literal, matches: value => typeof value === 'string' &&
    [literal, literal + ':443'].includes(value.toLowerCase()) };
}

export class Tunnel {
  constructor(certificates, reader) {
    const server = this.server = createServer({ maxHeaderSize: HEADER_LIMIT }, (_, response) => refuse(response, 'expected CONNECT'));
    server.maxConnections = 32;
    server.on('drop', () => reportRefusal('tunnel connection limit'));
    server.on('connection', socket => {
      const clock = setTimeout(() => disconnect(socket, 'CONNECT deadline'), 5_000);
      socket.holdClearDeadline = () => clearTimeout(clock);
      socket.once('close', socket.holdClearDeadline);
    });
    server.on('clientError', (_, socket) => disconnect(socket, 'CONNECT parser or socket error'));
    server.on('upgrade', (_, socket) => disconnect(socket, 'proxy upgrade'));
    server.on('connect', async (request, socket, head) => {
      socket.on('error', () => disconnect(socket, 'tunnel socket error'));
      try {
        const authority = destination(request.url);
        if (request.httpVersion !== '1.1' || head.length || !authority.matches(request.headers.host) ||
            request.headersDistinct.host?.length !== 1 || request.headers['content-length'] !== undefined ||
            request.headers['transfer-encoding'] !== undefined) throw new Error('unframed tunnel');
        const pair = await certificates.forSite(authority.host);
        if (socket.destroyed) return;
        const tls = createTLS({ ...pair, minVersion: 'TLSv1.2', ALPNProtocols: ['http/1.1'], handshakeTimeout: 5_000 },
          encrypted => {
            if (encrypted.alpnProtocol && encrypted.alpnProtocol !== 'http/1.1') return disconnect(encrypted, 'unexpected ALPN');
            encrypted.on('error', () => disconnect(encrypted, 'TLS socket error'));
            reader.accept(encrypted, authority);
          });
        tls.on('tlsClientError', (_, wire) => disconnect(wire, 'TLS handshake failed'));
        socket.holdClearDeadline();
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n', () => {
          if (!socket.destroyed) tls.emit('connection', socket);
        });
      } catch {
        reportRefusal('CONNECT validation or setup failed');
        socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      }
    });
  }

  listen(port) { this.server.listen(port, '127.0.0.1'); }
}
