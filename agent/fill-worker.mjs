// fill.mjs in a worker (fill-socket.mjs): its fetch and WebSocket reach the
// agent's browser only through fillOnly(), and it fills the tab used last,
// the first Chromium lists.
import { workerData } from 'node:worker_threads';
import { fillOnly, workerExit } from './fill-socket.mjs';

const browser = fillOnly(workerData.socketPath);
globalThis.fetch = browser.fetch;
globalThis.WebSocket = browser.WebSocket;
process.env.AGENT_CDP = 'http://localhost';
try {
  const tabs = await (await browser.fetch('http://localhost/json/list')).json();
  process.env.AGENT_TAB = tabs.find(tab => tab.type === 'page')?.id ?? '';
} catch (error) {
  process.exit(workerExit(error));
}
await import('./guest/fill.mjs');
