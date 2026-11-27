import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:http';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

test('--existing fails on a missing Sprite without sending a POST, for the screen, a desktop action and a screen script', async t => {
  const name = 'test-b1-c42';
  const requests = [];
  const api = createServer((request, response) => {
    requests.push(`${request.method} ${request.url}`);
    response.writeHead(404, { 'Content-Type': 'application/json' }).end('{}');
  });
  api.listen(0, '127.0.0.1');
  await once(api, 'listening');
  t.after(() => new Promise(resolve => api.close(resolve)));

  const bridge = fileURLToPath(new URL('../sprites-bridge.mjs', import.meta.url));
  for (const mode of ['screen', 'desk', 'browser']) {
    const child = spawn(process.execPath, [bridge, name, mode, '--existing'], {
      env: { SPRITES_URL: `http://127.0.0.1:${api.address().port}`, SPRITES_TOKEN: 'synthetic-only',
        SPRITES_IMAGE: 'synthetic-image' },
      stdio: 'ignore', timeout: 3000
    });
    assert.deepEqual(await once(child, 'close'), [1, null]);
  }

  assert.deepEqual(requests, Array(3).fill(`GET /v1/sprites/${name}`));
});
