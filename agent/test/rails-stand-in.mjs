import { digest } from '../state.mjs';

// A stand-in for Rails' side of the tool contract (POST /agent/invocations):
// `ask` waits until the fixture decides it, every other tool answers at once.
// Like Rails' ledger, a decided call keeps its result for every replay.
export function railsStandIn() {
  const calls = [], decided = new Map();
  return {
    calls, decided,
    invoke: async call => {
      calls.push(call);
      if (call.digest !== digest(Object.fromEntries(Object.entries(call).filter(([key]) => key !== 'digest')))) throw new Error('bad_digest');
      const key = `${call.taskId}:${call.callId}`;
      if (call.tool !== 'ask') return { status: 'done', result: { ok: true, ...call.arguments }, isError: false };
      if (!decided.has(key)) return { status: 'waiting', key, expiresAt: new Date(Date.now() + 600000).toISOString() };
      return { status: 'done', result: decided.get(key), isError: false };
    },
    decide(key, result) { decided.set(key, result); },
    keys: () => [...new Set(calls.filter(call => call.tool === 'ask').map(call => `${call.taskId}:${call.callId}`))]
  };
}

const object = (properties, required = Object.keys(properties)) => ({ type: 'object', additionalProperties: false, properties, required });
export const FIXTURE_TOOLS = Object.freeze([
  { name: 'ask', description: 'Ask the person', parameters: object({ question: { type: 'string' } }) },
  { name: 'note', description: 'Save a note', parameters: object({ key: { type: 'string' } }) }
]);

// An agent definition as Rails sends it, named by its own digest. `computer`
// (null, { provider: 'local' } or a sprite) is sent only when given.
export const LOCAL_COMPUTER = Object.freeze({ provider: 'local' });
// `capabilities` defaults to every one, as Rails gives a new agent.
export const ALL_CAPABILITIES = Object.freeze(['codemode', 'subagents', 'web_search']);
export function definition({ instructions = 'You are a fixture agent.', model = 'fixture/scripted', thinkingLevel = 'medium', tools = FIXTURE_TOOLS, computer,
  capabilities = ALL_CAPABILITIES } = {}) {
  const body = { instructions, model, thinkingLevel, tools, capabilities, ...(computer !== undefined ? { computer } : {}) };
  return { ...body, digest: digest(body) };
}
