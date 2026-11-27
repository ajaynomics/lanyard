import assert from 'node:assert/strict';
import test from 'node:test';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';
import { scriptedProvider, fauxAssistantMessage as message } from './scripted-provider.mjs';

test('the phone only speaks the answer bound to its own submission', async t => {
  const cwd = await privateDir('phone-answer-');
  const token = 'synthetic-sidecar-token-123';
  const server = await createServer({ storePath: join(cwd, 'state.sqlite'), sidecarToken: token, railsToken: 'synthetic-rails-token-456' }, {
    ...scriptedProvider([message('Phone answer'), message('Later written answer')]),
    authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done' })
  });
  t.after(() => server.close());
  const { port } = await server.listen(0);
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  const scope = { actorId: 'alice', workspaceId: 'one' };
  const root = `http://127.0.0.1:${port}/v1/conversations`;
  const post = async (url, requestId) => (await fetch(url, { method: 'POST', headers,
    body: JSON.stringify({ ...scope, requestId, content: requestId, whenBusy: 'reject' }) })).json();
  const { id } = await post(root, 'create');
  const phone = `${root}/${id}/phone-submissions`;
  const first = await post(phone, 'phone');
  await (await server.runtime.harness.submission(first.id, ctx)).wait(ctx);
  const later = await post(`${root}/${id}/submissions`, 'written');
  await (await server.runtime.harness.submission(later.id, ctx)).wait(ctx);
  const get = (submission, conversation = id) => fetch(`${root}/${conversation}/phone-submissions/${submission}?${new URLSearchParams(scope)}`, { headers });
  assert.deepEqual(await (await get(first.id)).json(), { status: 'done', answer: 'Phone answer' });
  assert.equal((await get(later.id)).status, 404);
  assert.equal((await get('999999')).status, 404);
  const other = await post(root, 'another-conversation');
  assert.equal((await get(first.id, other.id)).status, 404);
});
