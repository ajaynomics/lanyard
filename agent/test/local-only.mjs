import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
const local = host => ['127.0.0.1', '::1', 'localhost', '[::1]'].includes(host);
// Every non-loopback attempt is counted before it is refused, so a test can
// prove zero remote requests instead of inferring it from silence.
const COUNTER = Symbol.for('omakase.test.nonLocalAttempts');
globalThis[COUNTER] ??= { count: 0, installed: false };
const counter = globalThis[COUNTER];
export const nonLocalAttempts = () => counter.count;
const denied = () => { counter.count++; return new Error('test_nonlocal_transport_denied'); };
if (!counter.installed) {
counter.installed = true;
const originalFetch = globalThis.fetch;
globalThis.fetch = (input, options) => {
  const url = new URL(typeof input === 'string' || input instanceof URL ? input : input.url);
  if (!local(url.hostname)) return Promise.reject(denied());
  return originalFetch(input, options);
};
const connect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  const arg = Array.isArray(args[0]) ? args[0][0] : args[0];
  if (arg && typeof arg === 'object') {
    if (!arg.path && arg.host && !local(arg.host)) throw denied();
  } else if (typeof arg === 'number' && typeof args[1] === 'string' && !local(args[1])) {
    throw denied();
  }
  return connect.apply(this, args);
};
syncBuiltinESMExports();
}
// This protects Node transports used by these tests, not subprocess networking.
// Whole-app shell egress qualification requires the parent's OS-isolated runner.
