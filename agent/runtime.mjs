import { isAbsolute, extname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { access as fileExists } from 'node:fs/promises';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels, getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { localProvider } from './local-model.mjs';
import { subscriptionProvider, subscriptionCustody, custodyCredentials } from './claude-subscription.mjs';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai';
import { Harness, createRegistry, ProviderDoc, LiveDoc, UsageDoc, DEFAULT_COMPACTION_POLICY,
  defineExtension, hook, ToolTask } from '@earendil-works/pi-durable';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { createCodingTools } from '@earendil-works/pi-durable/tools';
import { createNodePhotonImages } from '@earendil-works/pi-durable/images/node';
import { App, Admission, Definitions, digest, ApiError, scopeMatches, requiredString } from './state.mjs';
import { infraExtension, botExtension } from './extensions.mjs';
import { ownStore } from './ownership.mjs';
import { validComputer, offeredComputers, localEnv, spritesComputers } from './computers.mjs';
import { browserExtension } from './browser.mjs';

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
// The model routes a bot may name, the same list Rails offers
// (config/pi_durable.yml). A route is offered only when its provider's key is
// present; local/avery-local, a scripted stand-in that costs nothing, only
// with modelMode 'local'. No other model is ever used, and none is a fallback.
export const MODEL_ROUTES = Object.freeze(['anthropic/claude-sonnet-5', 'anthropic/claude-sonnet-5-5', 'anthropic/claude-opus-5-5',
  'anthropic/claude-haiku-5-5', 'openai/gpt-6.1-sol'].map(route => Object.freeze({ provider: route.split('/')[0], modelId: route.split('/')[1] })));
export const LOCAL_ROUTE = Object.freeze({ provider: 'local', modelId: 'avery-local' });
export const DEFAULT_MODEL = MODEL_ROUTES.find(route => route.provider === 'openai');
export const THINKING_LEVELS = Object.freeze(['low', 'medium', 'high']);
const routeName = route => `${route.provider}/${route.modelId}`;
// maxRetries/retryBaseDelayMs: Durable's own generation retries of a retryable
// provider error (rate limit, overload, 5xx, timeout) or of a request a crash cut
// off; every attempt reserves a slot in maxRequests at the Models seam. 0 disables.
// persistWithinMs: how long streamed progress may stay in memory before it is
// stored (Durable's default is 1000 ms); a crash loses at most about this much.
// humanTimeoutMs bounds a wait for a person when Rails names no deadline;
// recheckMs is how often a waiting call asks Rails again without a doorbell.
// invokeRetries/invokeRetryMs: brief retries of a Rails callback that failed
// on the network (Rails restarting) before it becomes the call's error.
export const DEFAULT_LIMITS = Object.freeze({ maxRequests: 64, maxRuntimeMs: 300000,
  humanTimeoutMs: 86400000, recheckMs: 60000, invokeRetries: 3, invokeRetryMs: 1000,
  restartLimit: 5, maxRetries: 2, retryBaseDelayMs: 2000, persistWithinMs: 100, frameIntervalMs: 100 });
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
  'shell_isolation_unavailable', 'provider_credential_missing', 'anthropic_credential_ambiguous',
  'claude_subscription_invalid', 'claude_subscription_excludes_openai']);
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

