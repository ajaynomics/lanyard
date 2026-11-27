// Loopback peer for test/proofs/forge_files.rb. No model or wrapper runs.
import './local-only.mjs';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, writeFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { createServer } from '../server.mjs';
import { liveInvocations } from '../live-invocations.mjs';
import { forgeComputer } from './forge-file-computer.mjs';

const lines = createInterface({ input: process.stdin });
const io = lines[Symbol.asyncIterator]();
const input = async () => JSON.parse((await io.next()).value);
const send = value => console.log(JSON.stringify(value));
const { railsUrl, railsToken, sidecarToken, home, scope, sha256 } = await input();
const guest = forgeComputer(home), live = liveInvocations();
const app = await createServer({ modelMode: 'local', storePath: join(home, 'sidecar.sqlite3'), railsUrl, railsToken, sidecarToken },
  { liveInvocations: live, log: () => {} });
try {
  const { port } = await app.listen(0);
  const { id } = await app.runtime.create({ ...scope, requestId: 'forge-seam-test' });
  const call = { ...scope, conversationId: String(id), taskId: '7', callId: 'synthetic-forge', digest: 'd'.repeat(64), tool: 'forge' };
  const never = await fetch(`http://127.0.0.1:${port}/v1/conversations/${id}/files`, { method: 'POST',
    headers: { authorization: `Bearer ${sidecarToken}`, 'content-type': 'application/json' },
    body: JSON.stringify({ ...scope, taskId: call.taskId, callId: call.callId, digest: call.digest,
      forge: { id: 'a'.repeat(32), mode: 'push', bytes: 52428800, sha256 } }) });
  assert.equal(never.status, 403, 'no transfer without live proof');
  assert.equal(guest.metrics.processes, 0);
  live.enter(call, new AbortController().signal, { env: guest.env });
  await mkdir(guest.root);
  const fixture = Buffer.alloc(1024 * 1024, 77);
  for (let i = 0; i < 50; i++) await writeFile(join(guest.root, 'push.bundle'), fixture, { flag: i === 0 ? 'wx' : 'a' });
  send({ port, id });
  const stage = (await input()).check;
  const path = join(guest.root, `${stage}.bundle`);
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  assert.equal(hash.digest('hex'), stage);
  assert.equal((await stat(path)).size, 52428800);
  assert.equal((await stat(path)).mode & 0o777, 0o444);
  send(guest.metrics);
  await input();
  send(guest.metrics);
} finally {
  await app.close();
  guest.close();
  lines.close();
  process.stdin.pause();
}
