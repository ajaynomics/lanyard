import { Connection, localDaemon } from '@earendil-works/pi-env';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// A Sprite stand-in with the real daemon and guest process, confined to the
// test directory. Translate only argv at the computer boundary.
export function forgeComputer(home) {
  const connection = new Connection({ command: [localDaemon()] });
  const metrics = { processes: 0, sent: 0, received: 0, largestSent: 0, largestReceived: 0 };
  const root = join(home, '.forge');
  return { root, metrics, close: () => connection.close(), env: () => ({ id: 'sprites:forge-test', connection: {
    info: () => connection.info(),
    request(op, message, options) {
      if (op === 'process') {
        metrics.processes++;
        const [python, isolated, , mode, , length, digest] = message.argv;
        return connection.request(op, { ...message, cwd: home,
          argv: [python, isolated, fileURLToPath(new URL('../guest/forge-file.py', import.meta.url)), mode, root, length, digest] },
          { ...options, onEvent(json, payload) {
            if (json.kind === 'output' && json.stream === 'stdout') {
              metrics.received += payload.length;
              metrics.largestReceived = Math.max(metrics.largestReceived, payload.length);
            }
            options.onEvent(json, payload);
          } });
      }
      if (op === 'processWrite') {
        metrics.sent += options.payload.length;
        metrics.largestSent = Math.max(metrics.largestSent, options.payload.length);
      }
      return connection.request(op, message, options);
    }
  } }) };
}
