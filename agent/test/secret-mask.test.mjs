// Secret-shaped values in tool results are masked before the model reads
// them (secret-mask.mjs), from the shapes Rails masks its reports with
// (config/secret_shapes.json) and against the answers both suites share
// (test/fixtures/secret_shapes.json). Scripted model and stand-ins only; every
// key here is made up.
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createRuntime } from '../runtime.mjs';
import { digest } from '../state.mjs';
import { HELPER_INSTRUCTIONS } from '../subagent.mjs';
import { maskSecrets, secretMask, SHAPES } from '../secret-mask.mjs';
import { railsStandIn, definition, LOCAL_COMPUTER } from './rails-stand-in.mjs';
import { scriptedProvider, fauxAssistantMessage as message, fauxToolCall as call } from './scripted-provider.mjs';
import { privateDir } from './processes.mjs';

const FIXTURE = JSON.parse(readFileSync(new URL('../../test/fixtures/secret_shapes.json', import.meta.url), 'utf8'));
const KEY = 'sk-ant-api03-FakeExample0000MadeUp1111';
const APP_URL = FIXTURE.appUrl;
const TOKEN = 'Fake9Sign7In5Link3Token1MadeUp2Value4abcd';
const scope = { actorId: 'alice', workspaceId: 'one' };

FIXTURE.cases.forEach((example, index) => {
  test(`case ${index}: ${example.input.split('\n')[0].slice(0, 60)}`, () => {
    assert.equal(maskSecrets(example.input, { appUrl: APP_URL }).text, example.expected);
  });
});

