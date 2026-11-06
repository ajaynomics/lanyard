import { isAbsolute, extname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { access as fileExists, mkdir, mkdtemp } from 'node:fs/promises';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels, getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai';
import { obj, str, num, int, bool, nul, unknown, lit, oneOf, opt, arr, tuple, map, union, nullable } from '@earendil-works/pi-schema';
import { Harness, createRegistry, ProviderDoc, LiveDoc, UsageDoc, ConversationTranscript, DEFAULT_COMPACTION_POLICY,
  defineExtension, defineTool, defineTask, section, hook, ToolTask } from '@earendil-works/pi-durable';
import { createToolSearchExtension } from '@earendil-works/pi-durable/tool-search';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { NodeExecutionEnv } from '@earendil-works/pi-durable/env/node';
import { ok as envOk, err as envErr } from '@earendil-works/pi-durable/env';
import { createCodingTools } from '@earendil-works/pi-durable/tools';
import { createNodePhotonImages } from '@earendil-works/pi-durable/images/node';
import { createCodemodeExtension } from '@earendil-works/pi-durable/codemode';
import { CodemodeSandbox } from '@earendil-works/pi-codemode';
import { App, Admission, McpGrants, digest, ApiError, scopeMatches, requiredString, validateAnswer } from './state.mjs';
import { applicationExtension, approvedResources, approvedModules } from './extensions.mjs';
import { searchExtension, connectMcp } from './integrations.mjs';
import { workflowExtension } from './workflows.mjs';
import { ownStore } from './ownership.mjs';

// Re-exported so fixtures outside this package need no private dependency path.
export { context as BACKGROUND_CONTEXT };

// `none` (default): no read/write/edit/bash and no execution environment. One
// sidecar process serves every workspace, and a working directory is not a
// filesystem boundary, so shell/file tools could reach other workspaces, the
// Durable store, its ownership lock and the sidecar configuration.
// `trusted-local-single-tenant`: an explicit operator opt-in for a single
// trusted tenant on a local machine (and the fixture suite). It is not
// isolation. A qualified per-workspace execution environment is not provided.
export const EXECUTION_MODES = Object.freeze(['none', 'trusted-local-single-tenant']);
export const DEFAULT_MODEL = Object.freeze({ provider: 'openai', modelId: 'gpt-6.1-sol' });
// maxRetries/retryBaseDelayMs: Durable's own generation retries of a retryable
// provider error (rate limit, overload, 5xx, timeout) or of a request a crash cut
// off; every attempt reserves a slot in maxRequests at the Models seam. 0 disables.
// persistWithinMs: how long streamed progress may stay in memory before it is
// stored (Durable's default is 1000 ms); a crash loses at most about this much.
export const DEFAULT_LIMITS = Object.freeze({ maxRequests: 64, maxContinuations: 8, maxRuntimeMs: 300000,
  humanTimeoutMs: 86400000, maxGrantUses: 4, maxTasks: 8, maxConcurrency: 2, codeTimeoutMs: 30000, restartLimit: 5,
  maxRetries: 2, retryBaseDelayMs: 2000, persistWithinMs: 100 });
// Durable's automatic compaction (summarise older context before it overflows),
// on by default with Durable's thresholds; `config.compaction` overrides fields.
export const DEFAULT_COMPACTION = Object.freeze({ ...DEFAULT_COMPACTION_POLICY, enabled: true });
// `host` (default): the tool shell keeps the host network. `isolated`: every tool
// shell command runs in a fresh unprivileged user+network namespace (Linux
// `unshare`), so it has no route off the host (not even host loopback).
// Readiness fails closed when the kernel refuses user namespaces.
export const SHELL_NETWORK_MODES = Object.freeze(['host', 'isolated']);
// Readiness reasons. Each is actionable and carries no path, token or raw error.
export const READINESS_REASONS = Object.freeze(['store_already_owned', 'storage_unavailable', 'store_recovery_failed',
  'approved_model_unavailable', 'incompatible_definitions', 'absolute_store_required', 'invalid_execution_mode',
  'unapproved_resource', 'invalid_extension_module', 'shell_isolation_unavailable', 'invalid_mcp_scope', 'mcp_unavailable',
  'provider_credential_missing']);
// The SDK an application extension module receives. Modules export
// `default (sdk) => Extension | Extension[]` and need no dependency path of their own.
// `schema` holds @earendil-works/pi-schema's JSON Schema builders; `obj()` is
// closed (no additional properties) unless given `{ open: true }`.
export const SCHEMA = Object.freeze({ obj, str, num, int, bool, nul, unknown, lit, oneOf, opt, arr, tuple, map, union, nullable });
export const EXTENSION_SDK = Object.freeze({ defineExtension, defineTool, defineTask, section, hook, schema: SCHEMA });
// Every live task of the Session, read once from the task graph.
export async function liveTaskGraph(harness, ctx = context) {
  const observation = await harness.observeTaskGraph({ advance() {}, end() {} }, ctx);
  try { return observation.value; } finally { observation.detach(); }
}
function compactionSettings(value = {}) {
  const settings = { ...DEFAULT_COMPACTION };
  for (const [key, entry] of Object.entries(value ?? {})) {
    if (key === 'enabled' ? typeof entry !== 'boolean' : !(key in settings) || !Number.isInteger(entry) || entry < 0) throw new Error('invalid_compaction');
    settings[key] = entry;
  }
  return settings;
}
// Entries read per storage page when a snapshot pages the whole history.
const ENTRY_PAGE = 500;
async function allEntries(conversation) {
  const entries = [];
  let cursor;
  do {
    const page = await conversation.entries({ order: 'ascending' }, ENTRY_PAGE, cursor, context);
    entries.push(...page.items);
    cursor = page.next;
  } while (cursor !== undefined);
  return entries;
}
// Load every page a ConversationTranscript lacks: the start, then each gap.
async function completeTranscript(transcript, view) {
  for (let next; ; view = next) {
    const earlier = view.items[0]?.kind === 'earlier';
    const gap = earlier ? undefined : view.items.find(item => item.kind === 'gap');
    if (!earlier && !gap) return view;
    next = earlier ? await transcript.loadEarlier(context) : await transcript.fillGap(gap, context);
    if (next.items === view.items) throw new Error('transcript_incomplete');
  }
}
// A run that did not answer because crash-loop protection ended its work.
const CRASH_LOOP = 'restart_limit';
const crashLoopIn = entries => entries.some(entry => entry.kind === 'pi.tool-result' &&
  (entry.data?.diagnostics ?? []).some(d => d?.code === CRASH_LOOP));
// Image formats a reader might mistake for text. A file with one of these
// extensions that the read tool did not return as an image fails clearly.
const IMAGE_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.heic', '.heif',
  '.avif', '.ico', '.jxl']);
