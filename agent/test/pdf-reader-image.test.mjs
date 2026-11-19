// The sidecar's half of reading a PDF (agent/files.mjs) against the real
// computer image, through the real pi-env daemon in it: no stand-in for the
// Sprite, node, poppler or tesseract. It needs Docker and an image, so it runs
// only with PDF_READER_IMAGE set (bin/check-pdf-reader covers CI's image):
//
//   docker build -f Dockerfile.agent -t local/agent .
//   PDF_READER_IMAGE=local/agent node --test test/pdf-reader-image.test.mjs
import assert from 'node:assert/strict';
import test from 'node:test';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { Connection, RemoteExecutionEnv } from '@earendil-works/pi-env';
import { saveFile } from '../files.mjs';

const IMAGE = process.env.PDF_READER_IMAGE;
const fixture = name => new Uint8Array(readFileSync(new URL(`fixtures/${name}`, import.meta.url)));
const reply = result => JSON.parse(result.output.map(part => part.text).join(''));
let calls = 0;

// A computer from the image, as the agent's user, with no network.
async function computer(t, { prepare } = {}) {
  const name = `pdf-reader-test-${process.pid}-${++calls}`;
  execFileSync('docker', ['run', '-d', '--name', name, '--network', 'none', '--user', 'agent', '--entrypoint', 'sleep', IMAGE, 'infinity']);
  t.after(() => execFileSync('docker', ['rm', '-f', name], { stdio: 'ignore' }));
  if (prepare) execFileSync('docker', ['exec', '-u', 'root', name, 'sh', '-c', prepare]);
  const connection = new Connection({ command: ['docker', 'exec', '-i', '-u', 'agent', name, '/usr/local/bin/pi-env'] });
  t.after(() => connection.close());
  const { home } = await connection.info();
  return new RemoteExecutionEnv({ connection, id: `sprites:${name}`, cwd: home, shellEnv: { HOME: home, LANG: 'C.UTF-8' } });
}

const read = async (env, bytes, name = 'invoice.pdf') =>
  reply(await saveFile(async () => bytes, { taskId: 't', callId: `c${++calls}` }, { file: { name, type: 'application/pdf' } }, { env }, {}));

test('a text PDF returns its words, and a scanned page is read by OCR', { skip: !IMAGE && 'PDF_READER_IMAGE is not set' }, async t => {
  const env = await computer(t);
  const text = await read(env, fixture('text.pdf'));
  assert.match(text.text, /Invoice 4417: three blue widgets/);
  assert.equal(text.read_by_ocr, undefined);

  const scan = await read(env, fixture('scan.pdf'), 'scan.pdf');
  assert.deepEqual(scan.read_by_ocr, [1]);
  assert.match(scan.text, /Invoice\s+4417/);
});

test('a reader that fails says how: the command, its exit code and what it wrote', { skip: !IMAGE && 'PDF_READER_IMAGE is not set' }, async t => {
  const env = await computer(t);
  const broken = await read(env, new TextEncoder().encode('this is not a PDF\n'));
  assert.match(broken.note, /pdftotext exited with code [1-9]/);
  assert.match(broken.note, /the reader exited with code 1; it wrote: \S/);
  assert.doesNotMatch(broken.note, /did not answer/);
});

test('a computer made from an image without the reader says it must be made again', { skip: !IMAGE && 'PDF_READER_IMAGE is not set' }, async t => {
  const env = await computer(t, { prepare: 'rm /opt/agent/pdf-text.mjs' });
  const stale = await read(env, fixture('text.pdf'));
  assert.match(stale.note, /has no PDF reader: it was made from an image older than the reader, and must be made again/);
  assert.match(stale.note, /Cannot find module/);
});
