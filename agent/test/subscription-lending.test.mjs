import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { join } from 'node:path';
import { stat } from 'node:fs/promises';
import { lendingServer, borrowedCustody, LEND_PATH } from '../subscription-lending.mjs';
import { productionModels } from '../runtime.mjs';
import { createServer } from '../server.mjs';
import { privateDir } from './processes.mjs';

const SECRET = 's'.repeat(40);
const HOUR = 60 * 60 * 1000;

// The lender's own grant, as its custody answers: a token that renews.
function ownGrant({ expires = Date.now() + HOUR } = {}) {
  const grant = { calls: 0, signedOut: false, token: 'sk-ant-oat-first', expires };
  grant.custody = {
    async accessToken() { grant.calls++; if (grant.signedOut) throw Error('unavailable'); return grant.token; },
    async status() { return { expiresAt: new Date(grant.expires).toISOString() }; },
    async start() { throw Error('a lender is never asked to sign in by its borrower'); }
  };
  return grant;
}

async function lend(t, grant) {
  const socketPath = join(await privateDir('lend-'), 'claude.sock');
  const lender = lendingServer({ socketPath, secret: SECRET, custody: grant.custody, lender: 'acme' });
  await lender.listen();
  t.after(() => lender.close());
  return socketPath;
}

const get = (socketPath, path, authorization) => new Promise((resolve, reject) => {
  http.request({ socketPath, path, headers: authorization ? { authorization } : {} }, response => {
    let text = ''; response.on('data', chunk => { text += chunk; }); response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(text) }));
  }).on('error', reject).end();
});

test('the lender serves its current access token, and only that, only with the secret, on a socket only its user opens', async t => {
  const socketPath = await lend(t, ownGrant());
  assert.equal((await stat(socketPath)).mode & 0o777, 0o600);
  const lent = await get(socketPath, LEND_PATH, `Bearer ${SECRET}`);
  assert.equal(lent.status, 200);
  assert.deepEqual(Object.keys(lent.body).sort(), ['access', 'expiresAt', 'lender']);
  assert.equal(lent.body.access, 'sk-ant-oat-first');
  assert.equal(lent.body.lender, 'acme');
  assert.equal((await get(socketPath, LEND_PATH)).status, 401);
  assert.equal((await get(socketPath, LEND_PATH, `Bearer ${'x'.repeat(40)}`)).status, 401);
  assert.equal((await get(socketPath, '/v1/subscriptions/anthropic', `Bearer ${SECRET}`)).status, 404);
});

test('the borrower keeps a token a few minutes, then asks again, so the lender alone ever refreshes', async t => {
  let clock = Date.now();
  const grant = ownGrant();
  const borrower = borrowedCustody({ socketPath: await lend(t, grant), secret: SECRET, now: () => clock });
  assert.equal(await borrower.accessToken(), 'sk-ant-oat-first');
  await Promise.all([borrower.accessToken(), borrower.accessToken()]);
  assert.equal(grant.calls, 1, 'kept');
  grant.token = 'sk-ant-oat-renewed';
  clock += 5 * 60 * 1000 + 1;
  assert.equal(await borrower.accessToken(), 'sk-ant-oat-renewed');
  assert.equal(grant.calls, 2);
});

test('a token near its end is used once but not kept: the lender renews it on the next ask', async t => {
  const grant = ownGrant({ expires: Date.now() + 5.5 * 60 * 1000 });
  const borrower = borrowedCustody({ socketPath: await lend(t, grant), secret: SECRET });
  await borrower.accessToken();
  await borrower.accessToken();
  assert.equal(grant.calls, 2);
});

test('with the lender signed out, down or refusing the secret, the borrower is plainly unavailable, with no fallback', async t => {
  let clock = Date.now();
  const grant = ownGrant();
  const socketPath = await lend(t, grant);
  const borrower = borrowedCustody({ socketPath, secret: SECRET, now: () => clock });
  assert.equal((await borrower.status()).connected, true);
  grant.signedOut = true;
  clock += 5 * 60 * 1000 + 1;
  await assert.rejects(borrower.accessToken(), /no fallback/);
  const status = await borrower.status();
  assert.equal(status.connected, false);
  assert.equal(status.borrowed, true);
  assert.equal(status.lender, 'acme');
  assert.equal(JSON.stringify(status).includes('sk-ant'), false, 'status never carries the token');

  await assert.rejects(borrowedCustody({ socketPath, secret: 'w'.repeat(40) }).accessToken(), /no fallback/);
  await assert.rejects(borrowedCustody({ socketPath: join(await privateDir('lend-'), 'none.sock'), secret: SECRET }).accessToken(), /no fallback/);
});

test('a borrower has no sign-in of its own to start, finish or disconnect', async () => {
  const borrower = borrowedCustody({ socketPath: '/nowhere/claude.sock', secret: SECRET });
  for (const step of ['start', 'finish', 'disconnect']) assert.equal((await borrower[step]()).data.error, 'subscription_borrowed');
});

test('borrowing replaces the install own grant, and is checked like it', () => {
  const vault = { file: '/x/c.json', vaultKey: 'a'.repeat(64), environment: 'staging' };
  const { subscriptions, apiKeys, models } = productionModels({ claudeSubscription: vault, claudeBorrow: { socketPath: '/x/claude.sock', secret: SECRET } });
  assert.equal(subscriptions.anthropic.borrowed, true);
  assert.ok(apiKeys['anthropic-api'], 'the pasted API key still has its vault');
  assert.ok(models.getProviders().some(provider => provider.id === 'anthropic'));
  assert.throws(() => productionModels({ claudeBorrow: { socketPath: 'claude.sock', secret: SECRET } }), /claude_lending_invalid/);
  assert.throws(() => productionModels({ claudeBorrow: { socketPath: '/x/claude.sock', secret: 'short' } }), /claude_lending_invalid/);
  assert.throws(() => productionModels({ claudeBorrow: { socketPath: '/x/claude.sock', secret: SECRET }, anthropicApiKey: 'k' }), /anthropic_credential_ambiguous/);
});

test('a sidecar lends only a grant of its own, from the moment it listens', async t => {
  const cwd = await privateDir('lend-server-');
  const socketPath = join(cwd, 'claude.sock');
  const callbacks = { authorize: async scope => ({ ...scope, allowed: true, cwd }), invoke: async () => ({ status: 'done', result: {} }) };
  const base = { storePath: join(cwd, 'state.sqlite'), sidecarToken: 'synthetic-sidecar-token-123', railsToken: 'different-rails-token' };
  const borrowing = await createServer({ ...base, modelMode: 'local', claudeBorrow: { socketPath: join(cwd, 'other.sock'), secret: SECRET },
    claudeLend: { socketPath, secret: SECRET } }, callbacks);
  assert.deepEqual(borrowing.readiness(), { ready: false, reason: 'claude_lending_invalid' });
  await borrowing.close();

  const owner = await createServer({ ...base, claudeSubscription: { file: join(cwd, 'claude-subscription.json'), vaultKey: 'a'.repeat(64), environment: 'test' },
    claudeLend: { socketPath, secret: SECRET, lender: 'acme' } }, callbacks);
  t.after(() => owner.close());
  assert.equal(owner.readiness().ready, true);
  await owner.listen(0);
  const signedOut = await get(socketPath, LEND_PATH, `Bearer ${SECRET}`);
  assert.deepEqual(signedOut, { status: 503, body: { error: 'subscription_unavailable', lender: 'acme' } });
});
