// The relay of an agent's Sprite (Dockerfile.agent; agent/guest/entrypoint.sh
// starts it). It listens on $PORT and, for each connection that opens with
// the right secret, copies bytes both ways to the pi-env daemon it starts, or
// to the screen's websockify on the guest's loopback; agent/sprites-bridge.mjs
// is the other end.
//
//   first line from the bridge:  AVERY-RELAY <secret> <daemon token>\n
//                           or:  AVERY-SCREEN <secret>\n
//
// The secret arrives in the Sprite's create-time environment
// (SPRITE_RELAY_SECRET); anything on homeserver's network can reach this port, so
// a connection without it is closed before a daemon starts. Nothing here
// knows about conversations, models or Rails.
import { createServer, connect } from 'node:net';
import { spawn } from 'node:child_process';
import { timingSafeEqual } from 'node:crypto';
import { homedir } from 'node:os';

const secret = Buffer.from(process.env.SPRITE_RELAY_SECRET ?? '');
const daemon = process.env.PI_ENV_DAEMON || '/usr/local/bin/pi-env';
// The platform does not apply the image's ENV, so HOME may be unset.
const home = process.env.HOME || homedir();
const MAX_HELLO = 512;
// websockify, in front of the screen's VNC server.
const SCREEN_PORT = Number(process.env.SPRITE_SCREEN_PORT || 6080);

if (secret.length < 32) { console.error('sprite-relay: SPRITE_RELAY_SECRET is not set'); process.exit(1); }

const matches = given => {
  const bytes = Buffer.from(given);
  return bytes.length === secret.length && timingSafeEqual(bytes, secret);
};

const server = createServer(socket => {
  let hello = Buffer.alloc(0);
  socket.setTimeout(10000, () => socket.destroy());
  const onHello = chunk => {
    hello = Buffer.concat([hello, chunk]);
    const end = hello.indexOf('\n');
    if (end < 0) return void (hello.length > MAX_HELLO && socket.destroy());
    socket.off('data', onHello);
    socket.setTimeout(0);
    const [word, given, token] = hello.subarray(0, end).toString('utf8').split(' ');
    const rest = hello.subarray(end + 1);
    if (!given || !matches(given)) return void socket.destroy();
    if (word === 'AVERY-SCREEN' && token === undefined) {
      // Hold what follows the hello until websockify answers; pipe resumes it.
      socket.pause();
      const screen = connect(SCREEN_PORT, '127.0.0.1', () => { if (rest.length) screen.write(rest); socket.pipe(screen).pipe(socket); });
      screen.on('error', () => socket.destroy());
      socket.on('error', () => {});
      socket.on('close', () => screen.destroy());
      screen.on('close', () => socket.destroy());
      return;
    }
    if (word !== 'AVERY-RELAY' || !/^[0-9a-f]{16,128}$/.test(token ?? '')) return void socket.destroy();
    const child = spawn(daemon, ['serve', '--token', token], { cwd: home, env: { ...process.env, HOME: home }, stdio: ['pipe', 'pipe', 'inherit'] });
    child.on('error', error => { console.error(`sprite-relay: ${error.message}`); socket.destroy(); });
    child.stdout.pipe(socket);
    socket.pipe(child.stdin);
    if (rest.length) child.stdin.write(rest);
    socket.on('error', () => {});
    child.stdin.on('error', () => {});
    socket.on('close', () => child.exitCode === null && child.kill('SIGKILL'));
    child.on('close', () => socket.end());
  };
  socket.on('data', onHello);
  socket.on('error', () => {});
});

server.listen(Number(process.env.PORT ?? 8080), '0.0.0.0', () => console.log(`sprite-relay listening on ${server.address().port}`));
