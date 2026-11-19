// A file of any size a tool found reaches the agent's computer whole
// (agent/files.mjs, agent/server.mjs fetchFile): streamed from Rails in
// chunks to a partial name, moved into place once whole, and refused only
// when the computer has no room for it.
import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { saveFile, CHUNK_BYTES } from '../files.mjs';
import { railsCallbacks } from '../server.mjs';

const CALL = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'mcp__drive__read_file', arguments: {} };
const MB = 1024 * 1024;
const reply = result => JSON.parse(result.output.map(part => part.text).join(''));

// A stand-in Sprite that keeps what is written, in order, and answers df
// with `freeKb` free.
function sprite({ freeKb = 10 * 1024 * 1024, failAppendAt } = {}) {
  const runs = [], writes = [], files = new Map();
  return { runs, writes, files, api: { env: { id: 'sprites:as-test-b1-c3',
    async exec(argv, options) {
      runs.push(argv);
      if (argv[0] === 'df') options.onOutput(`Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda 20000000 1000 ${freeKb} 1% /home\n`, {}, { stream: 'stdout' });
      if (argv[0] === 'mv') { files.set(argv.at(-1), files.get(argv.at(-2))); files.delete(argv.at(-2)); }
      if (argv[0] === 'rm') files.delete(argv.at(-1));
      return { ok: true, value: { exitCode: 0 } };
    },
    async writeFile(path, bytes) { writes.push(['write', path, bytes.length]); files.set(path, Buffer.from(bytes)); return { ok: true }; },
    async appendFile(path, bytes) {
      writes.push(['append', path, bytes.length]);
      if (failAppendAt !== undefined && writes.length > failAppendAt) return { ok: false, error: { code: 'io' } };
      files.set(path, Buffer.concat([files.get(path), bytes])); return { ok: true };
    } } } };
}

// 30 MB in Rails' small pieces, each byte known.
const pattern = i => i % 251;
function body(size, piece = 64 * 1024) {
  return (async function* () {
    for (let offset = 0; offset < size; offset += piece) {
      yield Uint8Array.from({ length: Math.min(piece, size - offset) }, (_, i) => pattern(offset + i));
    }
  })();
}

test('a 30 MB file is written whole, a few MiB at a time, to a partial name moved into place', async () => {
  const size = 30 * MB;
  const { runs, writes, files, api } = sprite();
  const result = await saveFile(async () => ({ size, body: body(size) }), CALL,
    { file: { name: 'package.zip', type: 'application/zip', size } }, api, {});

  const answer = reply(result);
  assert.equal(result.isError, undefined, answer.note);
  assert.match(answer.saved, /^\/home\/agent\/files\/[0-9a-f]{10}\/package\.zip$/);
  const saved = files.get(answer.saved);
  assert.equal(saved.length, size);
  assert.ok(saved.every((byte, i) => byte === pattern(i)), 'every byte where it belongs');
  assert.equal(files.size, 1, 'no partial file left');

  const [first, ...rest] = writes;
  assert.equal(first[0], 'write');
  assert.ok(rest.every(it => it[0] === 'append' && it[1] === first[1]));
  assert.match(first[1], /\/\.package\.zip\.[0-9a-f]+\.partial$/);
  assert.ok(writes.every(it => it[2] <= CHUNK_BYTES), 'no write holds more than a chunk');
  assert.ok(writes.length >= Math.ceil(size / CHUNK_BYTES));
  assert.deepEqual(runs.find(it => it[0] === 'mv'), ['mv', '-f', '--', first[1], answer.saved]);
});

test('a file the computer has no room for is refused, in MB, before anything is written', async () => {
  const size = 30 * MB;
  const { writes, api } = sprite({ freeKb: 12 * 1024 });
  const result = await saveFile(async () => ({ size, body: body(size) }), CALL, { file: { name: 'package.zip', size } }, api, {});

  assert.equal(result.isError, true);
  assert.equal(reply(result).note, 'The file needs 30.0 MB and the computer has 12.0 MB free, so it was not saved.');
  assert.deepEqual(writes, []);
});

