import { readFile, appendFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { obj, num, str } from '@earendil-works/pi-schema';
import { defineExtension, defineTool, defineTask } from '@earendil-works/pi-durable';
import { createServer, railsCallbacks } from '../server.mjs';
import { BACKGROUND_CONTEXT as ctx, liveTaskGraph } from '../runtime.mjs';
import { App } from '../state.mjs';
import { scriptedProvider } from './scripted-provider.mjs';
import { nonLocalAttempts } from './local-only.mjs';
// ---- test-only native extensions, selected by name in the process config ----
// None of them is installed by the production server.
const untilAborted = (signal, ms = 30000) => new Promise((resolve, reject) => {
  const timer = setTimeout(resolve, ms);
  signal?.addEventListener('abort', () => { clearTimeout(timer); reject(new Error('aborted')); }, { once: true });
});

// A harmless local effect: append one line, mark started, then wait. Its replay
// policy is chosen per process so a fixture can change it between restarts.
const effect = (cwd, replay) => defineExtension({ name: `fixture.effect.${replay}`, tools: [defineTool({
  name: 'fx_effect', description: 'Append one effect line, then wait', parameters: obj({}), replay,
  execute: async (_args, _api, ctx) => {
    await appendFile(join(cwd, 'effect-count'), 'once\n');
    await writeFile(join(cwd, 'effect-started'), '1');
    await untilAborted(ctx.abortSignal);
    return { output: [{ type: 'text', text: 'effect finished' }] };
  } })] });

// Attempts one Node fetch to a non-loopback address from inside the sidecar.
const fetcher = defineExtension({ name: 'fixture.fetch', tools: [defineTool({
  name: 'fx_fetch', description: 'Fetch a URL', parameters: obj({ url: str() }), replay: 'safe',
  execute: async args => {
    const response = await fetch(args.url, { signal: AbortSignal.timeout(5000) });
    return { output: [{ type: 'text', text: `status ${response.status}` }] };
  } })] });

// A background task that runs until aborted; its kind is unknown to a process
// started without this extension (an incompatible registry).
const Background = defineTask({ name: 'fixture.background', version: 1, initial: () => ({ phase: 'run' }),
  abort: (_task, rt, c) => rt.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), c),
  phases: { run: (_task, _rt, c) => untilAborted(c.abortSignal, 600000) } });
const background = defineExtension({ name: 'fixture.background', tasks: [Background], tools: [defineTool({
  name: 'fx_background', description: 'Start background work', parameters: obj({}), replay: 'safe',
  execute: async (_args, api, c) => {
    const id = await api.commit(tx => tx.createTask(Background, {}, { ownership: { kind: 'conversation' }, conversationId: api.conversationId, background: true }), c);
    return { output: [{ type: 'text', text: `started ${id}` }] };
  } })] });

// A replay-safe tool that waits; a crash during it is a restart of a running task.
const sleeper = cwd => defineExtension({ name: 'fixture.sleep', tools: [defineTool({
  name: 'fx_sleep', description: 'Wait', parameters: obj({}), replay: 'safe',
  execute: async (_args, _api, ctx) => {
    await appendFile(join(cwd, 'sleep-starts'), 'start\n');
    await untilAborted(ctx.abortSignal);
    return { output: [{ type: 'text', text: 'slept' }] };
  } })] });

export function fixtureExtensions(names = [], cwd) {
  return names.map(name => {
    if (name === 'effect-safe') return effect(cwd, 'safe');
    if (name === 'effect-unsafe') return effect(cwd, 'unsafe');
    if (name === 'fetch') return fetcher;
    if (name === 'background') return background;
    if (name === 'sleep') return sleeper(cwd);
    throw new Error(`unknown_fixture_extension_${name}`);
  });
}

