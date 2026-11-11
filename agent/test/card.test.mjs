// Payments by card: agent/card.mjs (the sidecar's half) with a stand-in
// Sprite, and agent/guest/pay.mjs against a fake Chromium DevTools endpoint
// with a checkout page and a payment provider's card frame. The card reaches
// the pay command's environment and the page, and nothing the model reads.
import assert from 'node:assert/strict';
import test from 'node:test';
import { createServer } from 'node:http';
import { execFile } from 'node:child_process';
import { writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runInNewContext } from 'node:vm';
import { WebSocketServer } from 'ws';
import { fillCard } from '../card.mjs';
import { privateDir } from './processes.mjs';

const PAY = join(dirname(fileURLToPath(import.meta.url)), '..', 'guest', 'pay.mjs');
const NUMBER = '4000056655665556'; // gitleaks:allow (a test card)
const CVC = '737';
const CARD = { site: 'shop.example.com', number: NUMBER, cvc: CVC, exp_month: 12, exp_year: 2030, name: 'Maya Chen', postal_code: '94110' };
const CALL = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'pay_by_card', arguments: {} };
const RESULT = { paying: '$24.50', to: 'Corner Books', card: 'Visa ending 4242', site: 'shop.example.com' };
const text = result => result.output.map(part => part.text).join('');
const secretIn = value => [NUMBER, CVC].some(secret => JSON.stringify(value).includes(secret));

function sprite(answer) {
  const runs = [];
  return { runs, api: { env: { id: 'sprites:as-test-b1-c3', async exec(argv, options) {
    runs.push({ argv, env: options.env });
    options.onOutput(JSON.stringify(answer), {}, { stream: 'stdout' });
    return { ok: true, value: { exitCode: 0 } };
  } } } };
}

