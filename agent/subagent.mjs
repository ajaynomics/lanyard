import { defineExtension, defineTool, defineTask, configure, LiveDoc, UsageDoc, ConversationIdle } from '@earendil-works/pi-durable';
import { getSupportedThinkingLevels, clampThinkingLevel } from '@earendil-works/pi-ai/models';
import { App, Definitions, Helpers } from './state.mjs';
import { DESKTOP_EXTENSION } from './desktop.mjs';

// Helpers: the `subagent` tool runs a child conversation that
// the tool call owns, in the foreground, and returns its answer. The child is
// the parent agent without this tool (no helpers of helpers) and without the
// desktop (only the agent drives its own screen): same tools, computer and
// instructions, plus one line saying it is a helper, and the same model and
// thinking unless the call names others (chooseModel). Rails never learns the child's id: the child's App scope names the
// root conversation and its call, so the child's tool calls reach Rails as the
// root's, named `<helper call>/<child call>` (extensions.mjs), its model
// requests count against the root's bounds, and it works in the root's
// computer (runtime.mjs).
//
// With `background: true` the call returns at once and the helper runs under a
// background task its conversation owns (HELPER_TASK), so the agent carries on
// and its Stop leaves the helper running. The helper tells Rails it started,
// what it is doing, and how it ended (`report`); Rails hands the answer to the
// conversation as a message. A background helper counts its model requests
// against a bound of its own, since it outlives the run that started it.
// While it works, the agent (`message_helper`) or the person (Rails, through
// runtime.mjs) may tell it something more: a steer into its own turn
// (`steerHelper`), as a steer reaches the agent.
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
export const HELPER_TASK = 'omakase.helper';
// Background helpers running at once: in one conversation, and in the sidecar,
// whose memory every one of them shares.
export const HELPERS_PER_CONVERSATION = 3;
export const HELPERS_PER_SIDECAR = 6;
export const backgroundStarted = callId => 'A helper is working on it in the background. Its answer will come to this conversation ' +
  `as a message when it finishes; carry on meanwhile. To tell it something while it works, use message_helper with helper "${callId}".`;
// How often at most a background helper tells Rails what it is doing.
const PROGRESS_MS = 1000;
// The longest wait between tries of its last report while Rails cannot take
// it, the wait doubling from `retryMs`; it tries for `reportForMs`.
const REPORT_RETRY_MAX_MS = 600000;
const USAGE_KEYS = ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens'];
const COST_KEYS = ['input', 'output', 'cacheRead', 'cacheWrite', 'total'];

// The child's whole spend, models and tools, as one usage: the helper call's,
// so the root conversation's totals include its helpers.
function totalUsage(doc) {
  const rows = [...Object.values(doc?.models ?? {}), ...Object.values(doc?.tools ?? {})];
  const sum = (pick, keys) => Object.fromEntries(keys.map(key => [key, rows.reduce((total, row) => total + Number(pick(row)?.[key] ?? 0), 0)]));
  return { ...sum(row => row, USAGE_KEYS), cost: sum(row => row?.cost, COST_KEYS) };
}

// Each model's and tool's running total in `doc` (pi.usage), as one reply's
// usage is put ({input, output, cacheRead, cacheWrite, totalTokens, cost}),
// for Rails to record what each added (docs/billing.md).
export function usageRows(doc) {
  const rows = bucket => Object.fromEntries(Object.entries(doc?.[bucket] ?? {}).map(([key, row]) =>
    [key, { ...Object.fromEntries(USAGE_KEYS.map(name => [name, Number(row?.[name] ?? 0)])), cost: Number(row?.cost?.total ?? 0) }]));
  return { models: rows('models'), tools: rows('tools') };
}

const answerText = entry => (entry?.model ?? []).filter(message => message.role === 'assistant')
  .flatMap(message => typeof message.content === 'string' ? [message.content] : (message.content ?? []).filter(b => b.type === 'text').map(b => b.text))
  .join('').trim();

