// What a code mode script, and the model, get back from the tools they call,
// on the real runtime with a scripted model. Three things went wrong in use:
// - a screenshot (desktop, visit_website) taken from a script never reached
//   the model: code mode gives a script a schema-less tool's text and drops
//   its images;
// - a 128 KB answer was cut at 51,200 bytes and the script parsed the cut
//   copy: "Unterminated string in JSON" (#192: desktop actions at about
//   128 KB, other results at about 51 KB);
// - a long PDF attachment's answer was over that limit, so a script's
//   get_attachment failed at about 51 KB.
// No model provider, account or credential; the screen is a loopback stand-in.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { deflateSync, crc32 } from 'node:zlib';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime } from '../runtime.mjs';
import { saveFile } from '../files.mjs';
import { RESULT_MAX_BYTES, PREVIEW_CHARACTERS, wholeResults } from '../whole-results.mjs';
import { railsStandIn, definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
import { spritesStandIn } from './sprites-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
// 128 KB of made-up mail as one line of JSON, as Rails or a saved answer has it.
const BIG = JSON.stringify({ messages: Array.from({ length: 40 }, (_, i) => ({ id: `m${i}`, from: 'a@example.com', text: 'x'.repeat(3200) })) });

// The model's script, then 'done'; returns the codemode result the model was sent.
async function runScript(t, script, { computer, invoke, files = {}, spritesConfig, lookup } = {}) {
  const cwd = await privateDir('omakase-codemode-');
  let sent;
  const provider = scriptedProvider([message(call('codemode', { code: script }, { id: 'toolu_s' }), { stopReason: 'toolUse' }),
    context => { sent = context.messages.at(-1); return message('done'); }]);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), execution: 'trusted-local-single-tenant', ...spritesConfig }, {
    ...provider, authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: invoke ?? railsStandIn().invoke, onComputerLog: () => {} });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  await mkdir(join(cwd, String(id)), { recursive: true });
  for (const [name, text] of Object.entries(files)) await writeFile(join(cwd, String(id), name), text);
  const sub = await runtime.submit(id, { ...scope, requestId: 'go', content: 'go', definition: definition({ computer, lookup }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  assert.equal(sent?.role, 'toolResult');
  return sent;
}
const textOf = result => result.content.filter(part => part.type === 'text').map(part => part.text).join('\n');

test('a script reading a 128 KB one-line JSON file gets valid JSON saying so, with its size and start, never the cut copy', async t => {
  const script = [
    "const text = await tools.read({ path: 'answer.json' });",
    "let value; try { value = JSON.parse(text); } catch (error) { return 'parse failed: ' + error.message; }",
    "return [value.over_limit, value.path, value.bytes, value.preview.length, value.note].join(' | ');"
  ].join('\n');
  const result = textOf(await runScript(t, script, { computer: LOCAL_COMPUTER, files: { 'answer.json': BIG } }));
  assert.doesNotMatch(result, /parse failed/);
  assert.match(result, new RegExp(`true \\| answer\\.json \\| ${Buffer.byteLength(BIG)} \\| ${PREVIEW_CHARACTERS} \\| read gave only 51,200 of the file's 1\\d\\d,\\d{3} bytes, over the limit of 49,152 bytes or 2,000 lines for one result`));
});

test('a script reading a file under the limit, or part of one by offset and limit, gets the text as before', async t => {
  const lines = Array.from({ length: 3000 }, (_, i) => `line ${i + 1}`).join('\n');
  const script = [
    "const small = JSON.parse(await tools.read({ path: 'small.json' }));",
    "const part = await tools.read({ path: 'long.txt', offset: 2001, limit: 10 });",
    "return small.ok + ' ' + part.split('\\n')[0];"
  ].join('\n');
  const result = textOf(await runScript(t, script, { computer: LOCAL_COMPUTER, files: { 'small.json': '{"ok":true}', 'long.txt': lines } }));
  assert.match(result, /true line 2001/);
});

// A fake Sprite: what the call's whole answer is written to, by files.mjs.
function sprite() {
  const files = new Map();
  return { files, env: { id: 'sprites:as-test-b1-c3',
    async exec(argv) {
      if (argv[0] === 'mv') { files.set(argv.at(-1), files.get(argv.at(-2))); files.delete(argv.at(-2)); }
      return { ok: true, value: { exitCode: 0 } };
    },
    async writeFile(path, bytes) { files.set(path, Buffer.from(bytes)); return { ok: true }; } } };
}
const afterTool = (envOf, call, result) => wholeResults({ envOf }).hooks[0].handlers.afterTool(call, result, { conversationId: 3, taskId: 7 }, ctx);
const NESTED = { id: 'c1', name: 'note', arguments: {}, parent: { taskId: 9, callId: 'toolu_s' } };
const answer = text => ({ output: [{ type: 'text', text }], diagnostics: [] });

test('a script\'s 128 KB answer is saved whole on the agent\'s computer, and the script gets JSON saying where, with its start', async () => {
  const { files, env } = sprite();
  const result = await afterTool(async () => env, NESTED, answer(BIG));
  assert.equal(result.isError, undefined);
  assert.deepEqual(result.diagnostics, []);
  const said = JSON.parse(result.output[0].text);
  assert.match(said.path, /^\/home\/agent\/files\/[0-9a-f]{10}\/note-result\.json$/);
  assert.equal(files.get(said.path).toString('utf8'), BIG);
  assert.match(said.note, /^note returned 1\d\d,\d{3} bytes in 1 lines, over the limit of 49,152 bytes or 2,000 lines for one result/);
  assert.equal(said.preview, BIG.slice(0, PREVIEW_CHARACTERS));
  assert.ok(Buffer.byteLength(result.output[0].text) < 4000);

  // Without a computer there is nowhere to save it.
  const none = JSON.parse((await afterTool(async () => undefined, NESTED, answer(BIG))).output[0].text);
  assert.equal(none.path, null);
  assert.match(none.note, /over the limit .* Ask for less/);
  // An answer under the limit is left alone.
  assert.equal(await afterTool(async () => env, NESTED, answer('{"ok":true}')), undefined);
  // A model's own call over it is saved in its own folder.
  const own = JSON.parse((await afterTool(async () => env, { ...NESTED, parent: undefined }, answer(BIG))).output[0].text);
  assert.notEqual(own.path, said.path);
  assert.equal(files.get(own.path).toString('utf8'), BIG);
});

test('a script calling a Rails tool with a 128 KB answer gets valid JSON with its size and start, never the cut copy', async t => {
  const script = [
    "const value = await tools.note({ key: 'big' });",
    "try { const v = JSON.parse(value); return v.over_limit + ' ' + v.bytes; } catch (error) { return 'parse failed: ' + error.message; }"
  ].join('\n');
  const result = textOf(await runScript(t, script, { invoke: async () => ({ status: 'done', isError: false, result: JSON.parse(BIG) }) }));
  assert.doesNotMatch(result, /parse failed/);
  assert.match(result, new RegExp(`true ${Buffer.byteLength(BIG)}`));
});

// A real PNG of width x height, so the image is what a screen sends.
function png(width, height) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const size = Buffer.alloc(4); size.writeUInt32BE(data.length);
    const sum = Buffer.alloc(4); sum.writeUInt32BE(crc32(body));
    return Buffer.concat([size, body, sum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 2;
  const row = Buffer.alloc(1 + width * 3, 0x80);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header),
    chunk('IDAT', deflateSync(Buffer.concat(Array.from({ length: height }, () => row)))), chunk('IEND', Buffer.alloc(0))]);
}

