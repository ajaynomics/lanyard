import assert from 'node:assert/strict';
import test from 'node:test';
import { phoneInRun, phoneMessages } from '../phone-scope.mjs';

test('scope looks beyond the first page and refuses an unprovable live range', async () => {
  const origin = { id: 80, kind: 'app.message', data: { phone: true } };
  const calls = [];
  const cursor = { after: 73 };
  assert.equal(await phoneInRun({ run: { first: 10 } }, async (query, limit, next) => {
    calls.push(next);
    assert.deepEqual(query, { minEntryId: 10, order: 'ascending' });
    assert.equal(limit, 64);
    return next === undefined ? { items: Array.from({ length: 64 }, (_, i) => ({ id: 10 + i })), next: cursor } : { items: [origin] };
  }), true);
  assert.deepEqual(calls, [undefined, cursor]);
  await assert.rejects(phoneInRun({ run: { first: 10 } }, async () => ({ items: [{ id: 11 }] })), /phone_scope_unavailable/);
  await assert.rejects(phoneInRun({ run: {} }, async () => assert.fail('no safe scan range')), /phone_scope_unavailable/);
});

test('phone scope removes outward tools from every system tool delta without changing the source', () => {
  const read = { name: 'current_time' }, write = { name: 'send_text' };
  const messages = [
    { role: 'system', sections: { identity: 'Assistant' }, toolsAdded: [write, read] },
    { role: 'user', content: 'What time is it?' },
    { role: 'system', toolsRemoved: [write], toolsAdded: [write] }
  ];
  const result = phoneMessages(messages);
  assert.deepEqual(result[0].toolsAdded, [read]);
  assert.equal(result[0].sections.identity, 'Assistant');
  assert.match(result[0].sections['omakase.phone'], /read-only/);
  assert.equal(result[1], messages[1]);
  assert.deepEqual(result[2], { role: 'system', toolsRemoved: [], toolsAdded: [] });
  assert.deepEqual(messages[0].toolsAdded, [write, read]);
  assert.deepEqual(messages[2].toolsAdded, [write]);
});
