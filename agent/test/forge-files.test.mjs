import assert from 'node:assert/strict';
import http from 'node:http';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, mkdir, readdir, readFile, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { FORGE_CHUNK_BYTES as MiB, forgeFileRequest, transferForgeFile } from '../forge-files.mjs';
import { liveInvocations } from '../live-invocations.mjs';
import { railsCallbacks } from '../server.mjs';
import { forgeComputer } from './forge-file-computer.mjs';

const wanted = Buffer.from('synthetic forge binary\0\xff\x10', 'latin1');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const digest = sha(wanted);
const command = { actorId: '1', workspaceId: '19', taskId: '7', callId: 'call', digest: 'd'.repeat(64) };
const offer = (mode, bytes = wanted.length, sha256 = digest) => ({ id: 'a'.repeat(32), mode, bytes, sha256 });
const call = (mode, bytes, hash) => forgeFileRequest('12', { ...command, forge: offer(mode, bytes, hash) });
const record = (start, metrics, mode) => console.log(`${mode} 52428800 bytes in ${Math.round(performance.now() - start)} ms ${JSON.stringify(metrics)}`);

async function computer(t) {
  const home = await mkdtemp(join(tmpdir(), 'forge-computer-'));
  const guest = forgeComputer(home);
  t.after(async () => { guest.close(); await rm(home, { recursive: true, force: true }); });
  const run = (callbacks, file, signal = new AbortController().signal) => transferForgeFile(callbacks, file, { env: guest.env, signal });
  return { ...guest, home, run };
}

async function callbacks(t, handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  return railsCallbacks({ railsUrl: `http://127.0.0.1:${server.address().port}`, railsToken: 'test transport only' }).forgeFiles;
}

const reply = (bytes, yieldBytes) => ({ download: async () => ({ size: bytes, body: yieldBytes() }) });
const smallDownload = (bytes = wanted) => reply(wanted.length, async function* () { yield bytes; });

test('a 50 MiB download waits for verified publication; never sends a chunk bigger than one MiB to the Sprite', async t => {
  const guest = await computer(t);
  const chunk = Buffer.alloc(MiB, 127);
  const hash = createHash('sha256');
  for (let i = 0; i < 50; i++) hash.update(chunk);
  const digest = hash.digest('hex'), file = call('stage', 50 * MiB, digest);
  const staged = join(guest.root, `${digest}.bundle`);
  let reachedEnd = false;
  const cb = await callbacks(t, async (request, response) => {
    assert.equal(request.url, '/agent/files');
    assert.equal(request.headers['x-forge-mode'], 'stage');
    response.writeHead(200, { 'content-length': 50 * MiB });
    for (let i = 0; i < 49; i++) if (!response.write(chunk)) await once(response, 'drain');
    await assert.rejects(stat(staged), { code: 'ENOENT' });
    reachedEnd = true;
    response.end(chunk);
  });
  const start = performance.now();
  assert.deepEqual(await guest.run(cb, file), { transferred: true });
  record(start, guest.metrics, 'download');
  assert.ok(reachedEnd);
  assert.equal(guest.metrics.sent, 50 * MiB + 1);
  assert.equal(guest.metrics.largestSent, MiB);
  assert.equal((await stat(staged)).mode & 0o777, 0o444);
  assert.equal((await stat(staged)).size, 50 * MiB);
  assert.deepEqual(await readdir(guest.root), [`${digest}.bundle`]);
});

test('a 50 MiB upload is a binary body, checks the fixed file and reads one bounded chunk at a time', async t => {
  const guest = await computer(t);
  const chunk = Buffer.alloc(MiB, 201);
  const hash = createHash('sha256');
  await mkdir(guest.root);
  const path = join(guest.root, 'push.bundle');
  for (let i = 0; i < 50; i++) {
    await writeFile(path, chunk, { flag: i === 0 ? 'wx' : 'a' });
    hash.update(chunk);
  }
  const digest = hash.digest('hex');
  let checked = false, received = 0;
  const cb = await callbacks(t, async (request, response) => {
    assert.equal(request.url, '/agent/uploads');
    if (request.headers['x-forge-mode'] === 'push-check') {
      assert.equal(guest.metrics.processes, 0, 'Rails authorizes before the computer opens the bundle');
      checked = true;
    } else {
      assert.ok(checked);
      assert.equal(request.headers['content-type'], 'application/octet-stream');
      assert.equal(request.headers['content-length'], String(50 * MiB));
      const hash = createHash('sha256');
      for await (const bytes of request) { received += bytes.length; hash.update(bytes); }
      assert.equal(hash.digest('hex'), digest);
    }
    response.writeHead(204).end();
  });
  const start = performance.now();
  assert.deepEqual(await guest.run(cb, call('push', 50 * MiB, digest)), { transferred: true });
  record(start, guest.metrics, 'upload');
  assert.equal(received, 50 * MiB);
  assert.equal(guest.metrics.received, 50 * MiB + 1);
  assert.ok(guest.metrics.largestReceived <= MiB);
  assert.equal(guest.metrics.sent, 51, 'one request per MiB, plus one final check');
});