const readGuard = defineExtension({ name: 'omakase.read-guard', hooks: [hook(ToolTask, {
  afterTool: async (call, result) => {
    if (call.name !== 'read' || result.isError || typeof call.arguments?.path !== 'string') return undefined;
    if (!IMAGE_EXTENSIONS.has(extname(call.arguments.path).toLowerCase())) return undefined;
    if ((result.output ?? []).some(block => block.type === 'image')) return undefined;
    return { output: [{ type: 'text', text: `${call.arguments.path} is not a supported image (jpg, png, gif, webp, bmp); it was not read as text.` }],
      isError: true, diagnostics: [{ severity: 'error', code: 'unsupported_image', message: 'unsupported image' }] };
  }
})] });
class BootError extends Error {}
export const mcpGrantKey = (scope, server) => digest([scope.actorId, scope.workspaceId, server.serverId, server.accountId]);
// Usage as the runtime recorded it. Token counts are measured; a monetary amount
// is shown only when the model route has catalogue prices, and is then labelled
// an estimate, never a provider bill.
export function usageView(usage, priced) {
  if (!usage) return null;
  const keys = ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens'];
  const total = Object.fromEntries(keys.map(key => [key, 0]));
  let cost = 0;
  // pi.usage keeps one row per model and per tool; each is counted once here.
  for (const row of [...Object.values(usage.models ?? {}), ...Object.values(usage.tools ?? {})]) {
    for (const key of keys) total[key] += Number(row?.[key] ?? 0);
    cost += Number(row?.cost?.total ?? 0);
  }
  return { ...total, cost: priced ? { estimatedTotal: cost, basis: 'catalogue_price_estimate' } :
    { estimatedTotal: null, basis: 'price_unavailable' } };
}
const boot = (category, fn) => Promise.resolve().then(fn).catch(error => {
  throw error instanceof BootError ? error : new BootError(READINESS_REASONS.includes(error?.message) ? error.message : category);
});
export function shellIsolationAvailable() {
  const probe = spawnSync('unshare', ['--user', '--map-current-user', '--net', '--', '/bin/true'], { stdio: 'ignore', timeout: 5000, env: { PATH: '/usr/bin:/bin' } });
  return probe.status === 0;
}

