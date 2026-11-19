// The relay of an agent's Sprite (Dockerfile.agent; agent/guest/entrypoint.sh
// starts it as the `relay` user). It listens on $PORT and, for each connection
// that opens with the right secret, copies bytes both ways to the screen's
// websockify on the guest's loopback, to the desktop control server, or to the
// agent's spawner (agent/guest/spawner.mjs), which starts the pi-env daemon or
// a command connector as `agent`; agent/sprites-bridge.mjs is the other end.
//
//   first line from the bridge:  AGENT-RELAY <secret> <daemon token>\n
//                           or:  AGENT-SCREEN <secret>\n
//                           or:  AGENT-COMMAND <secret>\n{command, args, env, cwd}\n
//                           or:  AGENT-DESK <secret>\n<action JSON>\n
//                           or:  AGENT-BROWSER <secret>\n{command: 'node', args: [script, ...], env}\n
//
// AGENT-DESK posts one desktop action to the control server
// (agent/guest/server.js, run as `desk`) with its bearer, which only this
// process and that server hold, and answers with the server's JSON and closes.
// The agent drives its screen only through the sidecar, never with the bearer.
//
// AGENT-BROWSER answers `AGENT-BROWSER\n` at once, so the sidecar knows this
// relay has it, then passes the connection, without the secret, to the
// spawner that runs as `browser` (agent/guest/spawner.mjs, script-only),
// which runs one of the screen's scripts (visit.mjs, fill.mjs, pay.mjs,
// answer.mjs, upload.mjs) against the screen's DevTools, which `agent` cannot reach (#60).
// A sign-in or card in its entry so never passes through a process of the
// agent's. A relay made before it closes the connection unanswered.
//
// The secret arrives in the Sprite's create-time environment
// (SPRITE_RELAY_SECRET); anything on the platform's network, and the agent's
// own shell, can reach this port, so a connection without it is closed before
// anything starts. This process runs as neither root nor `agent`: the agent
// cannot read its environment or memory, and it starts nothing itself. Nothing
// here knows about conversations, models or Rails.
import { createServer, connect } from 'node:net';
import { request } from 'node:http';
import { timingSafeEqual } from 'node:crypto';

// It reads what anyone on the network sends; never as root.
// SPRITE_TEST_AS_ROOT: the sidecar's tests, when CI runs them as root; the
// entrypoint's fixed environment (env -i) never carries it onto a Sprite.
if (process.getuid?.() === 0 && process.env.SPRITE_TEST_AS_ROOT !== '1') { console.error('sprite-relay: refusing to run as root'); process.exit(1); }
const secret = Buffer.from(process.env.SPRITE_RELAY_SECRET ?? '');
const deskToken = process.env.PI_DESKTOP_TOKEN ?? '';
const spawner = process.env.SPRITE_SPAWN_SOCKET || '/run/spawn/agent.sock';
const browser = process.env.SPRITE_BROWSER_SOCKET || '/run/browser-spawn/browser.sock';
const MAX_HELLO = 512;
const MAX_ACTION = 64 * 1024;
// websockify, in front of the screen's VNC server, and the desktop control server.
const SCREEN_PORT = Number(process.env.SPRITE_SCREEN_PORT || 6080);
const DESK_PORT = Number(process.env.SPRITE_DESK_PORT || 8090);

if (secret.length < 32) { console.error('sprite-relay: SPRITE_RELAY_SECRET is not set'); process.exit(1); }

const matches = given => {
  const bytes = Buffer.from(given);
  return bytes.length === secret.length && timingSafeEqual(bytes, secret);
};

// Bytes both ways between the bridge's socket and another, after `first`.
function join(socket, other, first) {
  socket.pause();
  other.on('connect', () => { if (first.length) other.write(first); socket.pipe(other).pipe(socket); });
  other.on('error', () => socket.destroy());
  socket.on('close', () => other.destroy());
  // End, not destroy: a command's closing line may still be on its way.
  other.on('close', () => socket.end());
}

// One action: the line after the hello, posted as it came; the answer, as it came.
function desk(socket, first) {
  let line = first;
  const refuse = error => socket.end(`${JSON.stringify({ ok: false, error })}\n`);
  const onAction = chunk => {
    line = Buffer.concat([line, chunk]);
    const end = line.indexOf('\n');
    if (end < 0) return void (line.length > MAX_ACTION && socket.destroy());
    socket.off('data', onAction);
    if (!deskToken) return refuse('The screen is not running.');
    const post = request({ host: '127.0.0.1', port: DESK_PORT, path: '/action', method: 'POST',
      headers: { Authorization: `Bearer ${deskToken}`, 'Content-Type': 'application/json' } }, answer => {
      answer.pipe(socket);
      answer.on('error', () => socket.destroy());
    });
    // A wait may take 20 seconds and an action 15, then the screenshot.
    post.setTimeout(60000, () => post.destroy(new Error('timeout')));
    post.on('error', () => refuse('The screen is not running.'));
    socket.on('close', () => post.destroy());
    post.end(line.subarray(0, end));
  };
  socket.on('data', onAction);
  onAction(Buffer.alloc(0));
}

const server = createServer(socket => {
  let hello = Buffer.alloc(0);
  socket.setTimeout(10000, () => socket.destroy());
  const onHello = chunk => {
    hello = Buffer.concat([hello, chunk]);
    const end = hello.indexOf('\n');
    if (end < 0) return void (hello.length > MAX_HELLO && socket.destroy());
    socket.off('data', onHello);
    socket.setTimeout(0);
    const [word, given, token, extra] = hello.subarray(0, end).toString('utf8').split(' ');
    const rest = hello.subarray(end + 1);
    if (!given || !matches(given) || extra !== undefined) return void socket.destroy();
    if (word === 'AGENT-SCREEN' && token === undefined) return void join(socket, connect(SCREEN_PORT, '127.0.0.1'), rest);
    if (word === 'AGENT-DESK' && token === undefined) return void desk(socket, rest);
    if (word === 'AGENT-BROWSER' && token === undefined) {
      socket.write('AGENT-BROWSER\n');
      return void join(socket, connect(browser), Buffer.concat([Buffer.from('AGENT-COMMAND\n'), rest]));
    }
    // The spawner gets the hello without the secret.
    if (word === 'AGENT-COMMAND' && token === undefined)
      return void join(socket, connect(spawner), Buffer.concat([Buffer.from('AGENT-COMMAND\n'), rest]));
    if (word === 'AGENT-RELAY' && /^[0-9a-f]{16,128}$/.test(token ?? ''))
      return void join(socket, connect(spawner), Buffer.concat([Buffer.from(`AGENT-RELAY ${token}\n`), rest]));
    socket.destroy();
  };
  socket.on('data', onHello);
  socket.on('error', () => {});
});

server.listen(Number(process.env.PORT ?? 8080), '0.0.0.0', () => console.log(`sprite-relay listening on ${server.address().port}`));