// `toolLine(slot)`: one call as a frame shows it (runtime.mjs). The child's
// calls are copied into this call's details, so the root's frames carry them.
// `report(data)`: a background helper's news for Rails (POST /agent/helpers).
// `modelOf(route)`: the model of a route this sidecar runs, else undefined.
export function subagentExtension({ toolLine, report, retryMs = 5000, reportForMs = 86400000, modelOf }) {
  const helper = helperTask({ toolLine, report, retryMs, reportForMs });
  const tool = defineTool({
    name: 'subagent',
    description: 'Hand a self-contained piece of work to a helper with your tools, and get its answer back. ' +
      'The helper sees only what you give it here, not this conversation.',
    parameters: { type: 'object', additionalProperties: false, required: ['task'], properties: {
      task: { type: 'string', description: 'What the helper must do and what to report back.' },
      context: { type: 'string', description: 'Facts from this conversation the helper needs.' },
      background: { type: 'boolean', description: 'Run it in the background for a long job: the call returns at once, ' +
        'you carry on, and the answer comes later as a message. At most ' + HELPERS_PER_CONVERSATION + ' at a time.' },
      model: { type: 'string', description: MODEL_ARGUMENT },
      thinking: { type: 'string', description: THINKING_ARGUMENT } } },
    // A rerun after a crash finds the same child and the same submission.
    replay: 'safe',
    execute: async (args, api, ctx) => {
      if (args.background === true) return startHelper(helper, api, ctx, modelOf, args);
      const extensions = helperExtensions(await api.agent(ctx));
      const made = await api.commit(async tx => {
        const existing = (await tx.scanConversations({ ownerTaskId: api.taskId }, 1)).items[0];
        if (existing) return { child: existing.id };
        const chosen = chooseModel(await definitionOf(tx, api.conversationId), modelOf, args);
        if (chosen.refusal) return chosen;
        return { child: await createChild(tx, { owner: api.taskId, conversationId: api.conversationId, callId: api.callId, extensions, chosen }) };
      }, ctx);
      if (made.refusal) return { output: [{ type: 'text', text: made.refusal }], isError: true };
      const { child } = made;
      await api.details({ conversationId: child, tools: [], count: 0 }, ctx);
      const stopMirror = await mirror(entryPages(api, ctx, child), api, ctx, child, toolLine, value => api.details(value, ctx));
      let settled, calls;
      try {
        const handle = await api.conversation(child, ctx);
        settled = await (await handle.submit({ type: 'input', requestId: `subagent:${api.taskId}`, content: taskText(args) }, ctx)).wait(ctx);
      } finally { calls = await stopMirror(); }
      const usage = totalUsage(await api.snapshot(UsageDoc, child, ctx));
      const ran = (await api.snapshot(App, child, ctx)).model;
      // Every call it made, settled, for the page to keep under its line.
      const details = { conversationId: child, ...calls, ...ranOn(ran) };
      if (settled.status !== 'done') {
        return { output: [{ type: 'text', text: `The helper stopped without an answer (${settled.reason}).${ranLine(ran)}` }], isError: true, details, usage };
      }
      const text = answerText(await api.commit(tx => tx.entry(settled.answer), ctx));
      return { output: [{ type: 'text', text: (text || 'The helper finished without saying anything.') + ranLine(ran) }], details, usage };
    }
  });
  const message = defineTool({
    name: 'message_helper',
    description: 'Tell a helper working in the background something while it works: a correction, a detail it needs, ' +
      'or a change of course. It reads it at its next step. Its answer still comes as a message.',
    parameters: { type: 'object', additionalProperties: false, required: ['helper', 'message'], properties: {
      helper: { type: 'string', description: 'The id of the subagent call that started the helper.' },
      message: { type: 'string', description: 'What to tell it.' } } },
    // A rerun after a crash is the same submission, by the call's own task.
    replay: 'safe',
    execute: async (args, api, ctx) => {
      const content = `[Message from the assistant who gave you this task, sent while you work] ${args.message}\n` +
        'It changes your task only as far as it says.';
      const delivered = await steerHelper({ commit: change => api.commit(change, ctx), conversation: id => api.conversation(id, ctx) },
        { conversationId: api.conversationId, callId: args.helper, requestId: `agent:${api.taskId}`, content });
      if (delivered) return { output: [{ type: 'text', text: 'The helper has your message. It reads it at its next step.' }] };
      return { output: [{ type: 'text', text: delivered === false ? 'That helper has already finished, so it can\'t take a message. Its answer comes as a message.'
        : 'No helper started by that call is working in this conversation.' }], isError: true };
    }
  });
  return defineExtension({ name: SUBAGENT_EXTENSION, tools: [tool, message], tasks: [helper] });
}

const MODEL_ARGUMENT = 'The model the helper runs on, by its name as your settings show it. Leave it out for your own. ' +
  'Only the models offered to you here; any other is refused with the list.';
const THINKING_ARGUMENT = 'How much the helper thinks before it answers: off, minimal, low, medium, high, xhigh or max, ' +
  'one its model supports. Leave it out for your own level.';