test('every shape is a regular expression in JavaScript, in the subset Ruby shares', () => {
  const shapes = JSON.parse(readFileSync(new URL('../../config/secret_shapes.json', import.meta.url), 'utf8'));
  assert.ok(shapes.length > 0);
  assert.equal(SHAPES.length, shapes.length);
  for (const shape of shapes) {
    assert.deepEqual(Object.keys(shape).filter(key => key !== 'entropy').sort(), ['keep', 'name', 'pattern'], shape.name);
    assert.ok(new RegExp(shape.pattern, 'g'));
    // Lookbehind, named groups and inline flags differ between the engines.
    assert.doesNotMatch(shape.pattern, /\(\?<|\(\?[imx]|\\[AzZhRXK]|\\p\{/, shape.name);
  }
});

test('a long run of almost-secret text is masked in time', () => {
  const text = 'a.b-c_d.'.repeat(25_000) + ' password="'.repeat(5_000) + 'Aa1_'.repeat(25_000);
  const started = Date.now();
  maskSecrets(text);
  assert.ok(Date.now() - started < 5000, `took ${Date.now() - started} ms`);
});

const afterTool = (call, result, appUrl = APP_URL) =>
  secretMask({ appUrl, log: () => {} }).hooks[0].handlers.afterTool(call, result, { conversationId: 3 }, ctx);
const answer = text => ({ output: [{ type: 'text', text }, { type: 'image', data: 'AAAA', mimeType: 'image/png' }], diagnostics: [] });

test('the hook masks the text the model reads and says so; a script\'s own call and a clean result are left alone', async () => {
  const masked = await afterTool({ id: 'toolu_1', name: 'bash', arguments: {} }, answer(`echo ${KEY}\nAPI_KEY=fakefakefake01`));
  assert.equal(masked.output[0].text, 'echo sk-ant-[masked]\nAPI_KEY=[masked]');
  assert.deepEqual(masked.output[1], { type: 'image', data: 'AAAA', mimeType: 'image/png' });
  assert.deepEqual(masked.diagnostics, [{ severity: 'info', code: 'masked', message: '[masked 2 secret-shaped values]' }]);
  assert.equal(await afterTool({ id: 'c1', name: 'bash', arguments: {}, parent: { taskId: 9, callId: 'toolu_s' } }, answer(KEY)), undefined);
  assert.equal(await afterTool({ id: 'toolu_1', name: 'bash', arguments: {} }, answer('commit 3f786850e387550fdab836ed7e6dc881de23001b')), undefined);
  const link = `https://app.example.com/sign_in_links/${TOKEN}`;
  assert.equal(await afterTool({ id: 'toolu_1', name: 'ask_outside_for_sign_in', arguments: {} }, answer(link)), undefined);
  // Without the app's address in the sidecar's own environment, the link is masked like any other.
  assert.match((await afterTool({ id: 'toolu_1', name: 'x', arguments: {} }, answer(link), null)).output[0].text, /sign_in_links\/\[masked\]/);
});

test('the app\'s address is read once: missing or unparsable, one warning and masking with no exemption; usable, none', () => {
  for (const appUrl of [undefined, '', 'not a web address', 'javascript:alert(1)']) {
    const lines = [];
    secretMask({ appUrl, log: line => lines.push(line) });
    assert.equal(lines.length, 1, String(appUrl));
    assert.match(lines[0], /APP__URL/);
  }
  const lines = [];
  secretMask({ appUrl: APP_URL, log: line => lines.push(line) });
  assert.deepEqual(lines, []);
});

// One scripted turn: `calls` then 'done'. Returns the tool results the model was sent.
async function turn(t, calls, { invoke, appUrl = APP_URL, log = () => {}, computer = LOCAL_COMPUTER } = {}) {
  const cwd = await privateDir('omakase-secret-mask-');
  let sent;
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), execution: 'trusted-local-single-tenant', appUrl }, {
    log,
    ...scriptedProvider([message(calls, { stopReason: 'toolUse' }),
      context => { sent = context.messages.filter(m => m.role === 'toolResult'); return message('done'); }]),
    authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: invoke ?? railsStandIn().invoke });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  await mkdir(join(cwd, String(id)), { recursive: true });
  const sub = await runtime.submit(id, { ...scope, requestId: 'go', content: 'go', definition: definition({ computer }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  const entries = (await runtime.entries(id, scope)).entries.filter(entry => entry.role === 'toolResult');
  return { sent, entries };
}
const textOf = result => (typeof result.content === 'string' ? result.content : result.content.filter(p => p.type === 'text').map(p => p.text).join('\n'));

test('a key bash prints is masked in the transcript and in what the model reads, with a note', async t => {
  const { sent, entries } = await turn(t, call('bash', { command: `echo ${KEY}` }));
  for (const text of [textOf(entries[0]), textOf(sent[0])]) {
    assert.ok(!text.includes(KEY), text);
    assert.match(text, /sk-ant-\[masked\]/);
    assert.match(text, /\[masked 1 secret-shaped value\]/);
  }
});

test('a Rails tool\'s result is masked; the app\'s own sign-in link goes through and a look-alike does not', async t => {
  const rails = railsStandIn();
  const invoke = async request => request.tool === 'ask' ? { status: 'done', isError: false,
    result: { link: `https://app.example.com/sign_in_links/${TOKEN}`, phish: `https://app.example.com.evil.example/sign_in_links/${TOKEN}` } } : rails.invoke(request);
  const { sent } = await turn(t, [call('note', { key: KEY }, { id: 'toolu_n' }), call('ask', { question: 'link?' }, { id: 'toolu_a' })], { invoke });
  const [note, link] = ['toolu_n', 'toolu_a'].map(id => textOf(sent.find(result => result.toolCallId === id)));
  assert.equal(rails.calls[0].arguments.key, KEY, 'Rails gets the call as the model made it');
  assert.ok(!note.includes(KEY), note);
  assert.match(note, /sk-ant-\[masked\]/);
  assert.ok(link.includes(`"https://app.example.com/sign_in_links/${TOKEN}"`), link);
  assert.match(link, /evil\.example\/sign_in_links\/\[masked\]/);
  assert.match(link, /\[masked 1 secret-shaped value\]/);
});

test('a helper\'s own bash result is masked before the helper reads it', async t => {
  const cwd = await privateDir('omakase-secret-mask-helper-');
  const toolUse = (name, args, id) => message(call(name, args, { id }), { stopReason: 'toolUse' });
  let helperSaw;
  const scripts = { parent: [toolUse('subagent', { task: 'Job K: print the key.' }, 'toolu_h'), message('parent done')],
    helper: [toolUse('bash', { command: `echo ${KEY}` }, 'toolu_b'),
      context => { helperSaw = JSON.stringify(context.messages.filter(m => m.role === 'toolResult')); return message('helper done'); }] };
  const answer = context => {
    const next = scripts[JSON.stringify(context).includes(HELPER_INSTRUCTIONS) ? 'helper' : 'parent'].shift();
    return typeof next === 'function' ? next(context) : next;
  };
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), execution: 'trusted-local-single-tenant' }, {
    ...scriptedProvider(Array.from({ length: 8 }, () => answer)), invoke: railsStandIn().invoke,
    authorize: async requested => ({ ...requested, allowed: true, cwd }) });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  await mkdir(join(cwd, String(id)), { recursive: true });
  const sub = await runtime.submit(id, { ...scope, requestId: 'go', content: 'go', definition: definition({ computer: LOCAL_COMPUTER }) });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
  assert.ok(helperSaw, 'the helper read its result');
  assert.ok(!helperSaw.includes(KEY), helperSaw);
  assert.match(helperSaw, /sk-ant-\[masked\]/);
});

