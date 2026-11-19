// A tool result over Durable's output limits, called from a code mode script.
// Durable keeps the head of it, and a script got that head as the value:
// invalid JSON, the rest of a mail thread lost without a word (two Gmail
// threads cut at exactly 51,200 characters). Now the call, a script's or
// the model's, gets valid JSON naming the tool, its size and the limit, with
// its start (#192). Scripted model and a Rails stand-in only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { boundOutput } from '@earendil-works/chord/output';
import { createRuntime } from '../runtime.mjs';
import { RESULT_MAX_BYTES, RESULT_MAX_LINES } from '../whole-results.mjs';
import { definition } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
// The synthetic thread of the reproduction: 30 messages of 3,000 characters, no real mail.
const THREAD = { thread_id: 't1', messages: Array.from({ length: 30 }, (_, i) => ({ message_id: `m${i}`, from: 'a@example.com', text: 'x'.repeat(3000) })) };
const FULL = JSON.stringify(THREAD);

test('the limit is under Durable\'s own, whose cut leaves a thread that is not JSON', async () => {
  const truncate = await import(new URL('../node_modules/@earendil-works/pi-durable/dist/truncate.js', import.meta.url));
  // Room under Durable's cut for the diagnostics it adds after the hook.
  assert.ok(RESULT_MAX_BYTES <= truncate.DEFAULT_MAX_BYTES - 2048);
  assert.equal(RESULT_MAX_LINES, truncate.DEFAULT_MAX_LINES);
  const kept = boundOutput(FULL, { maxBytes: truncate.DEFAULT_MAX_BYTES, maxLines: truncate.DEFAULT_MAX_LINES, retain: 'head' });
  assert.equal(FULL.length, 91_641);
  assert.equal(kept.text.length, 51_200);
  assert.throws(() => JSON.parse(kept.text));
});

test('a script calling a tool whose result is over the limit gets JSON naming both, never the cut text', async t => {
  const script = [
    "let value; try { value = await tools.note({ key: 'thread' }); } catch (error) { return 'error: ' + error.message; }",
    "try { return 'whole ' + JSON.parse(value).note; } catch { return 'cut ' + value.length; }"
  ].join('\n');
  const cwd = await privateDir('omakase-cut-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, {
    ...scriptedProvider([message(call('codemode', { code: script }, { id: 'toolu_s' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async requested => ({ ...requested, allowed: true, cwd }),
    invoke: async c => ({ status: 'done', isError: false, result: c.arguments.key === 'thread' ? THREAD : { ok: true } })
  });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const sub = await runtime.submit(id, { ...scope, requestId: 'cut', content: 'read the thread', definition: definition() });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');

  const result = (await runtime.entries(id, scope)).entries.find(e => e.role === 'toolResult' && e.toolName === 'codemode');
  assert.doesNotMatch(result.content, /cut \d+/);
    assert.match(result.content, /whole note returned 91,\d{3} bytes in 1 lines, over the limit of 49,152 bytes or 2,000 lines for one result/);
});

test('a script\'s call under the limit is as before, and a model\'s own call over it gets JSON, not a cut copy', async t => {
  const script = "return JSON.stringify(await tools.note({ key: 'small' }));";
  const cwd = await privateDir('omakase-cut-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite') }, {
    ...scriptedProvider([message(call('codemode', { code: script }, { id: 'toolu_s' }), { stopReason: 'toolUse' }),
      message(call('note', { key: 'thread' }, { id: 'toolu_n' }), { stopReason: 'toolUse' }), message('done')]),
    authorize: async requested => ({ ...requested, allowed: true, cwd }),
    invoke: async c => ({ status: 'done', isError: false, result: c.arguments.key === 'thread' ? THREAD : { ok: true } })
  });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const sub = await runtime.submit(id, { ...scope, requestId: 'ok', content: 'go', definition: definition() });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const results = (await runtime.entries(id, scope)).entries.filter(e => e.role === 'toolResult');
  assert.match(results.find(e => e.toolName === 'codemode').content, /ok.*true/);
  // The model's own call: valid JSON with its size and start, and no computer to save it on here.
  const direct = results.find(e => e.toolName === 'note');
  assert.notEqual(direct.isError, true);
  const reply = JSON.parse(direct.content);
  assert.deepEqual([reply.over_limit, reply.bytes, reply.path], [true, FULL.length, null]);
  assert.ok(FULL.startsWith(reply.preview));
  assert.doesNotMatch(direct.content, /truncated/i);
});