export function productionModels(apiKey) {
  requiredString(apiKey, 'openai_key');
  // An application-owned in-memory credential, never Pi's personal auth store.
  const credential = { type: 'api_key', key: apiKey };
  const models = createModels({ credentials: { read: async id => id === 'openai' ? credential : undefined,
    list: async () => [{ providerId: 'openai', type: 'api_key' }],
    modify: async () => { throw new Error('credential_mutation_disabled'); }, delete: async () => { throw new Error('credential_mutation_disabled'); } } });
  models.setProvider(openaiProvider());
  const model = models.getModel(DEFAULT_MODEL.provider, DEFAULT_MODEL.modelId);
  if (!model || model.api !== 'openai-responses' || !getSupportedThinkingLevels(model).includes('medium')) throw new Error('approved_model_unavailable');
  return models;
}

function failure(model, category) {
  return { role: 'assistant', provider: model.provider, api: model.api, model: model.id, content: [],
    stopReason: 'error', errorMessage: category, timestamp: Date.now(),
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
}

// A hook throw is not a hard stop in Durable. Reserve a persisted request slot
// immediately before dispatch to Models, and reject before the provider sees it.
function guardedModels(models, reserve, route, timeoutMs) {
  const dispatch = method => (model, transcript, opts = {}) => {
    const stream = new AssistantMessageEventStream();
    void (async () => {
      try {
        if (model.provider !== route.provider || model.id !== route.modelId) throw new Error('model_route_denied');
        const remaining = Math.min(timeoutMs, await reserve(opts.sessionId));
        const signal = opts.signal ? AbortSignal.any([opts.signal, AbortSignal.timeout(remaining)]) : AbortSignal.timeout(remaining);
        const source = models[method](model, transcript, { ...opts, signal, maxRetries: 0 });
        for await (const event of source) stream.push(event);
        stream.end(await source.result());
      } catch (error) {
        const message = failure(model, ['model_route_denied', 'request_limit', 'runtime_limit', 'scope_missing', CRASH_LOOP].includes(error.message) ? error.message : 'model_request_failed');
        stream.push({ type: 'error', reason: 'error', error: message });
        stream.end(message);
      }
    })();
    return stream;
  };
  const overrides = {
    stream: dispatch('stream'), streamSimple: dispatch('streamSimple'),
    streamDeferred: () => { throw new Error('deferred_disabled'); },
    generateImages: () => { throw new Error('model_helpers_disabled'); },
    classify: () => { throw new Error('model_helpers_disabled'); }
  };
  overrides.complete = async (...args) => overrides.stream(...args).result();
  overrides.completeSimple = async (...args) => overrides.streamSimple(...args).result();
  return new Proxy(models, { get(target, key) { const value = overrides[key] ?? target[key]; return typeof value === 'function' ? value.bind(target) : value; } });
}

export async function createRuntime(config, dependencies = {}) {
  const limits = { ...DEFAULT_LIMITS, ...config.limits };
  for (const [key, value] of Object.entries(limits)) if (!Number.isInteger(value) || value < (key === 'maxRetries' ? 0 : 1)) throw new Error(`invalid_bound_${key}`);
  const compaction = compactionSettings(config.compaction);
  if (!isAbsolute(config.storePath ?? '')) throw new Error('absolute_store_required');
  const models = dependencies.models ?? await boot('provider_credential_missing', () => productionModels(config.openaiApiKey));
  const route = dependencies.model ?? DEFAULT_MODEL;
  const model = models.getModel(route.provider, route.modelId);
  if (!model || !(await models.getAvailable(route.provider)).some(m => m.id === route.modelId)) throw new Error('approved_model_unavailable');
  if (!dependencies.models && (route.provider !== DEFAULT_MODEL.provider || route.modelId !== DEFAULT_MODEL.modelId)) throw new Error('model_route_denied');
  const priced = Object.values(model.cost ?? {}).some(rate => typeof rate === 'number' && rate > 0);
  if (typeof dependencies.authorize !== 'function' && typeof config.authorize !== 'function') throw new Error('authorization_callback_required');
  const authorize = dependencies.authorize ?? config.authorize;
  const railsEffect = dependencies.railsEffect ?? config.railsEffect;
  if (typeof railsEffect !== 'function') throw new Error('rails_effect_callback_required');
  const execution = config.execution ?? 'none';
  if (!EXECUTION_MODES.includes(execution)) throw new Error('invalid_execution_mode');
  const shellNetwork = config.shellNetwork ?? 'host';
  if (!SHELL_NETWORK_MODES.includes(shellNetwork)) throw new Error('invalid_execution_mode');
  if (shellNetwork === 'isolated' && !shellIsolationAvailable()) throw new Error('shell_isolation_unavailable');
  const resources = await approvedResources(config);
  const modules = await approvedModules(config);
  const applicationExtensions = [];
  for (const file of modules) {
    const made = await boot('invalid_extension_module', async () => {
      const exported = (await import(pathToFileURL(file).href)).default;
      if (typeof exported !== 'function') throw new Error('invalid_extension_module');
      const value = await exported(EXTENSION_SDK);
      const list = Array.isArray(value) ? value : [value];
      if (!list.length || list.some(e => !e || typeof e.name !== 'string')) throw new Error('invalid_extension_module');
      return list;
    });
    applicationExtensions.push(...made);
  }
  const owner = await boot('storage_unavailable', () => ownStore(config.storePath));
  let harness, sandbox, mcp, storage;
  const reports = [];
  try {
    const registry = createRegistry();
    const checkPermission = async scope => {
      if (!scope?.actorId || !scope.workspaceId) throw new Error('scope_missing');
      const permission = await authorize({ actorId: scope.actorId, workspaceId: scope.workspaceId });
      if (permission?.allowed !== true || !scopeMatches(permission, scope) || permission.cwd !== scope.cwd) throw new Error('access_denied');
    };
    registry.install(defineExtension({ name: 'omakase.authority', hooks: [hook(ToolTask, {
      beforeTool: async (_call, api, ctx) => {
        await checkPermission(await api.snapshot(App, api.conversationId, ctx));
      }
    })] }));
    if (execution === 'trusted-local-single-tenant') {
      const images = await createNodePhotonImages({ worker: false });
      registry.install(createCodingTools({ images }));
      registry.install(readGuard);
    }
    let workers = 0;
    sandbox = new CodemodeSandbox({ memoryLimitBytes: 32 * 1024 * 1024, timeoutMs: limits.codeTimeoutMs,
      acquireWorker() { if (workers >= limits.maxConcurrency) throw new Error('code_concurrency_limit'); workers++;
        return () => workers--; } });
    registry.install(createCodemodeExtension({ sandbox, models: false }));
    const appExtension = applicationExtension({ ...limits, resources, railsEffect, continuation: id => harness.commit(async tx => {
      const app = await tx.doc(App, id); app.bounds.continuations++;
    }, context) });
    registry.install(appExtension);
    registry.install(searchExtension(dependencies.searchTransport));
    mcp = await boot('mcp_unavailable', () => connectMcp(config.mcp ?? [], { fetch: dependencies.fetch,
      grant: async (scope, server) => {
        const grants = await harness.snapshot(McpGrants, context);
        return grants?.grants[mcpGrantKey(scope, server)]?.status;
      } }));
    for (const extension of mcp.extensions) registry.install(extension);
    // An MCP server with `deferTools: true` offers its tools only once the model
    // finds them with Durable's built-in tool_search, installed only then.
    const toolSearch = (config.mcp ?? []).some(c => c.deferTools === true) ? createToolSearchExtension() : undefined;
    if (toolSearch) registry.install(toolSearch);
    const inScope = (extension, scope) => {
      const index = mcp.extensions.indexOf(extension);
      if (index >= 0) return scopeMatches(config.mcp[index], scope);
      if (extension === toolSearch) return config.mcp.some(c => c.deferTools === true && scopeMatches(c, scope));
      return true;
    };
    for (const extension of applicationExtensions) registry.install(extension);
    for (const extension of dependencies.extensions ?? []) registry.install(extension);
    const workflows = workflowExtension({ ...limits, model: route,
      childExtensions: scope => registry.snapshot().installed().filter(e => e.name !== 'omakase.workflows' && inScope(e, scope)),
      childTools: () => registry.snapshot().tools().filter(({ tool }) => tool.name !== 'workflow').map(({ tool }) => tool) });
    registry.install(workflows);
    // The newest tool round: the entries after the newest assistant answer.
    async function crashLoopedRound(id) {
      const conversation = await harness.conversation(id, context);
      let cursor;
      do {
        const page = await conversation.entries({ order: 'descending' }, 64, cursor, context);
        const end = page.items.findIndex(entry => entry.kind === 'pi.assistant');
        if (crashLoopIn(end < 0 ? page.items : page.items.slice(0, end))) return true;
        if (end >= 0) return false;
        cursor = page.next;
      } while (cursor !== undefined);
      return false;
    }
    const safeModels = guardedModels(models, async sessionId => {
      if (!sessionId) throw new Error('scope_missing');
      const admissions = await harness.snapshot(Admission, context);
      const id = admissions?.sessions[sessionId];
      if (!id) throw new Error('scope_missing');
      await checkPermission(await harness.snapshot(App, id, context));
      // Since 1.5.0 a tool the restart limit cut off gets an error result and the
      // run would go on. Like the 1.4 park, stop instead: no further request
      // after crash-loop protection fired in the newest tool round.
      if (await crashLoopedRound(id)) throw new Error(CRASH_LOOP);
      return harness.commit(async tx => {
        const app = await tx.doc(App, id);
        if (!app.actorId || !app.workspaceId) throw new Error('scope_missing');
        if (app.bounds.requests >= limits.maxRequests) throw new Error('request_limit');
        if (app.bounds.startedAt !== null && Date.now() - app.bounds.startedAt >= limits.maxRuntimeMs) throw new Error('runtime_limit');
        app.bounds.startedAt ??= Date.now();
        app.bounds.requests++;
        return Math.max(1, limits.maxRuntimeMs - (Date.now() - app.bounds.startedAt));
      }, context);
    }, route, limits.maxRuntimeMs);
    // A store that cannot be created is a storage problem; a retained store that
    // exists but cannot be opened or recovered needs restore or repair.
    const retained = await fileExists(owner.storePath).then(() => true, () => false);
    storage = await boot(retained ? 'store_recovery_failed' : 'storage_unavailable', () => openNodeSqliteStorage(owner.storePath));
    harness = await boot('store_recovery_failed', () => Harness.open(storage, { models: safeModels, registry,
      // Retries are Durable's generation attempts: each goes through the Models
      // seam and reserves a request slot. SDK retries inside one attempt stay off,
      // so no request bypasses that bound.
      settings: { retry: { enabled: limits.maxRetries > 0, maxRetries: limits.maxRetries, baseDelayMs: limits.retryBaseDelayMs,
        maxAgentDelayMs: 30000 }, compaction, afterFailedRun: 'withdraw', progress: { persistWithinMs: limits.persistWithinMs },
        stream: { maxRetries: 0 }, restartLimit: limits.restartLimit },
      env: async ({ conversationId, read }) => {
        if (execution !== 'trusted-local-single-tenant') return undefined;
        const scope = await read.snapshot(App, conversationId, context);
        if (!scope?.cwd || !isAbsolute(scope.cwd)) throw new Error('scope_missing');
        if (config.shellTmpDir) await mkdir(config.shellTmpDir, { recursive: true, mode: 0o700 });
        const shellEnv = { PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', HOME: scope.cwd, TMPDIR: config.shellTmpDir ?? '/tmp' };
        const env = new NodeExecutionEnv({ cwd: scope.cwd, shellPath: '/bin/bash', shellEnv });
        const exec = env.exec.bind(env);
        // shellEnv overlays process.env unless a call passes inheritEnv: false.
        const isolate = command => shellNetwork !== 'isolated' ? command :
          ['unshare', '--user', '--map-current-user', '--net', '--', ...(typeof command === 'string' ? ['/bin/bash', '-c', command] : command)];
        env.exec = (command, options, ctx) => exec(isolate(command), { ...options, inheritEnv: false, env: shellEnv }, ctx);
        // Spilled tool output (the full text behind a truncated result) goes to
        // shellTmpDir when one is configured, rather than the host temp directory.
        if (config.shellTmpDir) env.createTempDir = async (prefix, ctx) => {
          if (ctx?.abortSignal?.aborted) return envErr(new Error('aborted'));
          try {
            await mkdir(config.shellTmpDir, { recursive: true, mode: 0o700 });
            return envOk(await mkdtemp(join(config.shellTmpDir, prefix ?? 'tmp-')));
          } catch (error) { return envErr(error); }
        };
        return env;
      },
      conversationCreated: async (tx, conversation) => {
        await tx.doc(App, conversation.id);
        const provider = await tx.doc(ProviderDoc, conversation.id);
        (await tx.doc(Admission)).sessions[provider.sessionId] = conversation.id;
      },
      onReport: report => { reports.push(report.kind); dependencies.onReport?.(report.kind); }
    }, context));
    const inspection = await boot('store_recovery_failed', () => harness.inspect(context));
    // A task no registered definition can take refuses boot. (Since 1.5.0 a task
    // the restart limit cuts off ends visibly instead of parking; see snapshot.)
    if (inspection.tasks.some(task => task.state.kind === 'blocked')) throw new Error('incompatible_definitions');
    const records = await boot('store_recovery_failed', () => harness.commit(tx => tx.scanConversations({}, 100000), context));
    for (const record of records.items) {
      const app = await harness.snapshot(App, record.id, context);
      for (const cancellation of Object.values(app?.cancellations ?? {})) {
        for (const submission of cancellation.submissions) await harness.abortSubmission(submission.id ?? submission, context, submission.conversationId ?? record.id);
        for (const id of cancellation.tasks) { const task = await harness.getTask(id, context); if (task && task.state.status !== 'terminal') await harness.abortTask(id, context); }
      }
    }
    harness.resume();
    async function access(id, scope) {
      requiredString(scope.actorId, 'actor'); requiredString(scope.workspaceId, 'workspace');
      const app = await harness.snapshot(App, Number(id), context);
      if (!scopeMatches(app, scope)) throw new ApiError(404, 'not_found');
      const permission = await authorize({ actorId: app.actorId, workspaceId: app.workspaceId });
      if (permission?.allowed !== true || !scopeMatches(permission, app) || permission.cwd !== app.cwd) throw new ApiError(403, 'access_denied');
      return { app, conversation: await harness.conversation(Number(id), context) };
    }
    // The conversation, conversations owned by its tasks, and every task in them
    // (ordinary and background), to a fixpoint over the published task graph.
    async function ownedTree(root) {
      const nodes = Object.values((await liveTaskGraph(harness)).tasks);
      const conversations = new Set([root]), tasks = new Set();
      for (let changed = true; changed;) {
        changed = false;
        for (const node of nodes) {
          if (tasks.has(node.id) || !(conversations.has(node.conversationId) || (node.owner !== undefined && tasks.has(node.owner)))) continue;
          tasks.add(node.id); changed = true;
          for (const owned of node.conversations) conversations.add(owned);
        }
      }
      return { conversations: [...conversations], tasks: [...tasks] };
    }
    // Default Conversation.abort() leaves background subtrees running; abort with
    // `background`, then mark and join every recorded task explicitly.
    async function settleCancellation(record) {
      for (const submission of record.submissions) await harness.abortSubmission(submission.id ?? submission, context, submission.conversationId);
      // A retry only re-settles the recorded tasks; aborting the conversation again
      // would cancel work admitted after the original cancellation.
      if (!record.retry) for (const id of record.conversations ?? []) {
        const owned = await harness.conversation(id, context);
        if (owned) await owned.abort(context, { background: true });
      }
      for (const id of record.tasks) await harness.abortTask(id, context);
      for (const id of record.tasks) await harness.waitForTask(id, context);
    }
    // Pending human input of a conversation and the live conversations its tasks
    // own (workflow children), so a child's question or approval reaches the
    // same Rails page as the parent's.
    async function pendingRequests(id) {
      const tree = await ownedTree(id);
      const rows = [];
      for (const owned of tree.conversations) {
        const app = await harness.snapshot(App, owned, context);
        for (const request of Object.values(app?.requests ?? {})) rows.push({ request, conversationId: owned });
      }
      return rows;
    }
    const runtime = {
      harness, registry, reports, limits, route, execution, shellNetwork, mcp,
      async create(scope) {
        requiredString(scope.requestId, 'request'); requiredString(scope.actorId, 'actor'); requiredString(scope.workspaceId, 'workspace');
        const permission = await authorize({ actorId: scope.actorId, workspaceId: scope.workspaceId });
        if (permission?.allowed !== true || !scopeMatches(permission, scope) || !isAbsolute(permission.cwd ?? '')) throw new ApiError(403, 'access_denied');
        const key = digest([scope.actorId, scope.workspaceId, scope.requestId]);
        const payload = digest({ actorId: scope.actorId, workspaceId: scope.workspaceId, cwd: permission.cwd });
        const id = await harness.commit(async tx => {
          const admissions = await tx.doc(Admission);
          const prior = admissions.conversations[key];
          if (prior) { if (prior.digest !== payload) throw new ApiError(409, 'request_conflict'); return prior.id; }
          const created = await tx.createConversation({ ownership: { kind: 'ownerless' } });
          const app = await tx.doc(App, created.id);
          app.actorId = scope.actorId; app.workspaceId = scope.workspaceId; app.cwd = permission.cwd;
          admissions.conversations[key] = { id: created.id, digest: payload };
          return created.id;
        }, context);
        const conversation = await harness.conversation(id, context);
        // Scope came from the Rails callback, never a browser-supplied cwd.
        await conversation.configure({ model: route, thinkingLevel: 'medium', cwd: permission.cwd,
          extensions: registry.snapshot().installed().filter(extension => inScope(extension, scope)) }, context);
        return { id };
      },
      async submit(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.requestId, 'request'); requiredString(input.content, 'content');
        if (input.whenBusy !== undefined && !['steer', 'followUp', 'reject'].includes(input.whenBusy)) throw new ApiError(422, 'invalid_busy_mode');
        const draft = { type: 'input', requestId: input.requestId, content: input.content, ...(input.whenBusy ? { whenBusy: input.whenBusy } : {}) };
        const payload = digest(draft);
        await conversation.commit(async tx => {
          const app = await tx.doc(App, conversation.id);
          const key = digest(input.requestId);
          if (app.admissions[key] && app.admissions[key] !== payload) throw new ApiError(409, 'request_conflict');
          app.admissions[key] = payload;
        }, context);
        const submission = await conversation.submit(draft, context);
        return { id: submission.id, ...(await submission.status(context)) };
      },
      async answer(id, requestId, input) {
        const { conversation } = await access(id, input);
        requiredString(requestId, 'request');
        const owner = (await pendingRequests(conversation.id)).find(row => row.request.id === requestId)?.conversationId ?? conversation.id;
        return harness.commit(async tx => {
          const app = await tx.doc(App, owner);
          const request = app.requests[requestId];
          if (!request || !scopeMatches(request, input)) throw new ApiError(404, 'not_found');
          if (request.status === 'answered') {
            if (digest(request.answer) !== digest(input.answer)) throw new ApiError(409, 'answer_conflict');
            return JSON.parse(JSON.stringify(request.answer));
          }
          validateAnswer(request, input.answer, Date.now());
          request.answer = input.answer; request.status = 'answered';
          return input.answer;
        }, context);
      },
      async cancel(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        const key = digest(input.requestId);
        const tree = await ownedTree(conversation.id);
        const current = await harness.inspect(context);
        // The record is the authority for restart: only work live at admission is
        // cancelled again, so a retried request never cancels newer work.
        const cancellation = await harness.commit(async tx => {
          const app = await tx.doc(App, conversation.id);
          if (app.cancellations[key]) return { ...JSON.parse(JSON.stringify(app.cancellations[key])), retry: true };
          const record = { tasks: tree.tasks, conversations: tree.conversations,
            submissions: current.submissions.filter(s => tree.conversations.includes(s.conversationId) && s.status === 'queued')
              .map(s => ({ id: s.id, conversationId: s.conversationId })) };
          app.cancellations[key] = record;
          for (const owned of tree.conversations) {
            const doc = owned === conversation.id ? app : await tx.doc(App, owned);
            for (const request of Object.values(doc.requests)) if (request.status === 'pending') request.status = 'cancelled';
          }
          return record;
        }, context);
        await settleCancellation(cancellation);
        return { cancelled: true };
      },
      // The browser-facing DTO only: no raw Durable state, task inspection, scope
      // binding, task/call identity or other conversations' data. `entries` is the
      // whole fork-aware history, paged from the store (since 1.5.0 a conversation
      // view holds only a 50-100 entry window); compaction summaries appear in place.
      async snapshot(id, scope, history) {
        const { conversation } = await access(id, scope);
        const records = history ?? await allEntries(conversation);
        const inspection = await harness.inspect(context);
        const tasks = inspection.tasks.filter(t => t.record.conversationId === conversation.id);
        const last = await storage.scanSubmissions({ conversationId: conversation.id, order: 'descending' }, 1, undefined, context);
        const submission = last.items[0];
        const live = await harness.snapshot(LiveDoc, conversation.id, context);
        const requests = (await pendingRequests(conversation.id)).map(row => row.request);
        const pendingInputs = requests.filter(r => r.status === 'pending' && r.expiresAt > Date.now()).map(request =>
          request.kind === 'approval' ? { id: request.id, kind: 'approval', digest: request.digest, tool: request.tool,
            arguments: JSON.parse(JSON.stringify(request.arguments)), maxUses: request.maxUses, expiresAt: request.expiresAt } :
            { id: request.id, kind: 'question', expiresAt: request.expiresAt, questions: request.tabs.map(tab => ({
              question: tab.title, description: tab.description ?? '', multiple: tab.multiple === true,
              allowCustom: tab.custom === true, options: tab.options.map(option => ({ value: option.id, label: option.label,
                description: option.description ?? '' })) })) });
        // Why the newest run ended without an answer (pi.live.runFailure), until a
        // later run starts. Only the fixed reason category leaves the sidecar.
        const runFailure = live?.run === undefined ? live?.runFailure : undefined;
        const firstIndex = runFailure?.first === undefined ? -1 : records.findIndex(entry => entry.id === runFailure.first);
        const runEntries = firstIndex >= 0 ? records.slice(firstIndex) : records.slice(records.findLastIndex(entry => entry.kind === 'pi.user') + 1);
        // Crash-loop protection ended the run's work (a task cut off restartLimit
        // times): recovery-needed, reported as `blocked`, not silently retried.
        const crashLoop = runFailure !== undefined && (runFailure.reason === CRASH_LOOP || crashLoopIn(runEntries));
        const failure = runFailure ? { reason: crashLoop ? CRASH_LOOP : runFailure.reason } : null;
        const status = tasks.some(t => t.state.kind === 'blocked') || crashLoop ? 'blocked' : pendingInputs.length ? 'waiting' :
          tasks.length ? 'running' : submission?.status === 'unanswered' ?
            (['aborted', 'withdrawn', 'cancelled'].includes(submission.reason) ? 'cancelled' : 'error') : submission?.status === 'done' ? 'done' : 'idle';
        const entries = records.flatMap(entry => (entry.model ?? []).map((message, index) => ({
          id: index === 0 ? entry.id : `${entry.id}:${index}`, role: entry.kind === 'pi.compaction' ? 'summary' : message.role,
          content: typeof message.content === 'string' ? message.content : (message.content ?? []).map(block =>
            block.type === 'text' ? block.text : block.type === 'image' ? '[image]' : block.type === 'toolCall' ? `[tool: ${block.name}]` : '').join(''),
          ...(message.toolName ? { toolName: message.toolName } : {}),
          ...(message.role === 'toolResult' && message.isError ? { isError: true } : {}) })));
        const usage = await harness.snapshot(UsageDoc, conversation.id, context);
        return { id: conversation.id, entries, pendingInputs, status, failure, usage: usageView(usage, priced) };
      },
      // Rails records an MCP account grant or revocation for one actor/workspace.
      // It persists in the store; a revocation stays until Rails grants again.
      async setMcpGrant(input) {
        requiredString(input.actorId, 'actor'); requiredString(input.workspaceId, 'workspace');
        requiredString(input.serverId, 'server'); requiredString(input.accountId, 'account');
        if (!['granted', 'revoked'].includes(input.status)) throw new ApiError(422, 'invalid_grant');
        const server = (config.mcp ?? []).find(c => c.serverId === input.serverId && c.accountId === input.accountId && scopeMatches(c, input));
        if (!server) throw new ApiError(404, 'not_found');
        const permission = await authorize({ actorId: input.actorId, workspaceId: input.workspaceId });
        if (permission?.allowed !== true || !scopeMatches(permission, input)) throw new ApiError(403, 'access_denied');
        await harness.commit(async tx => {
          (await tx.doc(McpGrants)).grants[mcpGrantKey(input, server)] = { status: input.status, at: Date.now() };
        }, context);
        return { status: input.status };
      },
      // A live view for SSE: the conversation watch plus a ConversationTranscript,
      // so every frame carries the whole history without re-reading it per frame.
      // Older pages are loaded once, and gaps after a stall are filled.
      async watch(id, scope) {
        const { conversation } = await access(id, scope);
        const transcript = new ConversationTranscript((query, limit, ctx) => conversation.entries(query, limit, undefined, ctx),
          { pageSize: ENTRY_PAGE });
        const handle = await conversation.watch(context);
        let view = transcript.merge(handle.value);
        return {
          start(listener) {
            handle.start(async call => { if (call.kind !== 'value') return; view = transcript.merge(call.value); await listener(); });
          },
          stop: () => handle.stop(),
          closed: handle.closed,
          async snapshot() {
            view = await completeTranscript(transcript, view);
            return runtime.snapshot(id, scope, view.items.filter(item => item.kind === 'entry').map(item => item.entry));
          }
        };
      },
      async close() { try { await harness.close(context); } finally { await sandbox.close(); await mcp.close(); owner.release(); } }
    };
    return runtime;
  } catch (error) {
    try { if (harness) await harness.close(context); else await storage?.close(context);
      await sandbox?.close(); await mcp?.close(); } finally { owner.release(); }
    throw error;
  }
}