test('the card goes to the pay command\'s environment, never its arguments or the model\'s result', async () => {
  const { runs, api } = sprite({ ok: true, filled: ['number', 'expiry', 'security code'], url: 'https://shop.example.com/checkout' });
  const asked = [];
  const result = await fillCard(async data => { asked.push(data); return CARD; }, CALL, RESULT, api, {});

  assert.deepEqual(asked, [{ actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1' }]);
  assert.deepEqual(runs[0].argv, ['node', '/opt/agent/pay.mjs']);
  assert.deepEqual(Object.keys(runs[0].env), ['AGENT_CARD']);
  assert.deepEqual(JSON.parse(runs[0].env.AGENT_CARD), { site: 'shop.example.com', number: NUMBER, cvc: CVC, expMonth: 12, expYear: 2030,
    name: 'Maya Chen', postalCode: '94110' });
  assert.equal(result.isError, undefined);
  assert.match(text(result), /^Typed Visa ending 4242 \(number, expiry, security code\) into the checkout on https:\/\/shop\.example\.com\/checkout, for \$24\.50\./);
  assert.equal(secretIn(result), false);
});

test('a used card, a page that will not fill, or no screen is an error with no card in it', async () => {
  const used = await fillCard(async () => { throw new Error(`rails_callback_failed ${NUMBER}`); }, CALL, RESULT, sprite({}).api, {});
  assert.equal(used.isError, true);
  assert.match(text(used), /already typed in once/);

  const elsewhere = sprite({ ok: false, error: 'The page is not on shop.example.com over https, so nothing was filled.' });
  const refused = await fillCard(async () => CARD, CALL, RESULT, elsewhere.api, {});
  assert.equal(refused.isError, true);
  assert.match(text(refused), /not on shop\.example\.com.*The card was not typed in/);

  const local = await fillCard(async () => CARD, CALL, RESULT, { env: { id: 'local' } }, {});
  assert.match(text(local), /no screen/);
  for (const result of [used, refused, local]) assert.equal(secretIn(result), false);
});

// A fake browser with the agent's tab on `url`: the page has a frame of its
// own, and a card frame from another site that is its own target. Each
// frame's answer to the fill script is in `answers` (`beside` for the second
// pass); every script is kept.
async function fakeChromium(t, url, answers = {}, beside = {}) {
  const sent = [];
  let port;
  const tab = { id: 'agent-1', type: 'page', url, get webSocketDebuggerUrl() { return `ws://127.0.0.1:${port}/devtools/page/agent-1`; } };
  const server = createServer((request, response) => {
    if (request.url === '/json/list') return response.end(JSON.stringify([tab]));
    response.writeHead(404).end();
  });
  const sockets = new WebSocketServer({ server });
  sockets.on('connection', socket => socket.on('message', raw => {
    const { id, method, params, sessionId } = JSON.parse(raw);
    const reply = result => socket.send(JSON.stringify({ id, result, ...(sessionId ? { sessionId } : {}) }));
    if (method === 'Target.setAutoAttach') {
      reply({});
      if (!sessionId) socket.send(JSON.stringify({ method: 'Target.attachedToTarget', params: { sessionId: 'card-frame', targetInfo: { type: 'iframe' } } }));
    } else if (method === 'Page.getFrameTree') {
      reply(sessionId ? { frameTree: { frame: { id: 'card' } } } : { frameTree: { frame: { id: 'top' }, childFrames: [{ frame: { id: 'own' } }] } });
    } else if (method === 'Page.createIsolatedWorld') {
      reply({ executionContextId: params.frameId });
    } else if (method === 'Runtime.evaluate') {
      const second = params.expression.endsWith(', true)');
      sent.push({ frame: params.contextId, second, expression: params.expression });
      reply({ result: { value: (second ? beside : answers)[params.contextId] ?? null } });
    }
  }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
  t.after(() => new Promise(resolve => { sockets.close(); server.close(resolve); server.closeAllConnections?.(); }));
  return { sent, url: `http://127.0.0.1:${port}` };
}

const pay = (home, cdp, card) => new Promise(resolve => {
  execFile(process.execPath, [PAY], { env: { PATH: '/usr/bin:/bin', HOME: home, AGENT_CDP: cdp, AGENT_CARD: JSON.stringify(card) } },
    (error, stdout, stderr) => resolve({ code: error?.code ?? 0, reply: stdout ? JSON.parse(stdout) : null, stdout, stderr }));
});
const AS_SENT = { site: 'shop.example.com', number: NUMBER, cvc: CVC, expMonth: 12, expYear: 2030, name: 'Maya Chen', postalCode: '94110' };

test('pay.mjs fills the checkout and its card frames on the checkout\'s site, and prints which fields, not their values', async t => {
  const home = await privateDir('omakase-pay-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  const chromium = await fakeChromium(t, 'https://shop.example.com/checkout?cart=9#pay', { top: [], card: ['number', 'expiry', 'security code'] },
    { top: ['name', 'postal code'] });
  const result = await pay(home, chromium.url, AS_SENT);

  assert.deepEqual(result.reply, { ok: true, filled: ['number', 'expiry', 'security code', 'name', 'postal code'], url: 'https://shop.example.com/checkout' });
  assert.equal(secretIn(result.stdout) || secretIn(result.stderr), false);
  assert.deepEqual(chromium.sent.map(it => `${it.frame}${it.second ? ' beside' : ''}`), ['top', 'own', 'card', 'top beside', 'own beside', 'card beside'],
    'the page, its own frame, and the card frame in its own process; then beside the card');
  assert.match(chromium.sent[0].expression, /ancestorOrigins/, 'each frame checks the page it is in again');
});

test('pay.mjs fills nothing on another site, over http, without the agent\'s tab, or without a card number field', async t => {
  const home = await privateDir('omakase-pay-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  for (const url of ['https://shop.example.com.evil.test/checkout', 'https://evilshop.example.com.test/', 'https://myshop.example.com/',
    'http://shop.example.com/checkout', 'https://example.com/']) {
    const chromium = await fakeChromium(t, url, { top: ['number'] });
    const result = await pay(home, chromium.url, AS_SENT);
    assert.equal(result.reply.ok, false, url);
    assert.match(result.reply.error, /not on shop\.example\.com/);
    assert.deepEqual(chromium.sent, [], `${url}: nothing was sent to the page`);
  }

  const elsewhere = await privateDir('omakase-pay-');
  const untold = await pay(elsewhere, (await fakeChromium(t, 'https://shop.example.com/')).url, AS_SENT);
  assert.match(untold.reply.error, /visit_website first/);

  const nothing = await pay(home, (await fakeChromium(t, 'https://shop.example.com/')).url, AS_SENT);
  assert.match(nothing.reply.error, /no card field/);
  const partialChromium = await fakeChromium(t, 'https://shop.example.com/', { top: ['security code'] });
  const partial = await pay(home, partialChromium.url, AS_SENT);
  assert.match(partial.reply.error, /card number field wasn't found/);
  assert.equal(partialChromium.sent.some(it => it.second), false, 'nothing is filled beside a card that is not there');
  for (const each of [untold, nothing, partial]) assert.equal(secretIn(each.stdout), false);
});

// The script pay.mjs sends, run against stand-in frames: a checkout's own
// card form, and a payment provider's frame inside it.
test('in each frame, card fields are filled as typing would and masked, only under the checkout\'s site over https', async t => {
  const home = await privateDir('omakase-pay-');
  await writeFile(join(home, '.visit-tab'), 'agent-1');
  const chromium = await fakeChromium(t, 'https://shop.example.com/checkout');
  await pay(home, chromium.url, AS_SENT);
  const expression = chromium.sent[0].expression;

  const frame = (href, ancestors = [], { beside = false, extra = [] } = {}) => {
    class HTMLInputElement {
      constructor(attributes) {
        Object.assign(this, { disabled: false, readOnly: false, autocomplete: '', name: '', id: '', placeholder: '', maxLength: -1,
          events: [], style: { masked: false, setProperty: (name, value) => { if (name === '-webkit-text-security') this.style.masked = value; } } }, attributes);
      }
      getAttribute() { return null; }
      getClientRects() { return this.hidden ? [] : [{}]; }
      dispatchEvent(event) { this.events.push(event.type); }
    }
    class HTMLSelectElement {}
    Object.defineProperty(HTMLInputElement.prototype, 'value', { configurable: true, get() { return this.typed ?? ''; }, set(value) { this.typed = value; } });
    const fields = [new HTMLInputElement({ autocomplete: 'cc-number' }), new HTMLInputElement({ autocomplete: 'cc-exp', placeholder: 'MM / YY', maxLength: 7 }),
      new HTMLInputElement({ name: 'cvc' }), new HTMLInputElement({ autocomplete: 'cc-number', hidden: true }), new HTMLInputElement({ name: 'email' }),
      ...extra.map(attributes => new HTMLInputElement(attributes))];
    const location = Object.assign(new URL(href), { ancestorOrigins: ancestors });
    const context = { location, URL, HTMLInputElement, HTMLSelectElement, Event: class { constructor(type) { this.type = type; } },
      document: { querySelectorAll: () => fields } };
    return { fields, filled: runInNewContext(beside ? expression.replace(/, false\)$/, ', true)') : expression, context) };
  };

  const own = frame('https://shop.example.com/checkout');
  assert.deepEqual([...own.filled], ['number', 'expiry', 'security code']);
  assert.deepEqual(own.fields.map(field => field.typed), [NUMBER, '12 / 30', CVC, undefined, undefined]);
  assert.deepEqual(own.fields.slice(0, 3).map(field => field.style.masked), ['disc', 'disc', 'disc'], 'a screenshot shows dots');
  assert.deepEqual([...own.fields[0].events], ['input', 'change']);

  const around = frame('https://shop.example.com/checkout', [], { beside: true,
    extra: [{ autocomplete: 'shipping postal-code' }, { autocomplete: 'cc-name' }, { autocomplete: 'billing postal-code' }] });
  assert.deepEqual([...around.filled], ['name', 'postal code'], 'beside the card: the marked name and billing postal code only');
  assert.deepEqual(around.fields.map(field => field.typed), [undefined, undefined, undefined, undefined, undefined, undefined, 'Maya Chen', '94110']);
  assert.equal(around.fields[6].style.masked, false, 'a name is not a secret');

  const provider = frame('https://js.payments.example.net/card-frame', ['https://pay.shop.example.com']);
  assert.deepEqual([...provider.filled], ['number', 'expiry', 'security code'], 'a provider\'s frame inside the checkout');

  for (const [href, ancestors] of [['https://js.payments.example.net/card-frame', ['https://evil.test']],
    ['https://js.payments.example.net/card-frame', ['https://evil.test', 'https://shop.example.com']],
    ['http://js.payments.example.net/card-frame', ['https://shop.example.com']],
    ['http://shop.example.com/checkout', []], ['https://evil.test/', []]]) {
    const moved = frame(href, ancestors);
    assert.equal(moved.filled, null, `${href} in ${ancestors}`);
    assert.equal(moved.fields.some(field => field.typed), false);
  }
});