const input = JSON.parse(await readFile(process.argv[2], 'utf8'));
// recordContexts: append each request's actual model context (its system
// message with sections, and the other messages), as the scripted model
// received it, to a file the fixture reads.
// { fixtureHang: true }: a model request that marks model-started in cwd and
// never answers, so a fixture can kill the process mid-request.
const hang = async () => {
  await writeFile(join(input.cwd, 'model-started'), '1');
  await new Promise(resolve => setTimeout(resolve, 600000));
};
const scripted = (input.responses ?? []).map(response => response?.fixtureHang ? hang : response);
const responses = !input.recordContexts ? scripted : scripted.map(response => async (context, ...rest) => {
  await appendFile(input.recordContexts, JSON.stringify({ system: context.messages.filter(m => m.role === 'system'),
    messages: context.messages.filter(m => m.role !== 'system') }) + '\n');
  return typeof response === 'function' ? response(context, ...rest) : response;
});
const provider = scriptedProvider(responses);
// Without a Rails URL: synthetic members (default alice in workspace one) and a
// local effect log standing in for Rails' committed note.
const members = input.members ?? { alice: ['one'] };
let notes = 0;
const callbacks = input.railsUrl ? railsCallbacks(input) : {
  authorize: async scope => ({ ...scope, allowed: (members[scope.actorId] ?? []).includes(scope.workspaceId), cwd: input.cwd }),
  railsEffect: async effect => {
    await appendFile(`${input.cwd}/effects.jsonl`, JSON.stringify(effect) + '\n');
    return { noteId: ++notes, ...effect.arguments };
  }
};
const app = await createServer(input, { ...provider, ...(input.model ? { model: input.model } : {}), ...callbacks,
  extensions: fixtureExtensions(input.fixtureExtensions, input.cwd) });
const address = await app.listen(0);
process.send?.({ type: 'ready', port: address.port, readiness: app.readiness() });
// Test-only IPC inspection of Durable internals. The HTTP API deliberately
// returns only the browser DTO, so internal evidence never travels over it.
async function inspect(id) {
  const harness = app.runtime.harness;
  const conversation = await harness.conversation(id, ctx);
  const entries = (await conversation.entries({ order: 'ascending' }, 10000, undefined, ctx)).items;
  const liveTasks = Object.values((await liveTaskGraph(harness, ctx)).tasks)
    .map(t => ({ id: t.id, kind: t.kind, conversationId: t.conversationId, owner: t.owner }));
  const app_ = await harness.snapshot(App, id, ctx);
  const rootAgent = await conversation.agent(ctx);
  const children = (await harness.commit(tx => tx.scanConversations({ ownerConversationId: id }, 1000), ctx)).items;
  const childViews = [];
  for (const child of children) {
    const childConversation = await harness.conversation(child.id, ctx);
    const childEntries = (await childConversation.entries({ order: 'ascending' }, 10000, undefined, ctx)).items;
    const submissions = (await app.runtime.harness.inspect(ctx)).submissions.filter(s => s.conversationId === child.id).length;
    const agent = await childConversation.agent(ctx);
    childViews.push({ id: child.id, app: await harness.snapshot(App, child.id, ctx), entries: childEntries,
      openSubmissions: submissions, model: agent.model, tools: agent.tools.map(t => t.name).sort() });
  }
  const workflows = [];
  for (const taskId of Object.values(app_?.workflows ?? {})) workflows.push(await harness.getTask(taskId, ctx));
  return JSON.parse(JSON.stringify({ entries, liveTasks: liveTasks.length, live: liveTasks, app: app_, children: childViews,
    tools: rootAgent.tools.map(t => t.name).sort(),
    workflows, inspection: await harness.inspect(ctx), modelCalls: provider.faux.state.callCount, nonLocalAttempts: nonLocalAttempts() }));
}
process.on('message', async message => {
  if (message === 'stop') { await app.close(); process.disconnect(); return; }
  if (message?.type === 'stats') {
    process.send({ type: 'inspection', nonce: message.nonce, value: { modelCalls: provider.faux.state.callCount, nonLocalAttempts: nonLocalAttempts() } });
    return;
  }
  if (message?.type === 'inspect') {
    try { process.send({ type: 'inspection', nonce: message.nonce, value: await inspect(message.id) }); }
    catch (error) { process.send({ type: 'inspection', nonce: message.nonce, error: error.message }); }
  }
});
process.once('SIGTERM', async () => { await app.close(); process.disconnect?.(); });
