// PARITY.md item 2: images in a person's message. Scripted
// model and local fixtures only.
import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime, IMAGE_LIMITS } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { railsStandIn } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const scope = { actorId: 'alice', workspaceId: 'one' };
// A 1x1 transparent PNG.
const PNG = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
const image = (data = PNG, mimeType = 'image/png') => ({ type: 'image', data, mimeType });
const text = value => ({ type: 'text', text: value });

async function setup(t, responses, { model } = {}) {
  const cwd = await privateDir('omakase-messages-');
  const provider = scriptedProvider(responses, { model });
  const rails = railsStandIn();
  const deps = { ...provider, invoke: rails.invoke,
    authorize: async requested => ({ ...requested, allowed: requested.actorId === 'alice' && requested.workspaceId === 'one', cwd }) };
  const config = { storePath: join(cwd, 'state.sqlite') };
  const runtime = await createRuntime(config, deps);
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const run = async (conversation, requestId, content = requestId, extra = {}) => {
    const submitted = await runtime.submit(conversation, { ...scope, requestId, content, ...extra });
    return (await runtime.harness.submission(submitted.id, ctx)).wait(ctx);
  };
  return { cwd, runtime, id, provider, rails, run, config, deps };
}

// ---- item 2: images ---------------------------------------------------------------------------

test('a message with images reaches the model and its entry carries them; a repeat is the same submission', async t => {
  let seen;
  const f = await setup(t, [context => { seen = context.messages; return message('a pixel'); }]);
  const content = [text('What is this?'), image()];
  const first = await f.runtime.submit(f.id, { ...scope, requestId: 'look', content });
  assert.equal((await f.runtime.submit(f.id, { ...scope, requestId: 'look', content })).id, first.id);
  assert.equal((await (await f.runtime.harness.submission(first.id, ctx)).wait(ctx)).status, 'done');
  const asked = seen.filter(m => m.role === 'user').at(-1);
  assert.deepEqual(asked.content, content);
  const { entries } = await f.runtime.entries(f.id, scope);
  const person = entries.find(entry => entry.role === 'user');
  assert.equal(person.content, 'What is this?');
  assert.deepEqual(person.images, [{ mimeType: 'image/png', data: PNG }]);
  // The request id's digest covers the images, not only the words.
  await assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: 'look', content: [text('What is this?'), image(), image()] }), /request_conflict/);
});

test('images alone are a message; the limits are refused before anything is admitted', async t => {
  const f = await setup(t, [message('nice')]);
  assert.equal((await f.run(f.id, 'photo', [image()])).status, 'done');
  const refuse = (content, category) => assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: `bad-${category}-${Math.random()}`, content }),
    new RegExp(category));
  const big = 'A'.repeat(Math.ceil(IMAGE_LIMITS.bytes / 3) * 4 + 4);
  await refuse(Array.from({ length: 5 }, () => image()), 'invalid_images');
  await refuse([text('six blocks'), ...Array.from({ length: 5 }, () => image())], 'invalid_content');
  await refuse([text('x'), image(PNG, 'image/svg+xml')], 'invalid_images');
  await refuse([text('x'), image(big)], 'invalid_images');
  await refuse([text('x'), image('not base64!')], 'invalid_images');
  await refuse([text('x'), { ...image(), extra: true }], 'invalid_content');
  await refuse([text('   ')], 'invalid_content');
  await refuse([], 'invalid_content');
  await refuse('', 'invalid_content');
  const entries = (await f.runtime.entries(f.id, scope)).entries.filter(entry => entry.role === 'user');
  assert.equal(entries.length, 1);
});

test('a model without image input is refused images with images_unsupported; words still go', async t => {
  const f = await setup(t, [message('words only')], { model: { input: ['text'] } });
  await assert.rejects(f.runtime.submit(f.id, { ...scope, requestId: 'look', content: [text('see'), image()] }), /images_unsupported/);
  assert.equal((await f.run(f.id, 'hello')).status, 'done');
});

test('HTTP: a submission may be tens of megabytes; other bodies stay small', async t => {
  const cwd = await privateDir('omakase-messages-http-');
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' },
    { ...scriptedProvider([message('seen')]), authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const base = `http://127.0.0.1:${port}`;
  const headers = { authorization: 'Bearer synthetic-sidecar-token-123', 'content-type': 'application/json' };
  const post = (path, body) => fetch(`${base}${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const { id } = await (await post('/v1/conversations', { ...scope, requestId: 'create' })).json();
  // Four images at the limit: 4 x 5 MB, base64.
  const padded = PNG.replace(/=+$/, '');
  const large = (padded + 'A'.repeat(Math.floor(IMAGE_LIMITS.bytes / 3) * 4 - padded.length));
  const response = await post(`/v1/conversations/${id}/submissions`, { ...scope, requestId: 'large', content: [text('four'), ...Array.from({ length: 4 }, () => image(large))] });
  assert.equal(response.status, 202);
  assert.equal((await post('/v1/conversations', { ...scope, requestId: 'x'.repeat(2 * 1024 * 1024) })).status, 413);
});
