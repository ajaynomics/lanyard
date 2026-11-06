import { obj, str, arr } from '@earendil-works/pi-schema';
import { defineExtension, defineTool, defineTask, configure } from '@earendil-works/pi-durable';
import { App } from './state.mjs';
import { textResult } from './extensions.mjs';

const abort = (_task, runtime, ctx) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), ctx);
export function workflowExtension(options) {
  const Child = defineTask({ name: 'app.child', version: 1, initial: () => ({ phase: 'create' }), abort,
    phases: {
      create: async (task, rt, ctx) => {
        const source = await rt.snapshot(App, rt.conversationId, ctx);
        await rt.commit(async tx => {
          const existing = (await tx.scanConversations({ ownerTaskId: task.id }, 1)).items[0];
          const child = existing ?? await tx.createConversation({ ownership: { kind: 'task', taskId: task.id } });
          await configure(tx, child.id, { model: options.model, thinkingLevel: 'medium', cwd: source.cwd,
            extensions: options.childExtensions(source), tools: options.childTools() });
          const app = await tx.doc(App, child.id);
          app.actorId = source.actorId; app.workspaceId = source.workspaceId; app.cwd = source.cwd;
          return { status: 'running', checkpoint: { phase: 'run', child: child.id } };
        }, ctx);
      },
      run: async (task, rt, ctx) => {
        const child = await rt.conversation(task.state.checkpoint.child, ctx);
        const sub = await child.submit({ type: 'input', requestId: `child:${task.id}`, content: task.input.prompt }, ctx);
        const result = await sub.wait(ctx);
        if (result.status !== 'done') {
          await rt.commit(() => ({ status: 'terminal', outcome: { status: 'failed', error: { message: 'child_unanswered' } } }), ctx);
          return;
        }
        const context = await rt.context(child.id, ctx);
        const answer = context.entries.find(e => e.id === result.answer);
        await rt.commit(() => ({ status: 'terminal', outcome: { status: 'completed',
          result: { conversationId: child.id, submissionId: sub.id, answer: answer?.model ?? [] } } }), ctx);
      }
    } });
  const Workflow = defineTask({ name: 'app.workflow', version: 1, initial: () => ({ phase: 'spawn', index: 0, results: [] }), abort,
    phases: {
      spawn: async (task, rt, ctx) => {
        const state = task.state.checkpoint;
        if (state.index === task.input.stages.length) {
          await rt.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: state.results } }), ctx);
          return;
        }
        await rt.commit(async tx => {
          const ids = [];
          for (const prompt of task.input.stages[state.index]) ids.push(await tx.createTask(Child,
            { prompt: `${prompt}\n\nPrior stage results:\n${JSON.stringify(state.results.at(-1) ?? [])}` },
            { ownership: { kind: 'task', taskId: task.id } }));
          return { status: 'waiting', on: ids, policy: 'failFast', checkpoint: { ...state, phase: 'collect', ids } };
        }, ctx);
      },
      collect: async (task, rt, ctx) => {
        const state = task.state.checkpoint;
        const outcomes = await rt.outcomes(state.ids, ctx);
        const failed = outcomes.some(o => o.status !== 'completed');
        await rt.commit(() => failed ? { status: 'terminal', outcome: { status: 'failed', error: { message: 'workflow_stage_failed' } } } :
          { status: 'running', checkpoint: { phase: 'spawn', index: state.index + 1,
            results: [...state.results, outcomes.map(o => o.result)] } }, ctx);
      }
    } });
  const tool = defineTool({ name: 'workflow', description: 'Run bounded stages of owned children; each stage receives prior outputs.',
    callers: ['model'], replay: 'safe',
    parameters: obj({ stages: arr(arr(str({ minLength: 1 }), { minItems: 1, maxItems: options.maxConcurrency }),
      { minItems: 1, maxItems: options.maxTasks }) }),
    execute: async (args, api, ctx) => {
      if (args.stages.flat().length > options.maxTasks) throw new Error('workflow_task_limit');
      const id = await api.commit(async tx => {
        const app = await tx.doc(App, api.conversationId);
        const key = `${api.taskId}:${api.callId}`;
        if (app.workflows[key]) return app.workflows[key];
        const id = await tx.createTask(Workflow, args, { ownership: { kind: 'task', taskId: api.taskId } });
        app.workflows[key] = id;
        return id;
      }, ctx);
      const settled = await api.waitForTask(id, ctx);
      const outcome = settled.state.outcome;
      return { ...textResult(outcome), isError: outcome.status !== 'completed' };
    } });
  return defineExtension({ name: 'omakase.workflows', tools: [tool], tasks: [Child, Workflow] });
}