// The desktop control server's part: every action answers with a screenshot.
async function fakeDesk(token, shots) {
  let taken = 0;
  const server = createServer(async (request, response) => {
    for await (const _ of request);
    if (request.headers.authorization !== `Bearer ${token}`) return void response.writeHead(401).end('{"ok":false}');
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ ok: true, result: `shot ${++taken}`, width: 1280, height: 800, image_b64: shots[(taken - 1) % shots.length] }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { port: server.address().port, close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections?.(); }) };
}

function spritesEnv(t, values) {
  const saved = Object.fromEntries(Object.keys(values).map(key => [key, process.env[key]]));
  Object.assign(process.env, values);
  t.after(() => { for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key]; else process.env[key] = value; });
}

async function onScreen(t, script, shots) {
  const root = await privateDir('omakase-codemode-screen-');
  const bearer = 'd'.repeat(64);
  const desk = await fakeDesk(bearer, shots);
  const api = await spritesStandIn(root, { guestEnv: { SPRITE_DESK_PORT: String(desk.port), PI_DESKTOP_TOKEN: bearer } });
  spritesEnv(t, { SPRITES_URL: api.url, SPRITES_TOKEN: api.token, SPRITES_IMAGE: api.image });
  t.after(async () => { await api.close(); await desk.close(); });
  return runScript(t, script, { computer: { provider: 'sprites', name: 'ss-b7' }, spritesConfig: { sprites: { token: api.token, image: api.image } } });
}