// The production model catalogue: a provider is registered only with its own
// key, held in memory, never Pi's personal auth store. Returns the routes it
// can serve, in MODEL_ROUTES order; with none, the sidecar is not ready.
//
// claudeSubscription ({file, vaultKey, environment}) instead of
// anthropicApiKey reaches Claude through a Claude subscription
// (claude-subscription.mjs), never both: there is no fallback from one to the
// other. Its routes are offered before the owner has signed in, so signing in
// needs no restart; until then a run fails plainly. The custody is returned
// for the owner console's routes.
export function productionModels({ openaiApiKey, anthropicApiKey, claudeSubscription, modelMode } = {}) {
  const keys = { openai: openaiApiKey, anthropic: anthropicApiKey };
  for (const [provider, key] of Object.entries(keys)) if (key !== undefined && key !== null && key !== '') requiredString(key, `${provider}_key`);
  if (claudeSubscription && anthropicApiKey) throw new Error('anthropic_credential_ambiguous');
  if (claudeSubscription && !(isAbsolute(claudeSubscription.file ?? '') && /^[a-f0-9]{64}$/.test(claudeSubscription.vaultKey ?? '')
    && /^[a-z][a-z0-9-]{0,31}$/.test(claudeSubscription.environment ?? ''))) throw new Error('claude_subscription_invalid');
  const credentials = Object.fromEntries(Object.entries(keys).filter(([, key]) => key).map(([id, key]) => [id, { type: 'api_key', key }]));
  const custody = claudeSubscription ? subscriptionCustody(claudeSubscription) : undefined;
  const subscription = custody ? custodyCredentials(custody) : undefined;
  const models = createModels({ credentials: subscription ?? { read: async id => credentials[id],
    list: async () => Object.keys(credentials).map(providerId => ({ providerId, type: 'api_key' })),
    modify: async () => { throw new Error('credential_mutation_disabled'); }, delete: async () => { throw new Error('credential_mutation_disabled'); } } });
  if (subscription && credentials.openai) throw new Error('claude_subscription_excludes_openai');
  if (credentials.openai) models.setProvider(openaiProvider());
  if (credentials.anthropic) models.setProvider(anthropicProvider());
  if (subscription) models.setProvider(subscriptionProvider());
  const routes = MODEL_ROUTES.filter(route => credentials[route.provider] || (subscription && route.provider === 'anthropic'));
  for (const route of routes) {
    const model = models.getModel(route.provider, route.modelId);
    if (!model || !getSupportedThinkingLevels(model).includes('medium')) throw new Error('approved_model_unavailable');
  }
  if (modelMode === 'local') { models.setProvider(localProvider()); routes.unshift(LOCAL_ROUTE); }
  else if (modelMode !== undefined && modelMode !== null && modelMode !== '') throw new Error('invalid_model_mode');
  if (!routes.length) throw new Error('provider_credential_missing');
  return { models, routes, subscription: custody };
}

// One committed entry as the messages Rails shows: text, tool-call names and
// ids (so Rails can place each call's record), tool results by call id.
// Raw Durable state, task identity and scope bindings never leave.
// What the model thought before answering, when the provider shares it
// (redacted thinking is not text and is left out).
const thinkingOf = blocks => blocks.filter(block => block.type === 'thinking' && !block.redacted).map(block => block.thinking).join('\n\n').trim();
// Images a tool returned (a browser screenshot); the model saw them too.
const imagesOf = blocks => blocks.filter(block => block.type === 'image' && typeof block.data === 'string')
  .map(block => ({ mimeType: block.mimeType, data: block.data }));
export function entryView(entry) {
  return (entry.model ?? []).map((message, index) => {
    const blocks = typeof message.content === 'string' ? [{ type: 'text', text: message.content }] : (message.content ?? []);
    const toolCalls = blocks.filter(block => block.type === 'toolCall').map(block => ({ id: block.id, name: block.name }));
    return { id: index === 0 ? String(entry.id) : `${entry.id}:${index}`, entryId: entry.id,
      role: entry.kind === 'pi.compaction' ? 'summary' : message.role,
      content: blocks.map(block => block.type === 'text' ? block.text : block.type === 'toolCall' ? `[tool: ${block.name}]` : '').join(''),
      ...(thinkingOf(blocks) ? { thinking: thinkingOf(blocks) } : {}),
      ...(imagesOf(blocks).length ? { images: imagesOf(blocks) } : {}),
      ...(toolCalls.length ? { toolCalls } : {}),
      ...(message.toolName ? { toolName: message.toolName } : {}),
      ...(message.toolCallId ? { toolCallId: message.toolCallId } : {}),
      ...(message.role === 'toolResult' && message.isError ? { isError: true } : {}) };
  });
}