test('short, long, wrong hash, cancellation and an interrupted download leave no file', async t => {
  const guest = await computer(t);
  const controller = new AbortController();
  const aborted = reply(wanted.length, async function* () { yield wanted; controller.abort(); });
  for (const [cb, signal] of [[smallDownload(wanted.subarray(1))], [smallDownload(Buffer.concat([wanted, wanted]))],
    [smallDownload(Buffer.alloc(wanted.length))], [reply(wanted.length, async function* () { yield wanted; throw Error('torn stream'); })],
    [aborted, controller.signal]]) {
    await assert.rejects(guest.run(cb, call('stage'), signal), /forge_file_transfer_failed/);
    assert.deepEqual(await readdir(guest.root), []);
  }
});

test('stage refuses both an existing file and a symlink at the destination or in any parent', async t => {
  const guest = await computer(t);
  const dest = join(guest.root, `${digest}.bundle`);
  await mkdir(guest.root);
  await writeFile(dest, 'original');
  await assert.rejects(guest.run(smallDownload(), call('stage')), /forge_file_transfer_failed/);
  assert.equal(await readFile(dest, 'utf8'), 'original');
  await rm(dest);
  const elsewhere = join(guest.home, 'elsewhere');
  await mkdir(elsewhere);
  await symlink(join(elsewhere, 'missing'), dest);
  await assert.rejects(guest.run(smallDownload(), call('stage')), /forge_file_transfer_failed/);
  assert.deepEqual(await readdir(elsewhere), []);
  await rm(guest.root, { recursive: true });
  await symlink(elsewhere, guest.root);
  await assert.rejects(guest.run(smallDownload(), call('stage')), /forge_file_transfer_failed/);
  assert.deepEqual(await readdir(elsewhere), []);
  const alias = join(guest.home, 'alias');
  await symlink(guest.home, alias);
  const ancestor = forgeComputer(alias);
  t.after(ancestor.close);
  await assert.rejects(transferForgeFile(smallDownload(), call('stage'), { env: ancestor.env, signal: new AbortController().signal }), /forge_file_transfer_failed/);
});

test('push never uploads an unverified regular file, FIFO, folder, symlink, oversize file or path trick', async t => {
  const guest = await computer(t);
  await mkdir(guest.root);
  const fixed = join(guest.root, 'push.bundle'), alias = join(guest.home, 'decoy');
  await writeFile(alias, wanted);
  let uploads = 0;
  const cb = { check: async () => {}, upload: async () => { uploads++; } };
  const refuses = () => assert.rejects(guest.run(cb, call('push')), /forge_file_transfer_failed/);
  await symlink(alias, fixed);
  await refuses(); await rm(fixed);
  await mkdir(fixed);
  await refuses(); await rm(fixed, { recursive: true });
  assert.equal(spawnSync('mkfifo', [fixed]).status, 0);
  await refuses(); await rm(fixed);
  for (const bytes of [wanted.subarray(1), Buffer.concat([wanted, wanted]), Buffer.alloc(wanted.length)]) {
    await writeFile(fixed, bytes);
    await refuses();
  }
  await rm(fixed);
  assert.equal(spawnSync('truncate', ['-s', String(50 * MiB + 1), fixed]).status, 0);
  await assert.rejects(guest.run(cb, call('push', 50 * MiB, digest)), /forge_file_transfer_failed/);
  await rm(guest.root, { recursive: true });
  const elsewhere = join(guest.home, 'elsewhere');
  await mkdir(elsewhere);
  await writeFile(join(elsewhere, 'push.bundle'), wanted);
  await symlink(elsewhere, guest.root);
  await refuses();
  assert.equal(uploads, 0);
  assert.throws(() => forgeFileRequest('12', { ...command, forge: { ...offer('push'), path: '../decoy' } }), /invalid_forge_file/);
  assert.throws(() => call('stage', 50 * MiB + 1), /invalid_forge_file/);
  assert.throws(() => call('push', 50 * MiB + 1), /invalid_forge_file/);
});

test('no computer opens for a denied callback; only a still-running foreground forge caller can attest', async t => {
  const guest = await computer(t);
  const cb = await callbacks(t, (_request, response) => { response.writeHead(403).end(); });
  for (const mode of ['stage', 'push']) await assert.rejects(guest.run(cb, call(mode)), /forge_file_transfer_failed/);
  assert.equal(guest.metrics.processes, 0);
  const live = liveInvocations(), signal = new AbortController();
  const own = { ...call('push'), tool: 'forge' };
  live.enter({ ...own, tool: 'send_email' }, signal.signal, {});
  live.enter(own, signal.signal, { helper: true });
  assert.equal(live.get(own), undefined);
  const leave = live.enter(own, signal.signal, { env: guest.env });
  assert.equal(live.get(own).env, guest.env);
  for (const scope of [{ workspaceId: '20' }, { actorId: '2' }, { conversationId: '13' }, { taskId: '8' }, { digest: '0'.repeat(64) }]) {
    assert.equal(live.get({ ...own, ...scope }), undefined);
  }
  leave();
  assert.equal(live.get(own), undefined);
  live.enter(own, signal.signal, {});
  signal.abort();
  assert.equal(live.get(own), undefined);
});
