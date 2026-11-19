// An agent checks a document by looking at it: it draws a PDF's pages as PNG
// (pdftoppm -png) and reads each with the `read` tool the runtime installs.
// These run the real runtime with a scripted model and assert what that model
// is sent: the page as an image block, a wide page shrunk to the model's
// limits, and a PPM (pdftoppm's default) refused in words rather than read as
// text. pdftoppm draws the page when this machine has it; otherwise the PNG
// is made here.
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { mkdir, writeFile, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { crc32, deflateSync } from 'node:zlib';
import { createRuntime } from '../runtime.mjs';
import { railsStandIn, definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';

const scope = { actorId: 'alice', workspaceId: 'one' };
const PDF = fileURLToPath(new URL('fixtures/text.pdf', import.meta.url));
const pdftoppm = (() => { try { execFileSync('pdftoppm', ['-v'], { stdio: 'ignore' }); return true; } catch { return false; } })();

// A PNG of width x height in stripes, so it is not one flat colour.
function png(width, height) {
  const chunk = (type, data) => {
    const body = Buffer.concat([Buffer.from(type), data]);
    const size = Buffer.alloc(4); size.writeUInt32BE(data.length);
    const sum = Buffer.alloc(4); sum.writeUInt32BE(crc32(body));
    return Buffer.concat([size, body, sum]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
  header[8] = 8; header[9] = 2;
  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) row.fill(x % 200 < 100 ? 0x20 : 0xe0, 1 + x * 3, 4 + x * 3);
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', header),
    chunk('IDAT', deflateSync(Buffer.concat(Array.from({ length: height }, () => row)))), chunk('IEND', Buffer.alloc(0))]);
}

// Width and height from a PNG's or a JPEG's header.
function dimensions(bytes) {
  if (bytes.subarray(1, 4).toString() === 'PNG') return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  for (let at = 2; at < bytes.length;) {
    const marker = bytes[at + 1], length = bytes.readUInt16BE(at + 2);
    if (marker >= 0xc0 && marker <= 0xc3) return { width: bytes.readUInt16BE(at + 7), height: bytes.readUInt16BE(at + 5) };
    at += 2 + length;
  }
  return undefined;
}

// The PDF's first page drawn by pdftoppm, as PNG or as its default PPM.
async function drawn(dir, format) {
  execFileSync('pdftoppm', [...(format === 'png' ? ['-png'] : []), '-r', '50', '-f', '1', '-l', '1', '-singlefile', PDF, join(dir, 'page')]);
  return readFile(join(dir, `page.${format}`));
}

// Each named file is read in turn; returns the tool result the model is sent for each.
async function readAll(t, files) {
  const cwd = await privateDir('omakase-read-images-');
  const sent = [];
  const next = reply => context => { sent.push(context.messages.at(-1)); return reply; };
  const provider = scriptedProvider([message(call('read', { path: files[0][0] }), { stopReason: 'toolUse' }),
    ...files.slice(1).map(([name]) => next(message(call('read', { path: name }), { stopReason: 'toolUse' }))), next(message('done'))]);
  const rails = railsStandIn();
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), execution: 'trusted-local-single-tenant' }, { ...provider,
    authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: rails.invoke });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  await mkdir(join(cwd, String(id)), { recursive: true });
  for (const [name, bytes] of files) await writeFile(join(cwd, String(id), name), bytes);
  const submitted = await runtime.submit(id, { ...scope, requestId: 'look', content: 'Check the page', definition: definition({ computer: LOCAL_COMPUTER }) });
  assert.equal((await (await runtime.harness.submission(submitted.id, ctx)).wait(ctx)).status, 'done');
  assert.equal(sent.length, files.length);
  for (const result of sent) assert.equal(result.role, 'toolResult');
  return sent;
}

test('a page drawn as PNG reaches the model as an image, and a wide one is shrunk to fit 2000x2000', async t => {
  if (!pdftoppm) t.diagnostic('pdftoppm is not on PATH: the page is a PNG made by this test instead');
  const page = pdftoppm ? await drawn(await privateDir('omakase-pages-'), 'png') : png(425, 550);
  assert.equal(page.subarray(1, 4).toString(), 'PNG');
  const [small, wide] = await readAll(t, [['page-1.png', page], ['wide.png', png(4000, 1000)]]);

  assert.equal(small.isError, false, JSON.stringify(small.content));
  const image = small.content.find(block => block.type === 'image');
  assert.ok(image, `no image block: ${JSON.stringify(small.content)}`);
  assert.equal(image.mimeType, 'image/png');
  assert.match(image.data, /^[A-Za-z0-9+/]+=*$/);
  assert.deepEqual(Buffer.from(image.data, 'base64'), page, 'a page within the limits arrives as drawn');

  assert.equal(wide.isError, false, JSON.stringify(wide.content));
  const shrunk = wide.content.find(block => block.type === 'image');
  assert.ok(shrunk, `no image block: ${JSON.stringify(wide.content)}`);
  assert.match(shrunk.mimeType, /^image\/(png|jpeg)$/);
  const size = dimensions(Buffer.from(shrunk.data, 'base64'));
  assert.ok(size.width <= 2000 && size.height <= 2000, `sent at ${size.width}x${size.height}`);
  assert.equal(size.width, 2000);
  assert.equal(size.height, 500);
});

test('a page drawn as PPM, pdftoppm\'s default, is refused in words, not read as text', async t => {
  if (!pdftoppm) t.diagnostic('pdftoppm is not on PATH: the PPM is made by this test instead');
  const ppm = pdftoppm ? await drawn(await privateDir('omakase-pages-'), 'ppm') :
    Buffer.concat([Buffer.from('P6\n2 2\n255\n'), Buffer.alloc(12, 0x80)]);
  assert.equal(ppm.subarray(0, 2).toString(), 'P6');
  const [result] = await readAll(t, [['page-1.ppm', ppm]]);
  assert.equal(result.isError, true);
  const text = result.content.map(block => block.text ?? '').join('');
  assert.match(text, /^page-1\.ppm is not a supported image \(jpg, png, gif, webp, bmp\); it was not read as text\./);
  assert.match(text, /pdftoppm -png/);
  assert.ok(!result.content.some(block => block.type === 'image'));
  assert.ok(!text.includes('P6'), 'none of its bytes reach the model as text');
});
