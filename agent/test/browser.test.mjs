import assert from 'node:assert/strict';
import test from 'node:test';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { publicUrl, pageText, visitWebsite } from '../browser.mjs';

test('only public http and https addresses are visited', () => {
  assert.equal(publicUrl('https://example.com/a?b=1'), 'https://example.com/a?b=1');
  assert.equal(publicUrl(' http://news.ycombinator.com '), 'http://news.ycombinator.com/');
  assert.equal(publicUrl('https://8.8.8.8/'), 'https://8.8.8.8/');
  for (const bad of ['file:///etc/passwd', 'javascript:alert(1)', 'ftp://example.com', 'not a url', 'http://localhost:3000',
    'http://127.0.0.1', 'http://10.0.0.5', 'http://172.20.1.1', 'http://192.168.1.1', 'http://169.254.169.254/latest/meta-data',
    'http://100.64.0.1', 'http://[::1]/', 'http://durable_assistants-web/up', 'http://printer.local', 'http://db.internal',
    'https://user:pass@example.com']) assert.throws(() => publicUrl(bad), Error, bad);
});

test('page text: the title, readable text without scripts or styles, entities decoded, bounded', () => {
  const html = '<html><head><title> Example &amp; Co </title><style>p{}</style></head><body><script>evil()</script>' +
    '<h1>Hello</h1><p>Fish &lt;3 chips&nbsp;today</p><div>Bye</div></body></html>';
  assert.deepEqual(pageText(html), { title: 'Example & Co', text: 'Hello\nFish <3 chips today\nBye' });
  assert.ok(pageText(`<p>${'x'.repeat(10000)}</p>`).text.length <= 6001);
});

test('the tool drives Chromium on the computer and returns what it saw: text for the model and a screenshot it can see', async () => {
  const commands = [];
  const env = {
    cwd: '/computer/7',
    createDir: async () => ({ ok: true }),
    exec: async (command, options) => {
      commands.push(command);
      if (command.includes('--dump-dom')) options.onOutput('<title>Example Domain</title><p>This domain is for examples.</p>', ctx, { stream: 'stdout' });
      return { ok: true, value: { exitCode: 0 } };
    },
    readBinaryFile: async path => (assert.equal(path, '/computer/7/.browser/screenshot.jpeg'), { ok: true, value: new Uint8Array([0xff, 0xd8, 0xff]) })
  };
  const result = await visitWebsite.execute({ url: 'https://example.com' }, { env }, ctx);
  assert.equal(commands.length, 2);
  assert.ok(commands.every(command => Array.isArray(command) && command[0] === 'chromium' && command.at(-1) === 'https://example.com/'));
  assert.ok(commands[0].includes('--screenshot=/computer/7/.browser/screenshot.jpeg'));
  assert.match(result.output[0].text, /^Visited https:\/\/example\.com\/\nTitle: Example Domain\n\nThis domain is for examples\.$/);
  assert.deepEqual(result.output[1], { type: 'image', data: Buffer.from([0xff, 0xd8, 0xff]).toString('base64'), mimeType: 'image/jpeg' });
  assert.equal(visitWebsite.replay, 'safe');
  assert.equal(visitWebsite.executionMode, 'sequential', 'visits share one tab, so they take turns');
});

test('a computer whose browser has another name still works', async () => {
  const tried = [];
  const env = {
    cwd: '/c', createDir: async () => ({ ok: true }),
    exec: async command => {
      tried.push(command[0]);
      return command[0] === 'google-chrome' ? { ok: true, value: { exitCode: 0 } } : { ok: false, error: { code: 'spawn_error', message: 'not found' } };
    },
    readBinaryFile: async () => ({ ok: true, value: new Uint8Array([1]) })
  };
  await visitWebsite.execute({ url: 'https://example.com' }, { env }, ctx);
  assert.deepEqual(tried, ['chromium', 'chromium-browser', 'google-chrome', 'google-chrome']);
});

test('without a computer, or with a private address, the tool fails plainly and never starts a browser', async () => {
  await assert.rejects(visitWebsite.execute({ url: 'https://example.com' }, { env: undefined }, ctx), /no computer/);
  let started = false;
  const env = { cwd: '/c', createDir: async () => ({ ok: true }), exec: async () => { started = true; return { ok: true, value: { exitCode: 0 } }; } };
  await assert.rejects(visitWebsite.execute({ url: 'http://169.254.169.254/' }, { env }, ctx), /Private and local/);
  assert.equal(started, false);
});

test('on a Sprite the page opens in a tab of the screen\'s browser; with no screen browser, headless Chromium instead', async () => {
  const commands = [];
  const screen = {
    id: 'sprites:ss-b1-c2', cwd: '/home/agent', createDir: async () => ({ ok: true }),
    exec: async (command, options) => {
      commands.push(command);
      options.onOutput(JSON.stringify({ title: 'Example Domain', text: 'Signed in as Ajay.', screenshot: '/9j/' }) + '\n', ctx, { stream: 'stdout' });
      return { ok: true, value: { exitCode: 0 } };
    }
  };
  const seen = await visitWebsite.execute({ url: 'https://example.com' }, { env: screen }, ctx);
  assert.deepEqual(commands, [['node', '/opt/agent/visit.mjs', 'https://example.com/']]);
  assert.match(seen.output[0].text, /^Visited https:\/\/example\.com\/\nTitle: Example Domain\n\nSigned in as Ajay\.$/);
  assert.deepEqual(seen.output[1], { type: 'image', data: '/9j/', mimeType: 'image/jpeg' });

  const tried = [];
  const headless = {
    id: 'sprites:ss-b1-c3', cwd: '/home/agent', createDir: async () => ({ ok: true }),
    exec: async command => { tried.push(command[0]); return { ok: true, value: { exitCode: command[0] === 'node' ? 3 : 0 } }; },
    readBinaryFile: async () => ({ ok: true, value: new Uint8Array([1]) })
  };
  await visitWebsite.execute({ url: 'https://example.com' }, { env: headless }, ctx);
  assert.deepEqual(tried, ['node', 'chromium', 'chromium']);
});