export const ENTRIES_PAGE_BYTES = 3 * 1024 * 1024;
export const SIDECAR_TOOL_NAMES = Object.freeze(['read', 'write', 'edit', 'bash', 'visit_website']);
const TOOL_NAME = /^[a-z][a-z0-9_]{0,63}$/;
export function validDefinition(input, routes, reserved = new Set(), offered = {}) {
  const invalid = category => new ApiError(422, category);
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw invalid('invalid_definition');
  const { digest: claimed, ...body } = input;
  const keys = Object.keys(body).sort().join(',');
  if (keys !== 'instructions,model,thinkingLevel,tools' && keys !== 'computer,instructions,model,thinkingLevel,tools') throw invalid('invalid_definition');
  if (typeof claimed !== 'string' || digest(body) !== claimed) throw invalid('definition_digest_mismatch');
  if (typeof body.instructions !== 'string' || body.instructions.length > 65536) throw invalid('invalid_instructions');
  if (!routes.some(route => routeName(route) === body.model)) throw invalid('model_unavailable');
  if (!THINKING_LEVELS.includes(body.thinkingLevel)) throw invalid('invalid_thinking_level');
  const computer = validComputer(body.computer);
  if (computer === undefined) throw invalid('invalid_computer');
  if (computer && offered[computer.provider] !== true) throw invalid('computer_unavailable');
  if (!Array.isArray(body.tools) || body.tools.length > 64) throw invalid('invalid_tools');
  const names = new Set();
  for (const tool of body.tools) {
    if (!tool || typeof tool !== 'object' || Object.keys(tool).sort().join(',') !== 'description,name,parameters' ||
      typeof tool.name !== 'string' || !TOOL_NAME.test(tool.name) || names.has(tool.name) || reserved.has(tool.name) ||
      typeof tool.description !== 'string' || tool.description.length > 2048 ||
      !tool.parameters || typeof tool.parameters !== 'object' || tool.parameters.type !== 'object') throw invalid('invalid_tools');
    names.add(tool.name);
  }
  return JSON.parse(JSON.stringify(input));
}

// The text of the reply being written: the committed, throttled partial.
function liveText(live) {
  const content = live?.generation?.message?.content;
  if (!Array.isArray(content)) return '';
  return content.filter(block => block.type === 'text').map(block => block.text).join('');
}
function liveThinking(live) {
  const content = live?.generation?.message?.content;
  return Array.isArray(content) ? thinkingOf(content) : '';
}

// Pushes to Rails while a conversation runs: a frame with the whole live tail
// (Rails replaces, never appends, so a lost or reordered frame cannot corrupt
// the page) and a sync ping when entries commit (Rails pulls them, so a missed
// ping heals at the next). Both are best effort and throttled.
function railsNotifier(harness, { frame, sync, intervalMs }) {
  const watching = new Map();
  // Frame numbers only grow, across runs and restarts, so Rails can drop an
  // older frame that arrives after a newer one.
  let clock = Date.now();
  const nextSeq = () => (clock = Math.max(clock + 1, Date.now()));
  async function watch(id) {
    if ((!frame && !sync) || watching.has(id)) return;
    watching.set(id, null);
    try {
      const app = await harness.snapshot(App, id, context);
      const scope = { actorId: app?.actorId, workspaceId: app?.workspaceId, conversationId: String(id) };
      const conversation = await harness.conversation(id, context);
      const handle = await conversation.watch(context, { min: 1, max: 8 });
      const started = Date.now();
      let value = handle.value, timer, lastText, lastThinking, lastBusy, lastEntry = value.entries.at(-1)?.id, stopped = false, seenBusy = false;
      const stop = async () => { if (stopped) return; stopped = true; clearTimeout(timer); watching.delete(id); await handle.stop(); };
      const flush = async () => {
        timer = undefined;
        const live = value.docs['pi.live'];
        const text = liveText(live), thinking = liveThinking(live), busy = live?.run !== undefined;
        const newest = value.entries.at(-1)?.id;
        if (newest !== lastEntry) { lastEntry = newest; await sync?.(scope).catch(() => {}); }
        if (text !== lastText || thinking !== lastThinking || busy !== lastBusy) {
          lastText = text; lastThinking = thinking; lastBusy = busy;
          // No frame follows the last one, so it alone is retried before giving up
          // (the page then corrects its status when it next loads).
          const payload = { ...scope, seq: nextSeq(), busy, tail: text, thinking, failure: busy ? null : live?.runFailure?.reason ?? null };
          for (let attempt = 0; attempt < (busy ? 1 : 4); attempt++) {
            if (attempt) await new Promise(resolve => setTimeout(resolve, intervalMs * 2 ** attempt));
            if (await frame?.(payload).then(() => true, () => false)) break;
          }
        }
        seenBusy ||= busy;
        // A submission may not have started its run yet; give it a moment.
        if (!busy && (seenBusy || Date.now() - started > 5000)) await stop();
        else if (!busy) timer ??= setTimeout(() => { void flush(); }, intervalMs * 4);
      };
      handle.start(async call => {
        if (call.kind !== 'value') return;
        value = call.value;
        timer ??= setTimeout(() => { void flush(); }, intervalMs);
      });
      handle.closed.then(stop, stop);
      watching.set(id, handle);
      timer ??= setTimeout(() => { void flush(); }, intervalMs);
    } catch { watching.delete(id); }
  }
  return { watch };
}