// The agent definition the conversation runs now (runtime.mjs).
async function definitionOf(tx, conversationId) {
  const stored = await tx.doc(Definitions);
  return stored.byDigest[stored.conversations[conversationId]];
}

// The model and thinking a helper runs on, from its call's `model` and
// `thinking` (or a workflow's step's): the agent's own unless they name
// others. A model is one of those Rails offers the agent (the definition's
// `helperModels`, as its settings name them) that this sidecar runs, by its
// label, its route, or its name where only one has it; a level, one that
// model supports. Left out, the level is the agent's own, at the nearest the
// model supports, as the agent itself runs. Anything else is refused in
// words, with the choices: a helper never runs on what it wasn't asked to.
export function chooseModel(definition, modelOf, { model, thinking }) {
  if (!definition) return { refusal: 'This conversation has no agent to lend a helper its model yet.' };
  const offered = (Array.isArray(definition.helperModels) ? definition.helperModels : []).filter(choice => modelOf(choice.id));
  const labelOf = id => offered.find(choice => choice.id === id)?.label ?? id;
  let id = definition.model;
  if (model !== undefined && model !== null) {
    const words = String(model).trim().toLowerCase();
    const exact = offered.filter(choice => choice.id === words || choice.label.toLowerCase() === words);
    const found = exact.length ? exact : offered.filter(choice => choice.name.toLowerCase() === words);
    if (found.length > 1) return { refusal: `“${model}” is more than one model here. Name one: ${found.map(choice => choice.label).join(', ')}.` };
    if (!found.length) {
      return { refusal: `There is no model “${model}” for a helper here. ` +
        (offered.length ? `Choose one of: ${offered.map(choice => choice.label).join(', ')}.` : 'Leave the model out: only your own is offered.') };
    }
    id = found[0].id;
  }
  const levels = getSupportedThinkingLevels(modelOf(id));
  if (thinking !== undefined && thinking !== null && !levels.includes(thinking)) {
    return { refusal: `${labelOf(id)} can't think at “${thinking}”. Its levels: ${levels.join(', ')}.` };
  }
  const named = (model ?? thinking) !== undefined && (model ?? thinking) !== null;
  return { id, label: labelOf(id), thinkingLevel: thinking ?? clampThinkingLevel(modelOf(id), definition.thinkingLevel), ...(named ? { named } : {}) };
}

// What a helper ran on, for Rails; and in words for the agent its answer goes
// to, when it asked for a model or level (its own needs no saying).
const ranOn = chosen => chosen ? { model: chosen.id, thinking: chosen.thinkingLevel } : {};
const ranLine = chosen => chosen?.named ? `\n\n(The helper ran on ${chosen.label}, thinking: ${chosen.thinkingLevel}.)` : '';

const helperExtensions = agent => agent.extensions.filter(extension => ![SUBAGENT_EXTENSION, DESKTOP_EXTENSION].includes(extension.name));
const taskText = ({ task, context }) => context ? `${task}\n\nContext:\n${context}` : task;

// The helper's conversation: the parent's agent without helpers or the
// desktop, whose calls reach Rails as the root conversation's, under the call
// that started it. `background`: its requests count against its own bound.
// `chosen`: its model and level (chooseModel); one started before helpers had
// a choice has none and runs on the agent's, which it copies.
async function createChild(tx, { owner, conversationId, callId, extensions, background = false, chosen }) {
  const parent = await tx.doc(App, conversationId);
  if (!parent.actorId || !parent.workspaceId) throw new Error('scope_missing');
  const created = await tx.createConversation({ ownership: { kind: 'task', taskId: owner } });
  const scope = await tx.doc(App, created.id);
  scope.actorId = parent.actorId; scope.workspaceId = parent.workspaceId; scope.cwd = parent.cwd;
  scope.root = parent.root ? { conversationId: parent.root.conversationId, callId: `${parent.root.callId}/${callId}` }
    : { conversationId, callId };
  if (background) scope.root.background = true;
  const stored = await tx.doc(Definitions);
  const digest = stored.conversations[conversationId];
  if (digest) stored.conversations[created.id] = digest;
  const instructions = [stored.byDigest[digest]?.instructions, HELPER_INSTRUCTIONS].filter(Boolean).join('\n\n');
  const route = chosen && { provider: chosen.id.slice(0, chosen.id.indexOf('/')), modelId: chosen.id.slice(chosen.id.indexOf('/') + 1) };
  await configure(tx, created.id, { extensions, instructions, ...(chosen ? { model: route, thinkingLevel: chosen.thinkingLevel } : {}) });
  if (chosen) scope.model = chosen;
  return created.id;
}