test('a screenshot taken from a script reaches the model as an image', async t => {
  const shot = png(8, 5).toString('base64');
  const result = await onScreen(t, "return await tools.desktop({ action: 'screenshot' });", [shot]);
  assert.match(textOf(result), /shot 1 \(1280x800\)/);
  const images = result.content.filter(part => part.type === 'image');
  assert.deepEqual(images.map(image => [image.data, image.mimeType]), [[shot, 'image/png']]);
});

test('a script gets a connector’s JSON text unchanged and the model sees its image', async t => {
  const tool = { name: 'mcp__slack__read_file', description: 'Read a file', parameters: { type: 'object', properties: {} } };
  const shot = { type: 'image', mimeType: 'image/png', data: png(8, 5).toString('base64') };
  const value = { text: 'deck' };
  const script = "const file = JSON.parse(await tools.mcp__slack__read_file({})); return file.text;";
  const result = await runScript(t, script, { computer: LOCAL_COMPUTER, lookup: [tool], invoke: async request => {
    assert.equal(request.tool, tool.name);
    return { status: 'done', result: value, images: [shot], isError: false };
  } });
  assert.match(textOf(result), /deck/);
  assert.deepEqual(result.content.filter(part => part.type === 'image'), [shot]);
});

test('of many screenshots in one script the model sees the last few, and is told how many were left out', async t => {
  const shots = [1, 2, 3, 4, 5, 6].map(n => png(n + 1, 2).toString('base64'));
  const result = await onScreen(t, "for (let i = 0; i < 6; i++) await tools.desktop({ action: 'screenshot' }); return 'looked';", shots);
  const images = result.content.filter(part => part.type === 'image');
  assert.deepEqual(images.map(image => image.data), shots.slice(-3));
  assert.match(textOf(result), /3 earlier images from the script's tool calls are left out/);
});

test('a PDF attachment whose words fill 60 KB comes back under the limit, the rest in full_text', async () => {
  const words = Array.from({ length: 1200 }, (_, i) => `Line ${i} of the made-up report, with words to read.`).join('\n');
  const text = words.slice(0, 60_000);
  const { env } = sprite();
  const exec = env.exec;
  env.exec = async (argv, options) => {
    if (argv[0] === 'node') options.onOutput(JSON.stringify({ ok: true, pages: 12, shown: 12, ocr: [], text, truncated: false, full: '/home/agent/files/x/report.pdf.txt' }), {}, { stream: 'stdout' });
    return exec(argv, options);
  };
  const result = await saveFile(async () => new Uint8Array(60 * 1024), { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'get_attachment', arguments: {} },
    { message_id: 'm1', file: { name: 'report.pdf', type: 'application/pdf', size: 60 * 1024 } }, { env }, {});
  const bytes = Buffer.byteLength(result.output[0].text);
  assert.ok(bytes <= RESULT_MAX_BYTES, `${bytes} bytes`);
  const reply = JSON.parse(result.output[0].text);
  assert.equal(reply.truncated, true);
  assert.ok(text.startsWith(reply.text) && reply.text.length > 40_000, `${reply.text.length} characters shown`);
  assert.equal(reply.full_text, '/home/agent/files/x/report.pdf.txt');
  assert.match(reply.note, /whole text is in full_text/);
});

// Issue #192: one limit for every result, and past it valid JSON naming where
// the whole result is, its size and its start, never a cut copy (16 Nov:
// desktop actions failed at about 128 KB and other results at about 51 KB,
// "Unterminated string in JSON").
// About 60 KB of made-up mail as one line of JSON.
const SIXTY = JSON.stringify({ messages: Array.from({ length: 20 }, (_, i) => ({ id: `m${i}`, from: 'a@example.com', text: 'y'.repeat(3000) })) });

test('a script\'s 60 KB result comes back as valid JSON with the saved path, its size and its start; the file holds it whole', async t => {
  const cwd = await privateDir('omakase-codemode-60k-');
  const script = "const value = await tools.note({ key: 'big' }); return JSON.stringify(JSON.parse(value));";
  let sent;
  const provider = scriptedProvider([message(call('codemode', { code: script }, { id: 'toolu_s' }), { stopReason: 'toolUse' }),
    context => { sent = context.messages.at(-1); return message('done'); }]);
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), execution: 'trusted-local-single-tenant' }, {
    ...provider, authorize: async requested => ({ ...requested, allowed: true, cwd }), onComputerLog: () => {},
    invoke: async () => ({ status: 'done', isError: false, result: JSON.parse(SIXTY) }) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  await mkdir(join(cwd, String(id)), { recursive: true });
  const sub = await runtime.submit(id, { ...scope, requestId: 'go', content: 'go', definition: definition({ computer: LOCAL_COMPUTER }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const out = textOf(sent);
  const reply = JSON.parse(out.slice(out.indexOf('{'), out.lastIndexOf('}') + 1));
  assert.equal(reply.over_limit, true);
  assert.equal(reply.bytes, Buffer.byteLength(SIXTY));
  assert.equal(reply.limit_bytes, RESULT_MAX_BYTES);
  assert.ok(SIXTY.startsWith(reply.preview), 'its start');
  assert.equal(reply.preview.length, PREVIEW_CHARACTERS);
  assert.ok(reply.path, out);
  assert.equal(await readFile(reply.path, 'utf8'), SIXTY);
});

test('a 130 KB desktop result comes back as valid JSON with the saved path, its size and its start, and keeps its screenshot', async () => {
  const { files, env } = sprite();
  const big = 'z'.repeat(130 * 1024);
  const shot = { type: 'image', data: png(4, 3).toString('base64'), mimeType: 'image/png' };
  const desk = { id: 'c2', name: 'desktop', arguments: { action: 'screenshot' } };
  for (const called of [desk, { ...desk, parent: { taskId: 9, callId: 'toolu_s' } }]) {
    const result = await afterTool(async () => env, called, { output: [{ type: 'text', text: big }, shot], diagnostics: [] });
    const reply = JSON.parse(result.output[0].text);
    assert.equal(result.isError, undefined, 'a result saved whole is not an error');
    assert.deepEqual([reply.over_limit, reply.tool, reply.bytes, reply.limit_bytes], [true, 'desktop', 130 * 1024, RESULT_MAX_BYTES]);
    assert.equal(reply.preview, big.slice(0, PREVIEW_CHARACTERS));
    assert.match(reply.path, /^\/home\/agent\/files\/[0-9a-f]{10}\/desktop-result\.txt$/);
    assert.equal(files.get(reply.path).toString('utf8'), big);
    assert.deepEqual(result.output.slice(1), [shot]);
    assert.ok(Buffer.byteLength(result.output[0].text) < 4000);
  }
});

test('a result under the limit is left as it was, for a script and for the model', async () => {
  const { env } = sprite();
  const under = answer('w'.repeat(RESULT_MAX_BYTES - 10));
  assert.equal(await afterTool(async () => env, NESTED, under), undefined);
  assert.equal(await afterTool(async () => env, { ...NESTED, parent: undefined }, under), undefined);
  const shot = { output: [{ type: 'text', text: 'shot 1 (1280x800)' }, { type: 'image', data: png(2, 2).toString('base64'), mimeType: 'image/png' }] };
  assert.equal(await afterTool(async () => env, { id: 'c3', name: 'desktop', arguments: {} }, shot), undefined);
});

test('with no computer the result still comes back as valid JSON, its size and its start, saying it was not saved', async () => {
  const reply = JSON.parse((await afterTool(async () => undefined, NESTED, answer(SIXTY))).output[0].text);
  assert.deepEqual([reply.over_limit, reply.path, reply.bytes], [true, null, Buffer.byteLength(SIXTY)]);
  assert.ok(SIXTY.startsWith(reply.preview));
  assert.match(reply.note, /no computer/);
});
