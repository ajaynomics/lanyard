// The desktop tool on an agent's Sprite: one action through the desktop
// control server (agent/guest/server.js, POST /action on 127.0.0.1:8090),
// with the bearer the entrypoint made at boot (~/.desk-token). Prints the
// server's JSON answer on one line: an observed screenshot (base64 PNG), or
// {ok: false, error, outcome_unknown?}. Exits 3 when the server is not there.
//
//   node /opt/avery/desk.mjs '<action JSON>'
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';

const action = process.argv[2];
try {
  const token = (await readFile(join(process.env.HOME || homedir(), '.desk-token'), 'utf8')).trim();
  // A wait may take 20 seconds and an action 15, then the screenshot.
  const answer = await fetch('http://127.0.0.1:8090/action', { method: 'POST', body: action, signal: AbortSignal.timeout(60000),
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } });
  process.stdout.write(JSON.stringify(await answer.json()) + '\n');
} catch (error) {
  process.stderr.write(`The screen is not running (${error.message}).\n`);
  process.exit(3);
}
