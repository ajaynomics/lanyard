import assert from 'node:assert/strict';
import test from 'node:test';
import { digest } from '../state.mjs';

// docs/design/CONTRACT.md: both sides sign a tool call with the SHA-256 of its
// canonical JSON (keys sorted, no spaces). The same vector is asserted in the
// Rails suite (test/models/invocation_test.rb), so the two cannot drift apart.
test('a tool call digest matches the shared vector', () => {
  const call = { actorId: '1', workspaceId: '2', conversationId: '3', taskId: 7, callId: 'toolu_1', tool: 'remember_note',
    arguments: { key: 'greeting', body: 'h\u00e9llo "world" </script>' } };
  assert.equal(digest(call), 'b5de1faf8c7e1f1e0848f2f8b54d68fbb25b2f2089dce348bfb1bc559293a978');
});

// A bot's definition is named by the same digest on both sides. The same
// vector is asserted in the Rails suite (test/models/bot_test.rb).
test('a definition digest matches the shared vector, the computer\'s notes file switch included', () => {
  const body = { instructions: 'You are Avery.', model: 'anthropic/claude-opus-5-5', thinkingLevel: 'medium',
    tools: [{ name: 'remember_note', description: 'Save a note', parameters: { type: 'object', properties: { key: { type: 'string' } }, required: ['key'] } }],
    capabilities: ['codemode', 'subagents', 'web_search'], computer: { provider: 'local', notesFile: true } };
  assert.equal(digest(body), '928d71db3571432557027aabdda03d3e997eba2ed571d31f65971c51d8e15fee');
});