test('a file that stops arriving, or that the computer stops taking, leaves no partial file', async () => {
  const stalled = sprite();
  const cut = (async function* () { yield new Uint8Array(CHUNK_BYTES + 1); throw new Error('file_stalled'); })();
  const broken = await saveFile(async () => ({ size: 30 * MB, body: cut }), CALL, { file: { name: 'a.zip' } }, stalled.api, {});
  assert.equal(broken.isError, true);
  assert.match(reply(broken).note, /stopped arriving/);
  assert.equal(stalled.files.size, 0);
  assert.ok(stalled.runs.some(it => it[0] === 'rm'));

  const full = sprite({ failAppendAt: 1 });
  const refused = await saveFile(async () => ({ size: 30 * MB, body: body(30 * MB) }), CALL, { file: { name: 'a.zip' } }, full.api, {});
  assert.equal(refused.isError, true);
  assert.match(reply(refused).note, /would not take/);
  assert.equal(full.files.size, 0);

  const short = sprite();
  const shortened = await saveFile(async () => ({ size: 30 * MB, body: body(MB) }), CALL, { file: { name: 'a.zip' } }, short.api, {});
  assert.equal(shortened.isError, true);
  assert.equal(short.files.size, 0, 'a file shorter than Rails said is not kept');
});

// Rails' side of the stream, served for real on loopback.
async function rails(handler) {
  const server = http.createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return { server, callbacks: config => railsCallbacks({ railsUrl: `http://127.0.0.1:${port}`, railsToken: 'rails-token', ...config }) };
}

test('fetchFile streams a 30 MB answer as it comes, with its size, never refusing it for size', async () => {
  const size = 30 * MB;
  const { server, callbacks } = await rails((request, response) => {
    response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': size });
    const piece = Buffer.alloc(MB, 7);
    for (let i = 0; i < 30; i++) response.write(piece);
    response.end();
  });
  try {
    const download = await callbacks().fetchFile({ taskId: 7, callId: 'toolu_1' });
    assert.equal(download.size, size);
    let total = 0;
    for await (const chunk of download.body) total += chunk.length;
    assert.equal(total, size);
  } finally { server.close(); }
});

test('fetchFile gives up when bytes stop arriving, not after a fixed time', async () => {
  const { server, callbacks } = await rails((request, response) => {
    response.writeHead(200, { 'content-length': 10 });
    response.write('12345');
    // ...and nothing more.
  });
  try {
    const download = await callbacks({ fileIdleMs: 200 }).fetchFile({ taskId: 7, callId: 'toolu_1' });
    await assert.rejects(async () => { for await (const _ of download.body); });
  } finally { server.closeAllConnections(); server.close(); }
});

test('every file a call found is saved, each fetched by its place and given its own path', async () => {
  const { files, api } = sprite();
  const asked = [];
  const bytes = [new Uint8Array([1]), new Uint8Array([2, 2]), new Uint8Array([3, 3, 3])];
  const result = await saveFile(async data => { asked.push(data.index); return bytes[data.index]; }, CALL,
    { text: 'Three files.', found_files: [{ name: 'a.zip', type: 'application/zip', size: 1 }, { name: 'a.zip', type: 'application/zip', size: 2 },
      { name: 'export-answer.txt', type: 'text/plain', size: 3 }] }, api, {});

  const answer = reply(result);
  assert.equal(result.isError, undefined);
  assert.deepEqual(asked, [0, 1, 2]);
  assert.equal(answer.text, 'Three files.');
  const paths = answer.found_files.map(it => it.saved);
  assert.equal(new Set(paths).size, 3, paths.join());
  assert.match(paths[0], /\/a\.zip$/);
  assert.match(paths[1], /\/a \(2\)\.zip$/);
  paths.forEach((path, i) => assert.deepEqual(new Uint8Array(files.get(path)), bytes[i]));
});

test('one of several files that can\'t be fetched says so, and the others are kept', async () => {
  const { files, api } = sprite();
  const result = await saveFile(async data => { if (data.index === 1) throw new Error('rails_callback_failed'); return new Uint8Array([data.index]); }, CALL,
    { found_files: [{ name: 'a.txt' }, { name: 'b.txt' }, { name: 'c.txt' }] }, api, {});
  const answer = reply(result);
  assert.equal(result.isError, undefined);
  assert.deepEqual(answer.found_files.map(it => it.saved === null), [false, true, false]);
  assert.match(answer.found_files[1].note, /could not be fetched/);
  assert.equal(files.size, 2);
});