// Starts a background helper, at most once for the call (a rerun after a crash
// finds the one it started), unless as many as the caps allow already run.
async function startHelper(helper, api, ctx, modelOf, { task, context, model, thinking }) {
  // Its line on the page is the call's own, which a script's call has not.
  if (api.callId.includes('/')) {
    return { output: [{ type: 'text', text: 'Start a helper in the background with a call of your own, not from a script.' }], isError: true };
  }
  const refusal = await api.commit(async tx => {
    const helpers = await tx.doc(Helpers);
    if (helpers.byCall[api.taskId] !== undefined) return null;
    const chosen = chooseModel(await definitionOf(tx, api.conversationId), modelOf, { model, thinking });
    if (chosen.refusal) return chosen.refusal;
    const full = await noRoom(tx, api.conversationId);
    if (full) return full;
    helpers.byCall[api.taskId] = await tx.createTask(helper, { callId: api.callId, task, context: context ?? null, model: chosen },
      { ownership: { kind: 'conversation' }, conversationId: api.conversationId, background: true });
    return null;
  }, ctx);
  if (refusal) return { output: [{ type: 'text', text: refusal }], isError: true };
  return { output: [{ type: 'text', text: backgroundStarted(api.callId) }], details: { background: true } };
}

// Tells a background helper something while it works: `content` joins its turn
// as a steer, read at its next step, and gives that turn a fresh request
// bound, as a steer to the agent does (runtime.mjs `submit`). A helper with no
// turn to join (not yet started, or ended) takes nothing. True when it took
// it, false when it couldn't, undefined when no helper of the conversation's
// has that call. The same request id is the same message.
export async function steerHelper({ commit, conversation }, { conversationId, callId, requestId, content }) {
  const found = await commit(async tx => {
    const task = (await tx.scanTasks({ conversationId, kind: HELPER_TASK, order: 'descending' }, 1000)).items
      .find(record => record.input?.callId === callId);
    if (!task || task.state.status === 'terminal') return { task };
    return { task, child: (await tx.scanConversations({ ownerTaskId: task.id }, 1)).items[0]?.id };
  });
  if (!found.task) return undefined;
  if (found.child === undefined) return false;
  const handle = await conversation(found.child);
  return commit(async tx => {
    try {
      await handle.submit(tx, { type: 'input', requestId: `steer:${requestId}`, content, whenBusy: 'steer', whenIdle: 'reject' });
    } catch (error) {
      if (error instanceof ConversationIdle) return false;
      throw error;
    }
    (await tx.doc(App, found.child)).bounds = { requests: 0 };
    return true;
  });
}

// Why no further helper may start in the conversation now, in words, or null.
async function noRoom(tx, conversationId) {
  const running = (await helperTasks(tx, { kind: HELPER_TASK })).filter(record => record.state.status !== 'terminal');
  if (running.filter(record => record.conversationId === conversationId).length >= HELPERS_PER_CONVERSATION) {
    return `${HELPERS_PER_CONVERSATION} helpers are already working in this conversation, the most at once. Wait for one to finish, or do it yourself.`;
  }
  if (running.length >= HELPERS_PER_SIDECAR) {
    return `${HELPERS_PER_SIDECAR} helpers are already working across every conversation here, the most at once. Wait for one to finish, or do it yourself.`;
  }
  return null;
}

async function helperTasks(tx, filter) {
  const records = [];
  for (let page, cursor; !page || (cursor = page.next) !== undefined;) {
    page = await tx.scanTasks(filter, 100, cursor);
    records.push(...page.items);
    if (!page.items.length) break;
  }
  return records;
}

// A background helper Rails starts itself, for one step of a workflow
// (Rails' Workflow::Step), under the same caps as the agent's own. Rails names
// the call; a call that started one, running or ended, never starts another,
// so Rails may ask again after any failure. `{ started }` says whether this
// request started it; `{ refusal }` says, in words, why none may start now,
// and `{ invalid }` why it never may: a model or level it can't have.
export async function startNamedHelper(tx, helper, { conversationId, callId, task, context, model, thinking, modelOf }) {
  const started = (await helperTasks(tx, { conversationId, kind: HELPER_TASK })).some(record => record.input?.callId === callId);
  if (started) return { started: false };
  const chosen = chooseModel(await definitionOf(tx, conversationId), modelOf, { model, thinking });
  if (chosen.refusal) return { invalid: chosen.refusal };
  const refusal = await noRoom(tx, conversationId);
  if (refusal) return { refusal };
  await tx.createTask(helper, { callId, task, context: context ?? null, model: chosen },
    { ownership: { kind: 'conversation' }, conversationId, background: true });
  return { started: true };
}

