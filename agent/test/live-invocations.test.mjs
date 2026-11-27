import assert from 'node:assert/strict';
import test from 'node:test';
import { liveInvocations } from '../live-invocations.mjs';

const call = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 4, callId: 'call_5', digest: 'a'.repeat(64), tool: 'forge' };

test('only the exact live forge invocation is attested', () => {
  const registry = liveInvocations();
  const controller = new AbortController();
  const leave = registry.enter(call, controller.signal, { helper: false });
  assert.equal(registry.includes({ ...call, taskId: '4' }), true);
  for (const field of ['actorId', 'workspaceId', 'conversationId', 'taskId', 'callId', 'digest']) {
    assert.equal(registry.includes({ ...call, [field]: 'other' }), false, field);
  }
  leave();
  assert.equal(registry.includes(call), false);
});

test('cancelled or helper calls cannot keep a live proof', () => {
  const registry = liveInvocations();
  const controller = new AbortController();
  const wrapped = { ...call, tool: 'use_tool', arguments: { name: 'forge' } };
  registry.enter(wrapped, controller.signal, { helper: true });
  assert.equal(registry.includes(wrapped), false);
  registry.enter(wrapped, controller.signal, { helper: false });
  assert.equal(registry.includes(wrapped), true);
  controller.abort();
  assert.equal(registry.includes(wrapped), false);
  assert.equal(liveInvocations().includes(wrapped), false);
});
