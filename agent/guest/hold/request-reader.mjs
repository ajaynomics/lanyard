import { createServer } from 'node:http';
import { MUTATIONS } from './wire.mjs';

const LIMIT = 64 * 1024;
const READ_MS = 5_000;
export const HEADER_LIMIT = 16 * 1024;
// Reasons are fixed labels, never parser errors or request data.
export const reportRefusal = reason => console.error(`browser hold: refused: ${reason}`);
export const disconnect = (socket, reason) => { reportRefusal(reason); socket.destroy(); };
export const refuse = (response, reason) => {
  if (reason) reportRefusal(reason);
  response.writeHead(403, { connection: 'close', 'cache-control': 'no-store', 'content-type': 'text/plain' });
  response.end('The browser request was not allowed.\n');
};

class InvalidRequest extends Error {}

function uniqueHeaders(request) {
  const headers = Object.create(null);
  for (let i = 0; i < request.rawHeaders.length; i += 2) {
    const name = request.rawHeaders[i].toLowerCase();
    if (name in headers || !/^[a-z0-9!#$%&'*+.^_`|~-]+$/.test(name)) throw new InvalidRequest('ambiguous header');
    headers[name] = request.rawHeaders[i + 1];
  }
  return headers;
}

export class RequestReader {
  constructor(handle) {
    const accepted = new WeakSet();
    this.server = createServer({ maxHeaderSize: HEADER_LIMIT, insecureHTTPParser: false }, async (input, response) => {
      const { socket } = input;
      if (accepted.has(socket)) return disconnect(socket, 'second request in tunnel');
      accepted.add(socket);
      socket.holdClearDeadline();
      const deadline = setTimeout(() => disconnect(socket, 'HTTP body deadline'), READ_MS);
      let stage = 'HTTP request unreadable';
      const controller = new AbortController();
      socket.once('close', () => controller.abort());
      try {
        const request = await this.read(input, socket.holdAuthority);
        clearTimeout(deadline);
        socket.setTimeout(0);
        stage = 'request handler failed';
        if (!controller.signal.aborted) await handle(request, response, socket.holdAuthority, controller.signal);
        else reportRefusal('browser disconnected');
      } catch (error) {
        reportRefusal(error instanceof InvalidRequest ? error.message : stage);
        if (!socket.destroyed && !response.headersSent) refuse(response);
        else socket.destroy();
      } finally {
        clearTimeout(deadline);
      }
    });
    this.server.on('connect', (_, socket) => disconnect(socket, 'nested CONNECT'));
    this.server.on('upgrade', (_, socket) => {
      reportRefusal('HTTP upgrade');
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
    });
    this.server.on('checkContinue', (_, response) => refuse(response, 'HTTP Expect header'));
    this.server.on('checkExpectation', (_, response) => refuse(response, 'HTTP Expect header'));
    this.server.on('clientError', (_, socket) => disconnect(socket, 'HTTP parser or socket error'));
  }

  accept(socket, authority) {
    socket.holdAuthority = authority;
    const deadline = setTimeout(() => disconnect(socket, 'HTTP header deadline'), READ_MS);
    // Bound even a slow stream of headers. The body has a separate limit.
    socket.holdClearDeadline = () => clearTimeout(deadline);
    socket.once('close', socket.holdClearDeadline);
    this.server.emit('connection', socket);
  }

  async read(input, authority) {
    const { httpVersion, method, url: path } = input;
    const headers = uniqueHeaders(input);
    if (httpVersion !== '1.1' || !/^\/[\x21-\x7e]*$/.test(path) || path.startsWith('//') || /[\\#]/.test(path) ||
        path.length > 8192 || !authority.matches(headers.host) ||
        ['transfer-encoding', 'upgrade', 'expect', 'content-encoding', 'trailer', 'te', 'proxy-authorization'].some(name => name in headers) ||
        (headers.connection && !/^(?:close|keep-alive)$/i.test(headers.connection)))
      throw new InvalidRequest('unsupported request');

    const write = MUTATIONS.has(method);
    if (!write && !['GET', 'HEAD'].includes(method)) throw new InvalidRequest('unsupported method');
    if (headers['content-length'] !== undefined && !/^(0|[1-9][0-9]{0,4})$/.test(headers['content-length']))
      throw new InvalidRequest('unsupported length');
    const length = Number(headers['content-length'] || 0);
    if (length > LIMIT || (!write && length !== 0)) throw new InvalidRequest('unsupported body');
    const supplied = headers['content-type'] ?? '';
    const type = supplied.split(';', 1)[0].trim().toLowerCase();
    if (write && ((length || type) && !/^(?:application\/json|application\/x-www-form-urlencoded)(?:\s*;\s*charset=(?:utf-8|"utf-8"))?$/i.test(supplied)))
      throw new InvalidRequest('unsupported type');
    const chunks = [];
    let total = 0;
    for await (const chunk of input) {
      total += chunk.length;
      if (total > length) throw new InvalidRequest('oversized body');
      chunks.push(chunk);
    }
    if (!input.complete || total !== length) throw new InvalidRequest('incomplete body');
    delete headers.connection;
    delete headers['proxy-connection'];
    delete headers['keep-alive'];
    return { method, path, headers, type, body: Buffer.concat(chunks, total) };
  }
}
