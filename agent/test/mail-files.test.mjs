// Files Rails holds for a call of its own rather than a tool's: an email's
// attachments (Rails' ReceivedMail::Files). Rails asks the sidecar to save
// them (POST /v1/conversations/:id/files); each is fetched back from Rails by
// its place (POST /agent/files) and saved on the computer as a connector's
// files are (files.mjs): its own name in the call's folder, a PDF's words
// beside it, and only a computer with no room refusing one.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { saveHeld } from '../files.mjs';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';
import { scriptedProvider } from './scripted-provider.mjs';

const CALL = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 'email', callId: 'mail-0123456789abcdef' };
const PDF = Buffer.from('%PDF-1.4 statement');
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);

// A stand-in Sprite that keeps what is written, with `freeKb` free.
function sprite({ freeKb = 10 * 1024 * 1024 } = {}) {
  const files = new Map();
  return { files, env: { id: 'sprites:as-test-b1-c3',
    async exec(argv, options) {
      if (argv[0] === 'df') options.onOutput(`Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda 20000000 1000 ${freeKb} 1% /home\n`, {}, { stream: 'stdout' });
      if (argv[0] === 'node') options.onOutput(JSON.stringify({ ok: true, pages: 1, shown: 1, ocr: [], text: 'Statement', truncated: false, full: `${argv[2]}.txt` }), {}, { stream: 'stdout' });
      if (argv[0] === 'mv') { files.set(argv.at(-1), files.get(argv.at(-2))); files.delete(argv.at(-2)); }
      return { ok: true, value: { exitCode: 0 } };
    },
    async writeFile(path, bytes) { files.set(path, Buffer.from(bytes)); return { ok: true }; },
    async appendFile(path, bytes) { files.set(path, Buffer.concat([files.get(path), bytes])); return { ok: true }; } } };
}

const held = [{ name: 'Extract.pdf', type: 'application/pdf', size: PDF.length, held: 0 }, { name: 'room.jpg', type: 'image/jpeg', size: JPEG.length, held: 1 }];

test('each file is fetched from Rails by its place and saved in the call\'s folder; a PDF\'s words beside it', async () => {
  const { files, env } = sprite();
  const asked = [];
  const fetchFile = async data => { asked.push(data); return [PDF, JPEG][data.index]; };
  const saved = await saveHeld(fetchFile, CALL, held, env, {});

  assert.deepEqual(asked.map(it => [it.taskId, it.callId, it.conversationId, it.index]), [['email', CALL.callId, '3', 0], ['email', CALL.callId, '3', 1]]);
  const [pdf, jpeg] = saved;
  assert.match(pdf.saved, /^\/home\/agent\/files\/[0-9a-f]{10}\/Extract\.pdf$/);
  assert.equal(jpeg.saved, pdf.saved.replace('Extract.pdf', 'room.jpg'));
  assert.deepEqual(files.get(pdf.saved), PDF);
  assert.deepEqual(files.get(jpeg.saved), JPEG);
  assert.equal(pdf.full_text, `${pdf.saved}.txt`);
  assert.equal(jpeg.note, undefined);
});

test('a file the computer has no room for is refused, saying so, and the rest are kept', async () => {
  const { files, env } = sprite({ freeKb: 0 });
  const saved = await saveHeld(async data => [PDF, JPEG][data.index], CALL, held, env, {});
  assert.deepEqual(saved.map(it => it.saved), [null, null]);
  assert.match(saved[0].note, /computer has 0\.0 MB free, so it was not saved/);
  assert.equal(files.size, 0);
});

test('with no computer of this app\'s, nothing is fetched and each file says it was not saved', async () => {
  let fetched = 0;
  const saved = await saveHeld(async () => { fetched++; return PDF; }, CALL, held, undefined, {});
  assert.equal(fetched, 0);
  assert.deepEqual(saved.map(it => [it.name, it.saved]), [['Extract.pdf', null], ['room.jpg', null]]);
  assert.match(saved[0].note, /no computer of this app's/);
});

test('POST /v1/conversations/:id/files: the conversation\'s own scope only, a held computer refused, a computer this sidecar does not offer saves nothing', async t => {
  const cwd = await privateDir('mail-files-');
  const fetched = [];
  const app = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...scriptedProvider([]), authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }),
      fetchFile: async data => { fetched.push(data); return PDF; } });
  t.after(() => app.close());
  const { port } = await app.listen(0);
  const post = (path, body) => fetch(`http://127.0.0.1:${port}${path}`, { method: 'POST',
    headers: { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const { id } = await (await post('/v1/conversations', { ...scope, requestId: 'create' })).json();
  const ask = { ...scope, computer: { provider: 'local' }, taskId: 'email', callId: CALL.callId, files: held };

  const local = await post(`/v1/conversations/${id}/files`, ask);
  assert.equal(local.status, 200);
  const answer = await local.json();
  assert.deepEqual(answer.files.map(it => [it.name, it.saved]), [['Extract.pdf', null], ['room.jpg', null]]);
  assert.match(answer.files[0].note, /no computer of this app's/);

  assert.equal((await post(`/v1/conversations/${id}/files`, { ...ask, workspaceId: 'two' })).status, 404);
  const heldComputer = await post(`/v1/conversations/${id}/files`, { ...ask, computer: { provider: 'sprites', name: 'ss-b1', held: true } });
  assert.equal(heldComputer.status, 503);
  assert.equal((await heldComputer.json()).error, 'computer_held');
  assert.equal((await post(`/v1/conversations/${id}/files`, { ...ask, files: [{ name: 'x' }] })).status, 422);
  assert.equal((await post(`/v1/conversations/${id}/files`, { ...ask, callId: '' })).status, 422);
  assert.deepEqual(fetched, []);
});