test('a script\'s nested call gets the value whole; what the script returns is masked', async t => {
  const script = [
    `const value = await tools.bash({ command: 'echo ${KEY}' });`,
    "const printed = typeof value === 'string' ? value : JSON.stringify(value);",
    `return (printed.includes('${KEY.slice(7)}') ? 'nested whole: ' : 'nested masked: ') + printed;`
  ].join('\n');
  const { sent } = await turn(t, call('codemode', { code: script }));
  const text = textOf(sent[0]);
  assert.match(text, /nested whole: /);
  assert.ok(!text.includes(KEY), text);
  assert.match(text, /sk-ant-\[masked\]/);
});

test('with no APP__URL the sidecar warns once at start, still masks, and the turn goes through', async t => {
  const lines = [];
  const invoke = async request => ({ status: 'done', isError: false, result: { key: KEY, link: `https://app.example.com/sign_in_links/${TOKEN}` } });
  const { sent } = await turn(t, call('ask', { question: 'link?' }), { invoke, appUrl: null, log: line => lines.push(line) });
  assert.equal(lines.filter(line => /APP__URL/.test(line)).length, 1, lines.join('\n'));
  const text = textOf(sent[0]);
  assert.ok(!text.includes(KEY), text);
  assert.ok(!text.includes(TOKEN), text);
  assert.match(text, /sign_in_links\/\[masked\]/);
});

test('Rails sends no address: a definition is as before, and one with an appUrl is not one', async t => {
  const cwd = await privateDir('omakase-secret-mask-url-');
  const runtime = await createRuntime({ storePath: join(cwd, 'state.sqlite'), appUrl: APP_URL }, {
    ...scriptedProvider([message('done')]), authorize: async requested => ({ ...requested, allowed: true, cwd }), invoke: railsStandIn().invoke });
  t.after(() => runtime.close());
  const { id } = await runtime.create({ ...scope, requestId: 'create' });
  const { digest: _, ...body } = definition();
  const withUrl = { ...body, appUrl: APP_URL };
  await assert.rejects(runtime.submit(id, { ...scope, requestId: 'a', content: 'go', definition: { ...withUrl, digest: digest(withUrl) } }), /invalid_definition/);
  const sub = await runtime.submit(id, { ...scope, requestId: 'c', content: 'go', definition: definition() });
  assert.equal((await (await runtime.harness.submission(sub.id, ctx)).wait(ctx)).status, 'done');
});
