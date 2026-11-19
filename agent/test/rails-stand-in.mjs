import { digest } from '../state.mjs';

// A stand-in for Rails' side of the tool contract (POST /agent/invocations):
// `ask` waits until the fixture decides it, every other tool answers at once.
// Like Rails' ledger, a decided call keeps its result for every replay. An
// undecided call the sidecar hands back (`handBack`, outside the digest, as
// Rails reads it) stays handed back for every replay, unless `keeps` refuses.
export function railsStandIn({ keeps = () => false } = {}) {
  const calls = [], decided = new Map(), handedBack = new Set();
  return {
    calls, decided, handedBack,
    invoke: async call => {
      calls.push(call);
      if (call.digest !== digest(Object.fromEntries(Object.entries(call).filter(([key]) => !['digest', 'handBack'].includes(key))))) throw new Error('bad_digest');
      const key = `${call.taskId}:${call.callId}`;
      if (call.tool !== 'ask') return { status: 'done', result: { ok: true, ...call.arguments }, isError: false };
      if (!decided.has(key) && call.handBack === true && !keeps(call)) handedBack.add(key);
      // Rails names the card it kept, by its own id, so the call can be withdrawn.
      if (!decided.has(key) && handedBack.has(key)) return { status: 'handedBack', card: [...handedBack].indexOf(key) + 1 };
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
// `lookup` (tools only a code mode script calls) and `helperModels` (the
// models a helper may run on) are sent only when given.
export function definition({ instructions = 'You are a fixture agent.', model = 'fixture/scripted', thinkingLevel = 'medium', tools = FIXTURE_TOOLS, computer,
  capabilities = ALL_CAPABILITIES, lookup, helperModels } = {}) {
  const body = { instructions, model, thinkingLevel, tools, capabilities, ...(computer !== undefined ? { computer } : {}), ...(lookup !== undefined ? { lookup } : {}),
    ...(helperModels !== undefined ? { helperModels } : {}) };
  return { ...body, digest: digest(body) };
}