function failure(model, category) {
  return { role: 'assistant', provider: model.provider, api: model.api, model: model.id, content: [],
    stopReason: 'error', errorMessage: category, timestamp: Date.now(),
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
}

// A hook throw is not a hard stop in Durable. Reserve a persisted request slot
// immediately before dispatch to Models, and reject before the provider sees it.
function guardedModels(models, reserve, routes, timeoutMs) {
  const dispatch = method => (model, transcript, opts = {}) => {
    const stream = new AssistantMessageEventStream();
    void (async () => {
      try {
        if (!routes.some(route => model.provider === route.provider && model.id === route.modelId)) throw new Error('model_route_denied');
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
  // Injected models (tests) serve exactly the injected route.
  const catalogue = dependencies.models ? { models: dependencies.models, routes: [dependencies.model ?? DEFAULT_MODEL] } :
    await boot('provider_credential_missing', () => productionModels(config));
  const { models, routes, subscription } = catalogue;
  const route = routes[0];
  // A subscription's routes are offered before the owner signs in (productionModels).
  for (const candidate of routes) {
    if (!models.getModel(candidate.provider, candidate.modelId) || (!subscription &&
      !(await models.getAvailable(candidate.provider)).some(m => m.id === candidate.modelId))) throw new Error('approved_model_unavailable');
  }
  const priced = Object.fromEntries(routes.map(candidate => [routeName(candidate),
    Object.values(models.getModel(candidate.provider, candidate.modelId).cost ?? {}).some(rate => typeof rate === 'number' && rate > 0)]));
  if (typeof dependencies.authorize !== 'function' && typeof config.authorize !== 'function') throw new Error('authorization_callback_required');
  const authorize = dependencies.authorize ?? config.authorize;
  const invoke = dependencies.invoke ?? config.invoke;
  if (typeof invoke !== 'function') throw new Error('rails_invoke_callback_required');
  // Best-effort pushes to Rails; the page heals on load if one is lost.
  const frame = dependencies.frame ?? config.frame;
  const sync = dependencies.sync ?? config.sync;
  const execution = config.execution ?? 'none';
  if (!EXECUTION_MODES.includes(execution)) throw new Error('invalid_execution_mode');
  const shellNetwork = config.shellNetwork ?? 'host';
  if (!SHELL_NETWORK_MODES.includes(shellNetwork)) throw new Error('invalid_execution_mode');
  if (shellNetwork === 'isolated' && !shellIsolationAvailable()) throw new Error('shell_isolation_unavailable');
  // Which computers this sidecar can give a bot; the bot's definition picks one.
  const offered = offeredComputers({ execution, sprites: config.sprites });
  const sprites = offered.sprites ? spritesComputers({ ...config.sprites, onLog: dependencies.onComputerLog }) : undefined;
  const owner = await boot('storage_unavailable', () => ownStore(config.storePath));
  let harness, storage;
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
    // File and shell tools, given only to conversations whose bot has a computer.
    const computerExtensions = [];
    if (offered.local || offered.sprites) {
      const images = await createNodePhotonImages({ worker: false });
      computerExtensions.push(createCodingTools({ images }), readGuard, browserExtension);
      for (const extension of computerExtensions) registry.install(extension);
    }
    registry.install(infraExtension());
    for (const extension of dependencies.extensions ?? []) registry.install(extension);
    // Everything but bot definitions: what every conversation in a scope gets.
    const isBot = extension => extension.name.startsWith('bot.');
    const forComputer = extension => computerExtensions.some(own => own.name === extension.name);
    const infraFor = () => registry.snapshot().installed().filter(extension => !isBot(extension) && !forComputer(extension));
    // A bot's tool may not take the name of one of the sidecar's, installed here or not.
    const reservedToolNames = () => new Set([...SIDECAR_TOOL_NAMES,
      ...registry.snapshot().installed().filter(e => !isBot(e)).flatMap(e => (e.tools ?? []).map(t => t.name))]);
    const installDefinition = definition => {
      const name = `bot.${definition.digest}`;
      if (!registry.snapshot().extension(name)) registry.install(botExtension(definition, { ...limits, invoke }));
      return registry.snapshot().extension(name);
    };
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
    }, routes, limits.maxRuntimeMs);
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
      // Pi builds this for every model request and tool call of a conversation
      // whose bot has a computer; a bot without one never reaches a computer.
      env: async ({ conversationId, read }) => {
        const stored = await read.snapshot(Definitions, context);
        const computer = stored?.byDigest[stored.conversations[conversationId]]?.computer;
        if (!computer || offered[computer.provider] !== true) return undefined;
        if (computer.provider === 'sprites') return sprites.env(computer.name, conversationId, context);
        const scope = await read.snapshot(App, conversationId, context);
        if (!scope?.cwd || !isAbsolute(scope.cwd)) throw new Error('scope_missing');
        return localEnv({ root: scope.cwd, conversationId, shellNetwork, shellTmpDir: config.shellTmpDir,
          isolate: command => ['unshare', '--user', '--map-current-user', '--net', '--', ...(typeof command === 'string' ? ['/bin/bash', '-c', command] : command)] });
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
    // Reinstall the definitions conversations still run, from the store, so a
    // call in flight after a restart finds its tool without asking Rails.
    // Definitions no conversation names any longer are dropped.
    await harness.commit(async tx => {
      const stored = await tx.doc(Definitions);
      const used = new Set(Object.values(stored.conversations));
      for (const key of Object.keys(stored.byDigest)) if (!used.has(key)) delete stored.byDigest[key];
    }, context);
    for (const definition of Object.values((await harness.snapshot(Definitions, context))?.byDigest ?? {})) installDefinition(definition);
    const notifier = railsNotifier(harness, { frame, sync, intervalMs: limits.frameIntervalMs });
    harness.resume();
    for (const record of records.items) if ((await harness.snapshot(LiveDoc, record.id, context))?.run) void notifier.watch(record.id);
    async function access(id, scope) {
      requiredString(scope.actorId, 'actor'); requiredString(scope.workspaceId, 'workspace');
      const app = await harness.snapshot(App, Number(id), context);
      if (!scopeMatches(app, scope)) throw new ApiError(404, 'not_found');
      // Rails sent this command with its token, so it is not asked again here;
      // access is checked before every tool call and model request instead.
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
    // A definition is Rails' word for what the bot is now. It must name itself
    // by its own digest, use an offered model, and declare plain JSON tools that
    // shadow none of the sidecar's own. A new digest reconfigures the
    // conversation from its next request.
    async function runDefinition(conversation, input) {
      const definition = validDefinition(input.definition, routes, reservedToolNames(), offered);
      const extension = installDefinition(definition);
      const current = await harness.snapshot(Definitions, context);
      if (current?.conversations[conversation.id] === definition.digest) return;
      const app = await harness.snapshot(App, conversation.id, context);
      const [provider, modelId] = definition.model.split('/');
      await conversation.configure({ model: { provider, modelId }, thinkingLevel: definition.thinkingLevel, instructions: definition.instructions,
        extensions: [...infraFor(), extension, ...(definition.computer ? computerExtensions : [])] }, context);
      await harness.commit(async tx => {
        const stored = await tx.doc(Definitions);
        stored.byDigest[definition.digest] = definition;
        stored.conversations[conversation.id] = definition.digest;
      }, context);
    }
    const runtime = {
      harness, registry, reports, limits, route, routes, execution, shellNetwork, offered,
      // The Claude subscription's custody, for the owner console (server.mjs).
      subscription,
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
        await conversation.configure({ model: route, thinkingLevel: 'medium', cwd: permission.cwd, extensions: infraFor() }, context);
        return { id };
      },
      async submit(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        if (typeof input.content !== 'string' || !input.content.trim() || input.content.length > 65536) throw new ApiError(422, 'invalid_content');
        if (input.whenBusy !== undefined && !['steer', 'followUp', 'reject'].includes(input.whenBusy)) throw new ApiError(422, 'invalid_busy_mode');
        if (input.definition !== undefined) await runDefinition(conversation, input);
        const draft = { type: 'input', requestId: input.requestId, content: input.content, ...(input.whenBusy ? { whenBusy: input.whenBusy } : {}) };
        const payload = digest(draft);
        await conversation.commit(async tx => {
          const app = await tx.doc(App, conversation.id);
          const key = digest(input.requestId);
          if (app.admissions[key] && app.admissions[key] !== payload) throw new ApiError(409, 'request_conflict');
          app.admissions[key] = payload;
          // The request and runtime bounds are per run: a message to an idle
          // conversation starts a fresh budget; a steer or follow-up joins the
          // running one. Counting from the first message would end every
          // conversation for good five minutes after it began.
          if (!(await tx.doc(LiveDoc, conversation.id)).run) app.bounds = { requests: 0, startedAt: null };
        }, context);
        const submission = await conversation.submit(draft, context);
        void notifier.watch(conversation.id);
        return { id: submission.id, ...(await submission.status(context)) };
      },
      // Rails' doorbell for one waiting tool call. It carries no decision: the
      // waiting call asks Rails again. A ring before the wait is recorded is kept.
      async wake(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.key, 'key');
        const owner = (await pendingRequests(conversation.id)).find(row => row.request.key === input.key)?.conversationId ?? conversation.id;
        return harness.commit(async tx => {
          const app = await tx.doc(App, owner);
          const request = Object.values(app.requests).find(r => r.key === input.key && r.status === 'pending');
          if (request) request.rings++;
          else if (!app.requests[`person:${input.key}`]) app.requests[`person:${input.key}`] = { id: `person:${input.key}`, kind: 'person', key: input.key,
            actorId: app.actorId, workspaceId: app.workspaceId, status: 'pending', rings: 1, early: true, expiresAt: Date.now() + limits.humanTimeoutMs };
          return { rung: true };
        }, context);
      },
      // Committed transcript entries after `after` (an entry id), oldest first,
      // for Rails' rebuildable copy. `cursor` is the newest entry id returned.
      async entries(id, scope, after, limit) {
        const { conversation } = await access(id, scope);
        const from = after === undefined || after === null || after === '' ? undefined : Number(after);
        if (from !== undefined && (!Number.isInteger(from) || from < 0)) throw new ApiError(422, 'invalid_cursor');
        const size = Math.min(Math.max(Number(limit) || 200, 1), 500);
        const page = await conversation.entries({ order: 'ascending', ...(from !== undefined ? { minEntryId: from + 1 } : {}) }, size, undefined, context);
        // Screenshots make entries large: stop a page at about ENTRIES_PAGE_BYTES,
        // always after at least one entry, and let the cursor carry on from there.
        const entries = [];
        let bytes = 0, taken = 0;
        for (const item of page.items) {
          const views = entryView(item);
          const size = Buffer.byteLength(JSON.stringify(views));
          if (taken > 0 && bytes + size > ENTRIES_PAGE_BYTES) break;
          entries.push(...views); bytes += size; taken++;
        }
        const cut = taken < page.items.length;
        return { entries, cursor: page.items[taken - 1]?.id ?? from ?? null, more: cut || page.next !== undefined };
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
        // Waits for a person; the question or approval itself is Rails' record.
        const pendingInputs = requests.filter(r => r.status === 'pending' && !r.early && r.expiresAt > Date.now())
          .map(request => ({ id: request.id, kind: request.kind, expiresAt: request.expiresAt }));
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
        const entries = records.flatMap(entryView).map(({ entryId: _entryId, toolCalls: _calls, toolCallId: _callId, images: _images, ...entry }) => entry);
        const usage = await harness.snapshot(UsageDoc, conversation.id, context);
        const agent = await conversation.agent(context);
        return { id: conversation.id, entries, pendingInputs, status, failure,
          usage: usageView(usage, priced[agent?.model ? routeName(agent.model) : routeName(route)] === true) };
      },
      async close() { try { await harness.close(context); } finally { sprites?.close(); owner.release(); } }
    };
    return runtime;
  } catch (error) {
    try { if (harness) await harness.close(context); else await storage?.close(context);
      sprites?.close(); } finally { owner.release(); }
    throw error;
  }
}
