// Files a person attaches in the thread (Rails' Conversation::Attachments):
// Rails asks the sidecar to save them as it does a mail's (saveHeld), and each
// is written under ~/files on the agent's computer, under its own name made
// safe, a second of the same name beside it rather than over it.
import assert from 'node:assert/strict';
import test from 'node:test';
import { saveHeld } from '../files.mjs';

const CALL = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 'composer', callId: 'message-0123456789abcdef' };
const WORD = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
const DOCX = Buffer.from([0x50, 0x4b, 0x03, 0x04, 1, 2, 3]);
const OTHER = Buffer.from([0x50, 0x4b, 0x03, 0x04, 9, 9]);

function sprite() {
  const files = new Map();
  return { files, env: { id: 'sprites:as-test-b1-c3',
    async exec(argv, options) {
      if (argv[0] === 'df') options.onOutput('Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda 20000000 1000 9000000 1% /home\n', {}, { stream: 'stdout' });
      if (argv[0] === 'mv') { files.set(argv.at(-1), files.get(argv.at(-2))); files.delete(argv.at(-2)); }
      return { ok: true, value: { exitCode: 0 } };
    },
    async writeFile(path, bytes) { files.set(path, Buffer.from(bytes)); return { ok: true }; },
    async appendFile(path, bytes) { files.set(path, Buffer.concat([files.get(path), bytes])); return { ok: true }; } } };
}

test('a .docx from the thread is written under ~/files by its own name; an unsafe name is made safe, and a second of one name kept beside it', async () => {
  const { files, env } = sprite();
  const held = [
    { name: 'Q3 plan.docx', type: WORD, size: DOCX.length, held: 0 },
    { name: '../../.ssh/Q3 plan.docx', type: WORD, size: OTHER.length, held: 1 },
    { name: '.hidden\u0007 notes.docx', type: WORD, size: DOCX.length, held: 2 }
  ];
  const saved = await saveHeld(async data => [DOCX, OTHER, DOCX][data.index], CALL, held, env, {});

  const [first, second, third] = saved.map(it => it.saved);
  assert.match(first, /^\/home\/agent\/files\/[0-9a-f]{10}\/Q3 plan\.docx$/);
  assert.equal(second, first.replace('Q3 plan.docx', 'Q3 plan (2).docx'), 'a folder in the name is dropped, and the name taken already is not overwritten');
  assert.equal(third, first.replace('Q3 plan.docx', 'hidden notes.docx'), 'no hidden file, no control characters');
  assert.deepEqual(files.get(first), DOCX);
  assert.deepEqual(files.get(second), OTHER);
  assert.equal(files.size, 3);
  assert.ok(saved.every(it => it.note === undefined));
});