// The task behind a background helper. `start` makes its conversation, `run`
// gives it the task and waits, telling Rails what it does, and `report` tells
// Rails how it ended, again later while Rails cannot take it. Aborting it (a
// person's Cancel) aborts the conversation it owns with it.
function helperTask({ toolLine, report, retryMs, reportForMs }) {
  const send = async (runtime, ctx, data) => {
    const scope = await runtime.snapshot(App, runtime.conversationId, ctx);
    if (typeof report !== 'function') throw new Error('rails_helper_callback_required');
    return report({ actorId: scope.actorId, workspaceId: scope.workspaceId, conversationId: String(runtime.conversationId), ...data });
  };
  return defineTask({
    name: HELPER_TASK,
    version: 1,
    initial: () => ({ phase: 'start' }),
    phases: {
      start: async (task, runtime, ctx) => {
        const extensions = helperExtensions(await runtime.agent(ctx));
        await runtime.commit(async tx => {
          const existing = (await tx.scanConversations({ ownerTaskId: runtime.taskId }, 1)).items[0];
          const child = existing?.id ?? await createChild(tx, { owner: runtime.taskId, conversationId: runtime.conversationId,
            callId: task.input.callId, extensions, background: true, chosen: task.input.model });
          return { status: 'running', checkpoint: { phase: 'run', child } };
        }, ctx);
      },
      run: async (task, runtime, ctx) => {
        const { child } = task.state.checkpoint;
        const { callId } = task.input;
        const ran = ranOn(task.input.model);
        const progress = ({ tools, count }) => send(runtime, ctx, { callId, state: 'running', task: task.input.task, tools, count, ...ran }).catch(() => {});
        await progress({ tools: [], count: 0 });
        const stopMirror = await mirror(contextPages(runtime, ctx, child), runtime, ctx, child, toolLine, progress, PROGRESS_MS);
        let settled, calls;
        try {
          const handle = await runtime.conversation(child, ctx);
          settled = await (await handle.submit({ type: 'input', requestId: `helper:${runtime.taskId}`, content: taskText(task.input) }, ctx)).wait(ctx);
          // A message that came as it wrote that answer is read in a turn of its
          // own (steerHelper), whose answer is then the newest.
          await handle.waitForIdle(ctx);
        } finally { calls = await stopMirror(); }
        const doc = await runtime.snapshot(UsageDoc, child, ctx);
        const usage = { ...totalUsage(doc), ...usageRows(doc) };
        const view = await runtime.context(child, ctx);
        const answered = view.entries.findLast(entry => entry.id > (settled.answer ?? settled.entry ?? 0) &&
          (entry.model ?? []).some(message => message.role === 'assistant' && message.stopReason === 'stop')) ??
          (settled.status === 'done' ? view.entries.find(entry => entry.id === settled.answer) : undefined);
        const ending = answered ? { state: 'done', answer: (answerText(answered) || 'The helper finished without saying anything.') + ranLine(task.input.model) }
          : { state: 'failed', reason: String(settled.reason ?? 'unknown') };
        await runtime.commit(() => ({ status: 'running', checkpoint: { phase: 'report', child, since: runtime.now(), attempt: 0,
          report: { callId, task: task.input.task, ...ending, tools: calls.tools, count: calls.count, usage, ...ran } } }), ctx);
      },
      report: async (task, runtime, ctx) => {
        const { report: last, since, attempt } = task.state.checkpoint;
        try { await send(runtime, ctx, last); } catch {
          if (runtime.now() - since < reportForMs) {
            const wait = Math.min(retryMs * 2 ** attempt, REPORT_RETRY_MAX_MS);
            return runtime.sleepUntil(runtime.now() + wait, { ...task.state.checkpoint, attempt: attempt + 1 }, ctx);
          }
        }
        await runtime.commit(async tx => {
          await forget(tx, runtime.taskId);
          return { status: 'terminal', outcome: { status: 'completed', result: null } };
        }, ctx);
      }
    },
    abort: (_task, runtime, ctx) => runtime.commit(async tx => {
      await forget(tx, runtime.taskId);
      return { status: 'terminal', outcome: { status: 'aborted' } };
    }, ctx)
  });
}

