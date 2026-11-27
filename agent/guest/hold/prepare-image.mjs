// The everyday image includes these files unchanged. The proof derivative
// replaces only the transport that would otherwise need a browser TCP exception.
import { readFileSync, writeFileSync } from 'node:fs';

function patch(file, ...edits) {
  const path = '/opt/agent/' + file;
  let text = readFileSync(path, 'utf8');
  for (const [from, to] of edits) {
    if (typeof from === 'string' ? text.split(from).length !== 2 : !from.test(text))
      throw new Error('cannot prepare hold-proof: ' + file);
    text = text.replace(from, () => to);
  }
  writeFileSync(path, text);
}

patch('entrypoint.sh',
  ['spawn chromium as_browser', '. "$GUEST/hold/boot.sh"\nspawn chromium as_browser'],
  ['PI_DESKTOP_PROFILE_DIR="$PROFILE"', 'NODE_OPTIONS=--import=/opt/agent/hold/cdp-client.mjs PI_DESKTOP_PROFILE_DIR="$PROFILE"']);
patch('cdp.mjs',
  ["server.listen(PORT, '127.0.0.1', () => {", "server.listen('/run/browser/cdp.sock', () => {"],
  ["...chromiumArgs({ restore }), '--remote-debugging-pipe'",
    "...chromiumArgs({ restore }), '--remote-debugging-pipe', '--disable-background-networking', '--disable-component-update', '--disable-sync'"]);
patch('spawner.mjs',
  ['readFileSync, rmSync', 'rmSync, statSync'],
  [/function cdpHeld\(\) \{[^]*?\n\}/, `function cdpHeld() {
    try {
      const socket = statSync('/run/browser/cdp.sock');
      return socket.isSocket() && socket.uid === process.getuid();
    } catch { return false; }
  }`],
  ['env.AGENT_CDP =', "env.NODE_OPTIONS = '--import=/opt/agent/hold/cdp-client.mjs';\n  env.AGENT_CDP ="]);
patch('sprite-relay.mjs', [
  "    if (word === 'AGENT-SCREEN'",
  "    if (word === 'AGENT-HOLD' && token === undefined && !rest.length) return void join(socket, connect('/dev/shm/browser-hold/relay.sock'), rest);\n    if (word === 'AGENT-SCREEN'"
]);
