import { defineExtension, defineTool, configure, LiveDoc, UsageDoc } from '@earendil-works/pi-durable';
import { App, Definitions } from './state.mjs';

// Helpers (PARITY.md §1): the `subagent` tool runs a child conversation that
// the tool call owns, in the foreground, and returns its answer. The child is
// the parent bot without this tool (no helpers of helpers): same model,
// thinking, tools, computer and instructions, plus one line saying it is a
// helper. Rails never learns the child's id: the child's App scope names the
// root conversation and its call, so the child's tool calls reach Rails as the
// root's, named `<helper call>/<child call>` (extensions.mjs), its model
// requests count against the root's bounds, and it works in the root's
// computer folder (runtime.mjs).
export const SUBAGENT_EXTENSION = 'omakase.subagents';
export const HELPER_INSTRUCTIONS = 'You are a helper: another assistant gave you one self-contained task. ' +
  'Finish it, then report back concisely; your final answer is all it will see.';
// How often at most the helper's running tools are copied to its call's line.
const MIRROR_MS = 100;
// The newest calls shown; each holds at most a 4 KB output tail.
const MIRROR_LINES = 16;
const USAGE_KEYS = ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens'];
const COST_KEYS = ['input', 'output', 'cacheRead', 'cacheWrite', 'total'];

// The child's whole spend, models and tools, as one usage: the helper call's,
// so the root conversation's totals include its helpers.
function totalUsage(doc) {
  const rows = [...Object.values(doc?.models ?? {}), ...Object.values(doc?.tools ?? {})];
  const sum = (pick, keys) => Object.fromEntries(keys.map(key => [key, rows.reduce((total, row) => total + Number(pick(row)?.[key] ?? 0), 0)]));
  return { ...sum(row => row, USAGE_KEYS), cost: sum(row => row?.cost, COST_KEYS) };
}

const answerText = entry => (entry?.model ?? []).filter(message => message.role === 'assistant')
  .flatMap(message => typeof message.content === 'string' ? [message.content] : (message.content ?? []).filter(b => b.type === 'text').map(b => b.text))
  .join('').trim();

// `toolLine(slot)`: one call as a frame shows it (runtime.mjs). The child's
// calls are copied into this call's details, so the root's frames carry them.
export function subagentExtension({ toolLine }) {
  const tool = defineTool({
    name: 'subagent',
    description: 'Hand a self-contained piece of work to a helper with your tools, and get its answer back. ' +
      'The helper sees only what you give it here, not this conversation.',
    parameters: { type: 'object', additionalProperties: false, required: ['task'], properties: {
      task: { type: 'string', description: 'What the helper must do and what to report back.' },
      context: { type: 'string', description: 'Facts from this conversation the helper needs.' } } },
    // A rerun after a crash finds the same child and the same submission.
    replay: 'safe',
    execute: async (args, api, ctx) => {
      const extensions = (await api.agent(ctx)).extensions.filter(extension => extension.name !== SUBAGENT_EXTENSION);
      const child = await api.commit(async tx => {
        const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
        if (existing) return existing.id;
        const parent = await tx.doc(App, api.conversationId);
        if (!parent.actorId || !parent.workspaceId) throw new Error('scope_missing');
        const created = await tx.createConversation({ ownership: { kind: 'task', taskId: api.taskId } });
        const scope = await tx.doc(App, created.id);
        scope.actorId = parent.actorId; scope.workspaceId = parent.workspaceId; scope.cwd = parent.cwd;
        scope.root = parent.root ? { conversationId: parent.root.conversationId, callId: `${parent.root.callId}/${api.callId}` }
          : { conversationId: api.conversationId, callId: api.callId };
        const stored = await tx.doc(Definitions);
        const digest = stored.conversations[api.conversationId];
        if (digest) stored.conversations[created.id] = digest;
        const instructions = [stored.byDigest[digest]?.instructions, HELPER_INSTRUCTIONS].filter(Boolean).join('\n\n');
        await configure(tx, created.id, { extensions, instructions });
        return created.id;
      }, ctx);
      await api.details({ conversationId: child, tools: [] }, ctx);
      const stopMirror = await mirror(api, ctx, child, toolLine);
      let settled;
      try {
        const handle = await api.conversation(child, ctx);
        const content = args.context ? `${args.task}\n\nContext:\n${args.context}` : args.task;
        settled = await (await handle.submit({ type: 'input', requestId: `subagent:${api.taskId}`, content }, ctx)).wait(ctx);
      } finally { await stopMirror(); }
      const usage = totalUsage(await api.snapshot(UsageDoc, child, ctx));
      const details = { conversationId: child };
      if (settled.status !== 'done') {
        return { output: [{ type: 'text', text: `The helper stopped without an answer (${settled.reason}).` }], isError: true, details, usage };
      }
      const text = answerText(await api.commit(tx => tx.entry(settled.answer), ctx));
      return { output: [{ type: 'text', text: text || 'The helper finished without saying anything.' }], details, usage };
    }
  });
  return defineExtension({ name: SUBAGENT_EXTENSION, tools: [tool] });
}

// Copies the child's calls into this call's details while it works, at most
// every MIRROR_MS, so Rails shows them under the helper's line. Finished ones
// stay, so a line ends "Ran", not "Running", until the helper answers.
async function mirror(api, ctx, child, toolLine) {
  const watch = await api.watchDoc(LiveDoc, child, ctx);
  const lines = new Map();
  let latest = watch.value, shown = '[]', timer, writing = Promise.resolve(), stopped = false;
  const write = () => {
    timer = undefined;
    for (const slot of [...(latest?.tools ?? []), ...(latest?.nestedTools ?? [])]) lines.set(slot.callId, toolLine(slot));
    for (const callId of [...lines.keys()].slice(0, -MIRROR_LINES)) lines.delete(callId);
    const tools = [...lines.values()], key = JSON.stringify(tools);
    if (stopped || key === shown) return;
    shown = key;
    writing = writing.then(() => api.details({ conversationId: child, tools }, ctx)).catch(() => {});
  };
  watch.start(async call => {
    if (call.kind !== 'value') return;
    latest = call.retired ? undefined : call.value;
    timer ??= setTimeout(write, MIRROR_MS);
  });
  return async () => { stopped = true; clearTimeout(timer); await watch.stop(); await writing; };
}
