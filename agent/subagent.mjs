import { defineExtension, defineTool, configure, LiveDoc, UsageDoc } from '@earendil-works/pi-durable';
import { App, Definitions } from './state.mjs';
import { DESKTOP_EXTENSION } from './desktop.mjs';

// Helpers: the `subagent` tool runs a child conversation that
// the tool call owns, in the foreground, and returns its answer. The child is
// the parent agent without this tool (no helpers of helpers) and without the
// desktop (only the agent drives its own screen): same model, thinking,
// tools, computer and instructions, plus one line saying it is a helper. Rails never learns the child's id: the child's App scope names the
// root conversation and its call, so the child's tool calls reach Rails as the
// root's, named `<helper call>/<child call>` (extensions.mjs), its model
// requests count against the root's bounds, and it works in the root's
// computer (runtime.mjs).
export const SUBAGENT_EXTENSION = 'omakase.subagents';
export const HELPER_INSTRUCTIONS = 'You are a helper: another assistant gave you one self-contained task. ' +
  'Finish it, then report back concisely; your final answer is all it will see.';
// How often at most the helper's running tools are copied to its call's line.
const MIRROR_MS = 100;
// The newest calls shown while it works; each holds at most a 4 KB output tail.
const MIRROR_LINES = 16;
// The calls its result keeps for the page, each with its input and the end of
// what came back, so a long helper's record stays a few hundred kilobytes.
const KEPT_CALLS = 64;
const KEPT_BYTES = 1024;
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
      const extensions = (await api.agent(ctx)).extensions.filter(extension => ![SUBAGENT_EXTENSION, DESKTOP_EXTENSION].includes(extension.name));
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
      await api.details({ conversationId: child, tools: [], count: 0 }, ctx);
      const stopMirror = await mirror(api, ctx, child, toolLine);
      let settled, calls;
      try {
        const handle = await api.conversation(child, ctx);
        const content = args.context ? `${args.task}\n\nContext:\n${args.context}` : args.task;
        settled = await (await handle.submit({ type: 'input', requestId: `subagent:${api.taskId}`, content }, ctx)).wait(ctx);
      } finally { calls = await stopMirror(); }
      const usage = totalUsage(await api.snapshot(UsageDoc, child, ctx));
      // Every call it made, settled, for the page to keep under its line.
      const details = { conversationId: child, ...calls };
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
// every MIRROR_MS, so Rails shows them under the helper's line: what each was
// given and what it has printed, or once it is done, how it ended and what came
// back. A call's input and result are the child's committed entries, read when
// its calls change; its progress is its slot. A call that leaves its slot with
// no result recorded ended all the same, so no line says "Running" after its
// call is over. Stopping returns every call, settled, for the helper's result.
async function mirror(api, ctx, child, toolLine) {
  const watch = await api.watchDoc(LiveDoc, child, ctx);
  const lines = new Map();
  let latest = watch.value, read = 0, count = 0, seen = '', shown = '', timer, writing = Promise.resolve(), stopped = false;
  const line = (callId, name) => {
    if (!lines.has(callId)) { count++; lines.set(callId, { callId, name, status: 'running', output: '' }); }
    for (const old of [...lines.keys()].slice(0, -KEPT_CALLS)) lines.delete(old);
    return lines.get(callId);
  };
  const settle = message => {
    if (message.role === 'assistant') {
      for (const block of Array.isArray(message.content) ? message.content : []) {
        if (block.type === 'toolCall') line(block.id, block.name).arguments ??= input(block.arguments);
      }
    } else if (message.role === 'toolResult' && message.toolCallId) {
      Object.assign(line(message.toolCallId, message.toolName), { status: message.isError ? 'failed' : 'done', output: tail(resultText(message), KEPT_BYTES) });
    }
  };
  const readEntries = async () => {
    let page;
    do {
      page = await api.commit(tx => tx.scanEntries({ conversationId: child, minEntryId: read + 1, order: 'ascending' }, 64), ctx);
      for (const entry of page.items) { read = Math.max(read, entry.id); (entry.model ?? []).forEach(settle); }
    } while (page.next !== undefined && page.items.length);
  };
  const slots = () => [...(latest?.tools ?? []), ...(latest?.nestedTools ?? [])];
  const update = async () => {
    const now = slots();
    const key = JSON.stringify(now.map(slot => [slot.callId, slot.status]));
    if (key !== seen) { seen = key; await readEntries(); }
    const running = new Set();
    for (const slot of now) {
      const shownLine = line(slot.callId, slot.name);
      if (slot.arguments !== undefined) shownLine.arguments ??= input(slot.arguments);
      if (shownLine.status !== 'running') continue;
      if (slot.status === 'done') shownLine.status = 'done';
      else { running.add(slot.callId); shownLine.output = toolLine(slot).output; }
    }
    for (const each of lines.values()) if (each.status === 'running' && !running.has(each.callId)) each.status = 'done';
  };
  const write = async () => {
    timer = undefined;
    if (stopped) return;
    await update();
    const tools = [...lines.values()].slice(-MIRROR_LINES), key = JSON.stringify([tools, count]);
    if (key === shown) return;
    shown = key;
    writing = writing.then(() => api.details({ conversationId: child, tools, count }, ctx)).catch(() => {});
  };
  let updating = Promise.resolve();
  watch.start(async call => {
    if (call.kind !== 'value') return;
    latest = call.retired ? undefined : call.value;
    timer ??= setTimeout(() => { updating = updating.then(write).catch(() => {}); }, MIRROR_MS);
  });
  return async () => {
    stopped = true; clearTimeout(timer); await watch.stop(); await updating; await writing;
    latest = undefined;
    await readEntries().catch(() => {});
    for (const each of lines.values()) if (each.status === 'running') each.status = 'done';
    return { tools: [...lines.values()].map(each => ({ ...each, output: tail(each.output, KEPT_BYTES) })), count };
  };
}

// A call's input as the page shows it: whole, unless it is long.
function input(args) {
  const json = JSON.stringify(args ?? {});
  return json.length <= 2000 ? args ?? {} : { input: `${json.slice(0, 2000)}…` };
}
const resultText = message => (typeof message.content === 'string' ? message.content :
  (message.content ?? []).filter(block => block.type === 'text').map(block => block.text).join('\n'));
// The end of a text, cut on a character.
function tail(text, bytes) {
  const buffer = Buffer.from(text ?? '');
  return buffer.length <= bytes ? text ?? '' : buffer.subarray(-bytes).toString('utf8').replace(/^\uFFFD+/, '');
}
