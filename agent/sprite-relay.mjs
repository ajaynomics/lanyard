// The entrypoint of a bot's Sprite (Dockerfile.agent). It listens on $PORT and,
// for each connection that opens with the right secret, runs the pi-env daemon
// and copies bytes both ways; agent/sprites-bridge.mjs is the other end.
//
//   first line from the bridge:  AVERY-RELAY <secret> <daemon token>\n
//
// The secret arrives in the Sprite's create-time environment
// (SPRITE_RELAY_SECRET); anything on homeserver's network can reach this port, so
// a connection without it is closed before a daemon starts. Nothing here
// knows about conversations, models or Rails.
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { timingSafeEqual } from 'node:crypto';
import { homedir } from 'node:os';

const secret = Buffer.from(process.env.SPRITE_RELAY_SECRET ?? '');
const daemon = process.env.PI_ENV_DAEMON || '/usr/local/bin/pi-env';
// The platform does not apply the image's ENV, so HOME may be unset.
const home = process.env.HOME || homedir();
const MAX_HELLO = 512;

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
    if (word !== 'AVERY-RELAY' || !given || !matches(given) || !/^[0-9a-f]{16,128}$/.test(token ?? '')) return void socket.destroy();
    const child = spawn(daemon, ['serve', '--token', token], { cwd: home, env: { ...process.env, HOME: home }, stdio: ['pipe', 'pipe', 'inherit'] });
    child.on('error', error => { console.error(`sprite-relay: ${error.message}`); socket.destroy(); });
    child.stdout.pipe(socket);
    socket.pipe(child.stdin);
    const rest = hello.subarray(end + 1);
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
