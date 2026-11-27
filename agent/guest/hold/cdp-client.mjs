// Proof-only: keep CDP on a private Unix socket without giving Chromium's
// UID an exception to the IP firewall. Site traffic never uses this adapter.
import { request } from 'node:http';
import { connect } from 'node:net';
import { Readable } from 'node:stream';
import WebSocket from 'ws';

const socketPath = '/run/browser/cdp.sock';
const isCdp = url => url.hostname === '127.0.0.1' && url.port === '9222';
const fetch = globalThis.fetch;
const BrowserSocket = globalThis.WebSocket;

globalThis.fetch = (input, options) => {
  const url = new URL(input);
  if (!isCdp(url)) return fetch(input, options);
  return new Promise((resolve, reject) => {
    const call = request({ socketPath, path: url.pathname + url.search, method: options?.method, signal: options?.signal }, response => {
      resolve(new Response(Readable.toWeb(response), { status: response.statusCode, headers: response.headers }));
    });
    call.on('error', reject);
    call.end();
  });
};

globalThis.WebSocket = class {
  constructor(address) {
    if (!isCdp(new URL(address))) return new BrowserSocket(address);
    return new WebSocket(address, { createConnection: () => connect(socketPath) });
  }
};