async function forget(tx, taskId) {
  const helpers = await tx.doc(Helpers);
  for (const [call, id] of Object.entries(helpers.byCall)) if (id === taskId) delete helpers.byCall[call];
}

// The child's committed entries after `read`, for mirror(): a tool reads them
// in its own commits; a task, which commits no reads, from the child's context.
function entryPages(api, ctx, child) {
  return async read => {
    const items = [];
    let page;
    do {
      page = await api.commit(tx => tx.scanEntries({ conversationId: child, minEntryId: read + 1, order: 'ascending' }, 64), ctx);
      items.push(...page.items);
      if (page.items.length) read = Math.max(read, ...page.items.map(entry => entry.id));
    } while (page.next !== undefined && page.items.length);
    return items;
  };
}
function contextPages(runtime, ctx, child) {
  return async read => {
    const view = await runtime.context(child, ctx);
    return view.entries.map((entry, index) => ({ id: entry.id, model: view.contributions[index] })).filter(entry => entry.id > read);
  };
}

// Copies the child's calls into this call's details while it works, at most
// every MIRROR_MS, so Rails shows them under the helper's line: what each was
// given and what it has printed, or once it is done, how it ended and what came
// back. A call's input and result are the child's committed entries, read when
// its calls change; its progress is its slot. A call that leaves its slot with
// no result recorded ended all the same, so no line says "Running" after its
// call is over. Stopping returns every call, settled, for the helper's result.
async function mirror(pages, observer, ctx, child, toolLine, publish, intervalMs = MIRROR_MS) {
  const watch = await observer.watchDoc(LiveDoc, child, ctx);
  const lines = new Map();
  let latest = watch.value, read = 0, count = 0, seen = '', shown = '', timer, writing = Promise.resolve(), stopped = false;
  const line = (callId, name) => {
    if (!lines.has(callId)) { count++; lines.set(callId, { callId, name, status: 'running', output: '' }); }
    for (const old of [...lines.keys()].slice(0, -KEPT_CALLS)) lines.delete(old);
    return lines.get(callId);
  };
  const settle = message => settleCall(line, message);
  const readEntries = async () => {
    for (const entry of await pages(read)) { read = Math.max(read, entry.id); (entry.model ?? []).forEach(settle); }
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
    writing = writing.then(() => publish({ conversationId: child, tools, count })).catch(() => {});
  };
  let updating = Promise.resolve();
  watch.start(async call => {
    if (call.kind !== 'value') return;
    latest = call.retired ? undefined : call.value;
    timer ??= setTimeout(() => { updating = updating.then(write).catch(() => {}); }, intervalMs);
  });
  return async () => {
    stopped = true; clearTimeout(timer); await watch.stop(); await updating; await writing;
    latest = undefined;
    await readEntries().catch(() => {});
    for (const each of lines.values()) if (each.status === 'running') each.status = 'done';
    return { tools: [...lines.values()].map(each => ({ ...each, output: tail(each.output, KEPT_BYTES) })), count };
  };
}

// One model message's calls, as `line(callId, name)` keeps them: what each was
// given and, once back, how it ended and the end of what came back.
function settleCall(line, message) {
  if (message.role === 'assistant') {
    for (const block of Array.isArray(message.content) ? message.content : []) {
      if (block.type === 'toolCall') line(block.id, block.name).arguments ??= input(block.arguments);
    }
  } else if (message.role === 'toolResult' && message.toolCallId) {
    Object.assign(line(message.toolCallId, message.toolName), { status: message.isError ? 'failed' : 'done', output: tail(resultText(message), KEPT_BYTES) });
  }
}

// What a cancelled helper had done, from its entries: every call it made, any
// the cancel cut off as stopped. The newest KEPT_CALLS, and how many.
export function callsMade(entries) {
  const lines = new Map();
  const line = (callId, name) => {
    if (!lines.has(callId)) lines.set(callId, { callId, name, status: 'stopped', output: '' });
    return lines.get(callId);
  };
  for (const entry of entries) {
    for (const message of entry.model ?? []) {
      settleCall(line, message);
      if (message.role === 'toolResult' && entry.data?.diagnostics?.some(each => each.code === 'aborted')) line(message.toolCallId).status = 'stopped';
    }
  }
  return { tools: [...lines.values()].slice(-KEPT_CALLS), count: lines.size };
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
