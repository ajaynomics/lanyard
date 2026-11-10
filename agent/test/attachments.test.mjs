// Files a Rails tool names by path (agent/attachments.mjs): read from the
// agent's computer within the tool's limits and handed to Rails before the
// call goes. Nothing goes unless every file can; nothing is read from the
// sidecar's own disk.
import assert from 'node:assert/strict';
import test from 'node:test';
import { uploadFiles } from '../attachments.mjs';

const MB = 1024 * 1024;
const FILES = { argument: 'attachments', maxBytes: 10 * MB, maxTotalBytes: 15 * MB };
const call = paths => ({ actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'send_email',
  arguments: { to: ['ada@example.com'], attachments: paths } });
const text = result => result.output.map(part => part.text).join('');

function computer(files, id = 'sprites:as-test-b1-c3') {
  const closed = [];
  return { closed, api: { env: { id,
    async openBinaryReader(path) {
      const file = files[path];
      if (file === undefined) return { ok: false, error: { code: 'not_found' } };
      if (file === 'folder') return { ok: false, error: { code: 'is_directory' } };
      return { ok: true, value: {
        info: async () => ({ ok: true, value: { kind: 'file', size: file.length } }),
        read: async (offset, length) => ({ ok: true, value: file.subarray(offset, offset + length) }),
        close: async () => { closed.push(path); } } };
    } } } };
}

function rails() {
  const sent = [];
  return { sent, upload: async data => { sent.push(data); return null; } };
}

test('each file goes to Rails, base64, under the call, before the call does; its bytes are in no result', async () => {
  const { closed, api } = computer({ '/home/agent/a.pdf': new Uint8Array([1, 2, 3]), '/home/agent/b.txt': new Uint8Array([104, 105]) });
  const { sent, upload } = rails();
  assert.equal(await uploadFiles(upload, call(['/home/agent/a.pdf', '/home/agent/b.txt']), FILES, api, {}), undefined);
  assert.deepEqual(sent, [
    { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'send_email', path: '/home/agent/a.pdf', bytes: 'AQID' },
    { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'send_email', path: '/home/agent/b.txt', bytes: 'aGk=' }]);
  assert.deepEqual(closed, ['/home/agent/a.pdf', '/home/agent/b.txt']);
});

test('no files named: nothing is read or sent', async () => {
  const { sent, upload } = rails();
  assert.equal(await uploadFiles(upload, call(undefined), FILES, { env: undefined }, {}), undefined);
  assert.equal(await uploadFiles(upload, call([]), FILES, { env: undefined }, {}), undefined);
  assert.deepEqual(sent, []);
});

test("only from a computer of this app's: never the sidecar's own disk", async () => {
  for (const id of ['local', 'node', '', null]) {
    const { api } = computer({ '/rails/storage/agent/durable.sqlite': new Uint8Array([1]) }, id);
    const { sent, upload } = rails();
    const result = await uploadFiles(upload, call(['/rails/storage/agent/durable.sqlite']), FILES, api, {});
    assert.equal(result.isError, true);
    assert.match(text(result), /no computer to attach files from/);
    assert.deepEqual(sent, [], String(id));
  }
  const { api } = computer({ '/home/me/a.txt': new Uint8Array([1]) }, 'ssh:7');
  const { sent, upload } = rails();
  assert.equal(await uploadFiles(upload, call(['/home/me/a.txt']), FILES, api, {}), undefined);
  assert.equal(sent.length, 1, 'an SSH computer is a computer');
});

test('a missing file, a folder, one too large, or too much together: refused, and none of them sent', async () => {
  const { api } = computer({ '/a': new Uint8Array(8 * MB), '/b': new Uint8Array(8 * MB), '/big': new Uint8Array(11 * MB), '/dir': 'folder' });
  const cases = [
    [['/a', '/missing'], /\/missing could not be read, so nothing was sent/],
    [['/dir'], /\/dir is a folder, not a file/],
    [['/big'], /\/big is 11 MB; a file may be at most 10 MB/],
    [['/a', '/b'], /more than 15 MB together/]];
  for (const [paths, said] of cases) {
    const { sent, upload } = rails();
    const result = await uploadFiles(upload, call(paths), FILES, api, {});
    assert.equal(result.isError, true);
    assert.match(text(result), said);
    assert.deepEqual(sent, [], paths.join());
  }
});

test('a file Rails would not take stops the call', async () => {
  const { api } = computer({ '/a': new Uint8Array(2) });
  const result = await uploadFiles(async () => { throw new Error('rails_callback_failed'); }, call(['/a']), FILES, api, {});
  assert.equal(result.isError, true);
  assert.match(text(result), /\/a could not be handed over, so nothing was sent/);
});

// Through the forwarder (agent/extensions.mjs): the files go first, and a
// refusal means Rails never hears of the call.
test('a tool with files sends them before its call, and a refused file stops the call', async () => {
  const { agentExtension } = await import('../extensions.mjs');
  const order = [];
  const tool = agentExtension({ digest: 'd', tools: [{ name: 'send_email', description: 'x', files: FILES,
    parameters: { type: 'object', properties: { attachments: { type: 'array' } } } }] }, {
    invoke: async data => { order.push(['invoke', data.arguments]); return { status: 'done', result: { sent: true } }; },
    uploadFile: async data => { order.push(['upload', data.path]); },
    invokeRetries: 0, invokeRetryMs: 1 }).tools[0];
  const { api } = computer({ '/a': new Uint8Array(2) });
  const run = args => tool.execute(args, { ...api, conversationId: 3, taskId: 7, callId: 'toolu_1',
    snapshot: async () => ({ actorId: '1', workspaceId: '2' }) }, {});

  assert.equal((await run({ attachments: ['/a'] })).isError, false);
  assert.deepEqual(order, [['upload', '/a'], ['invoke', { attachments: ['/a'] }]]);
  order.length = 0;
  const refused = await run({ attachments: ['/missing'] });
  assert.equal(refused.isError, true);
  assert.deepEqual(order, [], 'Rails never heard of it');
});
