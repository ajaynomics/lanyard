import { isAbsolute, extname, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { access as fileExists } from 'node:fs/promises';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels, getSupportedThinkingLevels, clampThinkingLevel } from '@earendil-works/pi-ai/models';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { localProvider } from './local-model.mjs';
import { subscriptionProvider, subscriptionCustody } from './claude-subscription.mjs';
import { chatgptProvider, chatgptCustody, CHATGPT_PROVIDER } from './chatgpt-subscription.mjs';
import { apiKeyProvider, apiKeyCustody, API_KEY_PROVIDER } from './claude-api-key.mjs';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai';
import { Harness, createRegistry, ProviderDoc, LiveDoc, UsageDoc, DEFAULT_COMPACTION_POLICY,
  defineExtension, hook, ToolTask } from '@earendil-works/pi-durable';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { createCodingTools } from '@earendil-works/pi-durable/tools';
import { createNodePhotonImages } from '@earendil-works/pi-durable/images/node';
import { createCodemodeExtension } from '@earendil-works/pi-durable/codemode';
import { CodemodeSandbox } from '@earendil-works/pi-codemode';
import { App, Admission, Definitions, digest, ApiError, scopeMatches, requiredString } from './state.mjs';
import { infraExtension, agentExtension } from './extensions.mjs';
import { ownStore } from './ownership.mjs';
import { validComputer, offeredComputers, localEnv, spritesComputers, spriteName, readNotes, NOTES_FILE, NOTES_LIMIT } from './computers.mjs';
import { browserExtension } from './browser.mjs';
import { desktopExtension } from './desktop.mjs';
import { subagentExtension } from './subagent.mjs';
import { webSearchExtension } from './web-search.mjs';
import { sessionFile } from './session-file.mjs';
import { commandConnectors, localCommand, validSpec, CONNECTOR_NAME } from './command-connectors.mjs';

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
// Which models an agent may choose is Rails' allow-list (config/pi_durable.yml).
// The sidecar runs any model in pi-ai's catalogue whose provider it has a
// credential for, and local/stand-in, a scripted stand-in that costs
// nothing, only with modelMode 'local'. An agent's model is used or the run
// fails: none is ever a fallback.
export const LOCAL_ROUTE = Object.freeze({ provider: 'local', modelId: 'stand-in' });
// Every level pi-ai knows. A definition may name any; the conversation runs at
// the nearest one its model supports (clampThinkingLevel).
export const THINKING_LEVELS = Object.freeze(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);
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
// The owner's choice: summarise at about 262k tokens, however large the window.
// A 1M-token context costs and slows every request long before it fills, and a
// model reasons worse over a very long one. `AGENT_COMPACT_AT_TOKENS` overrides it.
export const COMPACT_AT_TOKENS = 262144;
// Durable blocks to compact above contextWindow - reserveTokens, harness-wide,
// so a large window gets its own reserve to block at `compactAt` instead.
// backgroundTokens keeps its default: a background summary starts that much
// earlier (about 229k). A window already blocking below compactAt needs none.
export function compactionOverride(contextWindow, settings, compactAt = COMPACT_AT_TOKENS) {
  if (!Number.isInteger(contextWindow)) return undefined;
  const reserveTokens = Math.max(settings.reserveTokens, contextWindow - compactAt);
  return reserveTokens === settings.reserveTokens ? undefined : { reserveTokens };
}
// Where a model's conversations block to summarise, for Rails' context meter.
export function compactAtOf(contextWindow, settings, compactAt = COMPACT_AT_TOKENS) {
  if (!settings.enabled || !Number.isInteger(contextWindow)) return null;
  return Math.min(compactAt, contextWindow - settings.reserveTokens);
}
export const COMPACTION_INSTRUCTIONS_LIMIT = 4096;
// `host` (default): the tool shell keeps the host network. `isolated`: every tool
// shell command runs in a fresh unprivileged user+network namespace (Linux
// `unshare`), so it has no route off the host (not even host loopback).
// Readiness fails closed when the kernel refuses user namespaces.
export const SHELL_NETWORK_MODES = Object.freeze(['host', 'isolated']);
// Readiness reasons. Each is actionable and carries no path, token or raw error.
export const READINESS_REASONS = Object.freeze(['store_already_owned', 'storage_unavailable', 'store_recovery_failed',
  'approved_model_unavailable', 'incompatible_definitions', 'absolute_store_required', 'invalid_execution_mode',
  'shell_isolation_unavailable', 'provider_credential_missing', 'anthropic_credential_ambiguous',
  'claude_subscription_invalid', 'chatgpt_subscription_invalid']);
// pi's default: a round of tool calls runs at once, unless one of its tools
// declares `executionMode: 'sequential'` (it shares state, as the screen's
// browser does). Results reach the model in the order it made the calls.
// agent/patches.mjs makes this safe on pi-durable 1.5.0 (pi#11892).
export const TOOL_EXECUTION = 'parallel';
// A run whose live tasks are there but none runs, sleeps or is blocked: nothing
// will move it (Durable's inspection kinds; a missed wake leaves `pending`).
export const stalledRun = states => states.length > 0 && !states.some(state => ['running', 'sleeping', 'blocked'].includes(state.kind));

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
// A conversation's entries, oldest first, a storage page at a time, so a long
// history is never held whole.
const ENTRY_PAGE = 500;
async function* allEntries(conversation) {
  let cursor;
  do {
    const page = await conversation.entries({ order: 'ascending' }, ENTRY_PAGE, cursor, context);
    yield* page.items;
    cursor = page.next;
  } while (cursor !== undefined);
}
// Whether crash-loop protection cut off work among the newest entries, read
// from the newest back until `stop` says an entry is older than the work.
async function crashLoopAfter(conversation, stop) {
  let cursor;
  do {
    const page = await conversation.entries({ order: 'descending' }, 64, cursor, context);
    const end = page.items.findIndex(stop);
    if (crashLoopIn(end < 0 ? page.items : page.items.slice(0, end))) return true;
    if (end >= 0) return false;
    cursor = page.next;
  } while (cursor !== undefined);
  return false;
}
// A run that did not answer because crash-loop protection ended its work.
const CRASH_LOOP = 'restart_limit';
// The fixed reason a run ended without an answer, the only part of
// pi.live.runFailure that leaves the sidecar. A provider's refusal for usage
// limits (HTTP 429, a subscription's limit) is told apart from other model
// errors, so the person learns to wait or switch, not that something broke.
// A model whose credential is missing (a subscription signed out, no API key
// pasted) is told apart too, so the person learns where to set it.
export function failureReason(runFailure) {
  if (!runFailure) return null;
  // The summary a request waited for failed; the person can ask for one again.
  if (runFailure.reason === 'model_error' && /^Compaction failed:/.test(runFailure.detail ?? '')) return 'compaction_failed';
  if (runFailure.reason === 'model_error' && /\b429\b|rate[_ ]limit/i.test(runFailure.detail ?? '')) return 'rate_limited';
  if (runFailure.reason === 'model_error' && /^Provider is not configured:/.test(runFailure.detail ?? '')) return 'credential_missing';
  // The conversation's computer could not wake: the platform's awake cap is reached.
  if (runFailure.reason === 'model_error' && /\bcomputers_busy\b/.test(runFailure.detail ?? '')) return 'computers_busy';
  return runFailure.reason;
}
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
// credential, held in memory, never Pi's personal auth store. Returns every
// model of those providers as a route; with none, the sidecar is not ready.
//
// claudeSubscription ({file, vaultKey, environment}) instead of
// anthropicApiKey reaches Claude through a Claude subscription
// (claude-subscription.mjs), never both: there is no fallback from one to the
// other. chatgptSubscription reaches OpenAI's Codex models through a ChatGPT
// subscription (chatgpt-subscription.mjs), a provider of its own beside
// `openai`. A subscription's routes are offered before the owner has signed
// in, so signing in needs no restart; until then a run fails plainly. The
// custodies are returned, by provider, for the owner console's routes.
//
// With either subscription's file, the owner may also paste an Anthropic API
// key (claude-api-key.mjs), kept in that file: the `anthropic-api` provider,
// beside the subscription and never a fallback for it. Its routes too are
// offered before a key is set. The ANTHROPIC_API_KEY setting above is a
// separate, older path to the `anthropic` provider itself.
const validSubscription = setting => isAbsolute(setting.file ?? '') && /^[a-f0-9]{64}$/.test(setting.vaultKey ?? '')
  && /^[a-z][a-z0-9-]{0,31}$/.test(setting.environment ?? '') && /^[a-z][a-z0-9-]{0,63}$/.test(setting.application ?? 'x');
export function productionModels({ openaiApiKey, anthropicApiKey, claudeSubscription, chatgptSubscription, modelMode } = {}) {
  const keys = { openai: openaiApiKey, anthropic: anthropicApiKey };
  for (const [provider, key] of Object.entries(keys)) if (key !== undefined && key !== null && key !== '') requiredString(key, `${provider}_key`);
  if (claudeSubscription && anthropicApiKey) throw new Error('anthropic_credential_ambiguous');
  if (claudeSubscription && !validSubscription(claudeSubscription)) throw new Error('claude_subscription_invalid');
  if (chatgptSubscription && !validSubscription(chatgptSubscription)) throw new Error('chatgpt_subscription_invalid');
  const credentials = Object.fromEntries(Object.entries(keys).filter(([, key]) => key).map(([id, key]) => [id, { type: 'api_key', key }]));
  const subscriptions = {
    ...(claudeSubscription ? { anthropic: subscriptionCustody(claudeSubscription) } : {}),
    ...(chatgptSubscription ? { [CHATGPT_PROVIDER]: chatgptCustody(chatgptSubscription) } : {})
  };
  const vault = claudeSubscription ?? chatgptSubscription;
  const apiKeys = vault ? { [API_KEY_PROVIDER]: apiKeyCustody(vault) } : {};
  // pi-ai's CredentialStore, read-only: a key, the pasted key, or the
  // custody's current access token (refreshed there when due). Signed out,
  // awaiting a reconnect, or no key pasted means no credential, and the run
  // fails plainly.
  const read = async id => {
    if (credentials[id]) return credentials[id];
    const custody = subscriptions[id] ?? apiKeys[id];
    if (!custody) return undefined;
    try { return { type: 'api_key', key: await (subscriptions[id] ? custody.accessToken() : custody.key()) }; } catch { return undefined; }
  };
  const refuse = async () => { throw new Error('credential_mutation_disabled'); };
  const models = createModels({ credentials: { read, modify: refuse, delete: refuse,
    list: async () => [...Object.keys(credentials), ...Object.keys(subscriptions), ...Object.keys(apiKeys)].map(providerId => ({ providerId, type: 'api_key' })) } });
  if (credentials.openai) models.setProvider(openaiProvider());
  if (credentials.anthropic) models.setProvider(anthropicProvider());
  if (subscriptions.anthropic) models.setProvider(subscriptionProvider());
  if (subscriptions[CHATGPT_PROVIDER]) models.setProvider(chatgptProvider());
  if (apiKeys[API_KEY_PROVIDER]) models.setProvider(apiKeyProvider());
  const routes = models.getProviders().flatMap(provider => provider.getModels().map(model => ({ provider: provider.id, modelId: model.id })));
  if (modelMode === 'local') { models.setProvider(localProvider()); routes.unshift(LOCAL_ROUTE); }
  else if (modelMode !== undefined && modelMode !== null && modelMode !== '') throw new Error('invalid_model_mode');
  if (!routes.length) throw new Error('provider_credential_missing');
  // `read` is also web search's credential (web-search.mjs): the same key or
  // custody token the provider's chat uses.
  return { models, routes, subscriptions, apiKeys, credential: read };
}

// What a route offers an agent's settings: pi-ai's facts about the model, and
// where this sidecar summarises its conversations.
export function modelView(model, compactAt = null) {
  return { id: routeName({ provider: model.provider, modelId: model.id }), name: model.name ?? model.id,
    thinkingLevels: getSupportedThinkingLevels(model), images: (model.input ?? []).includes('image'),
    contextWindow: model.contextWindow ?? null, compactAt };
}

// One committed entry as the messages Rails shows: text, tool calls with their
// ids (so Rails can place each call's record) and inputs (a script, a command,
// a URL: what the person sees the agent do), tool results by call id.
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
    const toolCalls = blocks.filter(block => block.type === 'toolCall').map(block => ({ id: block.id, name: block.name, arguments: block.arguments ?? {} }));
    return { id: index === 0 ? String(entry.id) : `${entry.id}:${index}`, entryId: entry.id,
      role: entry.kind === 'pi.compaction' ? 'summary' : message.role,
      content: blocks.map(block => block.type === 'text' ? block.text : block.type === 'toolCall' ? `[tool: ${block.name}]` : '').join(''),
      ...(thinkingOf(blocks) ? { thinking: thinkingOf(blocks) } : {}),
      ...(imagesOf(blocks).length ? { images: imagesOf(blocks) } : {}),
      ...(toolCalls.length ? { toolCalls } : {}),
      ...(message.toolName ? { toolName: message.toolName } : {}),
      ...(message.toolCallId ? { toolCallId: message.toolCallId } : {}),
      ...(message.role === 'toolResult' && message.isError ? { isError: true } : {}),
      ...(message.role === 'assistant' && message.usage ? { usage: replyUsage(message.usage) } : {}) };
  });
}
// What one reply cost in tokens, and at the catalogue's prices (0 when unpriced).
const replyUsage = usage => ({ ...Object.fromEntries(['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens']
  .map(key => [key, Number(usage[key] ?? 0)])), cost: Number(usage.cost?.total ?? 0) });

export const ENTRIES_PAGE_BYTES = 3 * 1024 * 1024;
// What a person may attach to one message; Rails holds the same limits
// (Conversation::IMAGES_PER_MESSAGE), and each side refuses on its own.
export const IMAGE_LIMITS = Object.freeze({ count: 4, bytes: 5 * 1024 * 1024,
  types: Object.freeze(['image/png', 'image/jpeg', 'image/webp', 'image/gif']) });
export const TEXT_LIMIT = 65536;
const BASE64 = /^[A-Za-z0-9+/]*={0,2}$/;
const decodedBytes = data => Math.floor(data.length * 3 / 4) - (data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0);
// A message is words, or content blocks: text and images ({type, data,
// mimeType}, base64). Images alone are a message too (a photo from a phone);
// nothing at all is not. Returns how many images it holds.
export function validContent(content) {
  const invalid = category => new ApiError(422, category);
  if (typeof content === 'string') {
    if (!content.trim() || content.length > TEXT_LIMIT) throw invalid('invalid_content');
    return 0;
  }
  if (!Array.isArray(content) || !content.length || content.length > IMAGE_LIMITS.count + 1) throw invalid('invalid_content');
  let text = '', images = 0;
  for (const block of content) {
    const keys = block && typeof block === 'object' ? Object.keys(block).sort().join(',') : '';
    if (keys === 'text,type' && block.type === 'text' && typeof block.text === 'string') text += block.text;
    else if (keys === 'data,mimeType,type' && block.type === 'image') {
      if (!IMAGE_LIMITS.types.includes(block.mimeType) || typeof block.data !== 'string' || !block.data ||
        block.data.length % 4 !== 0 || !BASE64.test(block.data) || decodedBytes(block.data) > IMAGE_LIMITS.bytes) throw invalid('invalid_images');
      images++;
    } else throw invalid('invalid_content');
  }
  if (images > IMAGE_LIMITS.count) throw invalid('invalid_images');
  if (text.length > TEXT_LIMIT || (!text.trim() && !images)) throw invalid('invalid_content');
  return images;
}
export const SIDECAR_TOOL_NAMES = Object.freeze(['read', 'write', 'edit', 'bash', 'visit_website', 'desktop', 'codemode', 'subagent', 'web_search']);
// The sidecar's built-in abilities, which Rails switches on per agent through the
// definition's `capabilities` (PARITY.md §6). No hosted agent runs code of its
// own making: the list is fixed here.
export const CAPABILITIES = Object.freeze(['codemode', 'subagents', 'web_search']);
// Memory one code mode script's VM may allocate.
export const CODEMODE_MEMORY_BYTES = 64 * 1024 * 1024;
const TOOL_NAME = /^[a-z][a-z0-9_]{0,63}$/;
export function validDefinition(input, routes, reserved = new Set(), offered = {}) {
  const invalid = category => new ApiError(422, category);
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw invalid('invalid_definition');
  const { digest: claimed, ...body } = input;
  const keys = Object.keys(body).filter(key => key !== 'computer' && key !== 'capabilities').sort().join(',');
  if (keys !== 'instructions,model,thinkingLevel,tools') throw invalid('invalid_definition');
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
  // Absent (a Rails that predates them) means none.
  const capabilities = body.capabilities ?? [];
  if (!Array.isArray(capabilities) || new Set(capabilities).size !== capabilities.length ||
    capabilities.some(name => !CAPABILITIES.includes(name))) throw invalid('invalid_capabilities');
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

// Running tool calls and the tail of what each has printed: model-issued calls
// until their result is an entry (shown in their place by then), nested calls
// (a code mode script's) until their script settles, since their results never
// become entries.
export const TOOL_OUTPUT_BYTES = 4096;
function outputTail(text) {
  if (typeof text !== 'string') return '';
  const bytes = Buffer.from(text);
  // Cut on bytes, then drop a character the cut split.
  return bytes.length <= TOOL_OUTPUT_BYTES ? text : bytes.subarray(-TOOL_OUTPUT_BYTES).toString('utf8').replace(/^\uFFFD+/, '');
}
// A helper's call (subagent.mjs) carries its child's running calls in its
// details; they show under it, named `<helper call>/<child call>`.
export const toolLine = slot => ({ callId: slot.callId, name: slot.name, status: slot.status, output: outputTail(slot.output) });
function liveTools(live) {
  return [...(live?.tools ?? []).filter(slot => slot.status !== 'done'), ...(live?.nestedTools ?? [])].flatMap(slot => [toolLine(slot),
    ...(Array.isArray(slot.details?.tools) ? slot.details.tools : []).map(tool => ({ ...tool, callId: `${slot.callId}/${tool.callId}` }))]);
}

// A summary being made, and the newest one that failed, by what started it.
// The error text stays here: it is a provider's words.
const liveCompaction = live => live?.compactions?.length ? { trigger: live.compactions[0].trigger } : null;
const compactionFailed = live => live?.compactionFailure ? { trigger: live.compactionFailure.trigger } : null;

// Pushes to Rails while a conversation runs: a frame with the whole live tail
// (Rails replaces, never appends, so a lost or reordered frame cannot corrupt
// the page) and a sync ping when entries commit (Rails pulls them, so a missed
// ping heals at the next). Both are best effort and throttled.
function railsNotifier(harness, { frame, sync, intervalMs, usage, notes }) {
  const watching = new Map();
  // Asked to watch while already watching: a watcher about to stop may have
  // judged the conversation idle just before this new run, so a fresh one
  // starts after it stops.
  const again = new Set();
  // Frame numbers only grow, across runs and restarts, so Rails can drop an
  // older frame that arrives after a newer one.
  let clock = Date.now();
  const nextSeq = () => (clock = Math.max(clock + 1, Date.now()));
  async function watch(id) {
    if (!frame && !sync) return;
    if (watching.has(id)) return void again.add(id);
    watching.set(id, null);
    try {
      const app = await harness.snapshot(App, id, context);
      const scope = { actorId: app?.actorId, workspaceId: app?.workspaceId, conversationId: String(id) };
      const conversation = await harness.conversation(id, context);
      const handle = await conversation.watch(context, { min: 1, max: 8 });
      const started = Date.now();
      let value = handle.value, timer, lastText, lastThinking, lastBusy, lastTools, lastCompaction, lastEntry = value.entries.at(-1)?.id, stopped = false, seenBusy = false;
      const stop = async () => {
        if (stopped) return;
        stopped = true; clearTimeout(timer); watching.delete(id);
        await handle.stop();
        if (again.delete(id)) void watch(id);
      };
      const flush = async () => {
        timer = undefined;
        const live = value.docs['pi.live'];
        const text = liveText(live), thinking = liveThinking(live), busy = live?.run !== undefined;
        const tools = busy ? liveTools(live) : [], toolsKey = JSON.stringify(tools);
        // A summary runs beside a run or, asked for, while the conversation is idle.
        const compaction = liveCompaction(live), failed = compactionFailed(live), compactionKey = JSON.stringify([compaction, failed]);
        const newest = value.entries.at(-1)?.id;
        if (newest !== lastEntry) { lastEntry = newest; await sync?.(scope).catch(() => {}); }
        if (text !== lastText || thinking !== lastThinking || busy !== lastBusy || toolsKey !== lastTools || compactionKey !== lastCompaction) {
          lastText = text; lastThinking = thinking; lastBusy = busy; lastTools = toolsKey; lastCompaction = compactionKey;
          // No frame follows the last one, so it alone is retried before giving up
          // (the page then corrects its status when it next loads). It carries the
          // conversation's totals, which only settle when the run ends.
          const payload = { ...scope, seq: nextSeq(), busy, tail: text, thinking, tools, failure: busy ? null : failureReason(live?.runFailure),
            compaction, compactionFailed: failed,
            ...(busy ? {} : { usage: usage ? await usage(conversation).catch(() => null) : null,
              notesFile: notes ? await notes(conversation.id).catch(() => null) : null }) };
          for (let attempt = 0; attempt < (busy ? 1 : 4); attempt++) {
            if (attempt) await new Promise(resolve => setTimeout(resolve, intervalMs * 2 ** attempt));
            if (await frame?.(payload).then(() => true, () => false)) break;
          }
        }
        const active = busy || compaction !== null;
        seenBusy ||= active;
        // A submission may not have started its run yet; give it a moment.
        if (!active && (seenBusy || Date.now() - started > 5000)) await stop();
        else if (!active) timer ??= setTimeout(() => { void flush(); }, intervalMs * 4);
      };
      handle.start(async call => {
        if (call.kind !== 'value') return;
        value = call.value;
        timer ??= setTimeout(() => { void flush(); }, intervalMs);
      });
      handle.closed.then(stop, stop);
      watching.set(id, handle);
      timer ??= setTimeout(() => { void flush(); }, intervalMs);
    } catch { watching.delete(id); again.delete(id); }
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
        const message = failure(model, ['model_route_denied', 'request_limit', 'runtime_limit', 'scope_missing', 'computers_busy', CRASH_LOOP].includes(error.message) ? error.message : 'model_request_failed');
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
  const compactAt = config.compactAtTokens ?? COMPACT_AT_TOKENS;
  if (!Number.isInteger(compactAt) || compactAt < 1024) throw new Error('invalid_compact_at');
  if (!isAbsolute(config.storePath ?? '')) throw new Error('absolute_store_required');
  // Injected models (tests) serve exactly the injected route.
  if (dependencies.models && !dependencies.model) throw new Error('approved_model_unavailable');
  const catalogue = dependencies.models ? { models: dependencies.models, routes: [dependencies.model], subscriptions: {}, apiKeys: {},
    credential: dependencies.credential ?? (async () => undefined) } : await boot('provider_credential_missing', () => productionModels(config));
  const { models, routes, subscriptions, apiKeys, credential } = catalogue;
  const route = routes[0];
  // A key's provider must answer for its models now; a subscription's routes,
  // and the pasted key's, are offered before the owner signs in (productionModels).
  const available = {};
  for (const candidate of routes) {
    if (!models.getModel(candidate.provider, candidate.modelId)) throw new Error('approved_model_unavailable');
    if (subscriptions[candidate.provider] || apiKeys[candidate.provider]) continue;
    available[candidate.provider] ??= new Set((await models.getAvailable(candidate.provider)).map(m => m.id));
    if (!available[candidate.provider].has(candidate.modelId)) throw new Error('approved_model_unavailable');
  }
  const modelOf = candidate => models.getModel(candidate.provider, candidate.modelId);
  // Durable's policy is fixed when the harness opens, so every route's override
  // is computed now, keyed by the exact "provider/modelId" Durable looks up.
  const modelOverrides = {};
  for (const candidate of routes) {
    const override = compactionOverride(modelOf(candidate).contextWindow, compaction, compactAt);
    if (override) modelOverrides[routeName(candidate)] = override;
  }
  const compactAtFor = candidate => compactAtOf(modelOf(candidate).contextWindow, compaction, compactAt);
  const priced = Object.fromEntries(routes.map(candidate => [routeName(candidate),
    Object.values(models.getModel(candidate.provider, candidate.modelId).cost ?? {}).some(rate => typeof rate === 'number' && rate > 0)]));
  if (typeof dependencies.authorize !== 'function' && typeof config.authorize !== 'function') throw new Error('authorization_callback_required');
  const authorize = dependencies.authorize ?? config.authorize;
  const invoke = dependencies.invoke ?? config.invoke;
  if (typeof invoke !== 'function') throw new Error('rails_invoke_callback_required');
  // A saved sign-in's password, fetched for the browser alone (sign-in.mjs).
  const signIn = dependencies.signIn ?? config.signIn;
  // Best-effort pushes to Rails; the page heals on load if one is lost.
  const frame = dependencies.frame ?? config.frame;
  const sync = dependencies.sync ?? config.sync;
  const execution = config.execution ?? 'none';
  if (!EXECUTION_MODES.includes(execution)) throw new Error('invalid_execution_mode');
  const shellNetwork = config.shellNetwork ?? 'host';
  if (!SHELL_NETWORK_MODES.includes(shellNetwork)) throw new Error('invalid_execution_mode');
  if (shellNetwork === 'isolated' && !shellIsolationAvailable()) throw new Error('shell_isolation_unavailable');
  // Which computers this sidecar can give an agent; the agent's definition picks one.
  const offered = offeredComputers({ execution, sprites: config.sprites });
  const sprites = offered.sprites ? spritesComputers({ ...config.sprites, onLog: dependencies.onComputerLog }) : undefined;
  // Command connectors' processes, each on its agent's computer.
  const connectors = commandConnectors(dependencies.connectorTimings);
  const owner = await boot('storage_unavailable', () => ownStore(config.storePath));
  let harness, storage, codemode;
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
    // Conversations whose computer could not wake because too many are
    // awake; their next model request ends the run as `computers_busy`.
    const busy = new Set();
    // Summaries asked for and still being made, by conversation and request.
    const compacting = new Map();
    // The conversation's own computer. A helper uses the computer of the
    // conversation it works for.
    const computerEnv = async (conversationId, computer, scope) => {
      const owner = scope?.root?.conversationId ?? conversationId;
      if (computer.provider === 'sprites') {
        try { return await sprites.env(spriteName(computer.name, owner)); } catch (error) {
          if (/\bcomputers_busy\b/.test(error?.message ?? '')) busy.add(conversationId);
          throw error;
        }
      }
      if (!scope?.cwd || !isAbsolute(scope.cwd)) throw new Error('scope_missing');
      return localEnv({ root: scope.cwd, conversationId: owner, shellNetwork, shellTmpDir: config.shellTmpDir,
        isolate: command => ['unshare', '--user', '--map-current-user', '--net', '--', ...(typeof command === 'string' ? ['/bin/bash', '-c', command] : command)] });
    };
    // File and shell tools, given only to conversations whose agent has a computer.
    const computerExtensions = [];
    if (offered.local || offered.sprites) {
      const images = await createNodePhotonImages({ worker: false });
      computerExtensions.push(createCodingTools({ images }), readGuard, browserExtension, desktopExtension);
      for (const extension of computerExtensions) registry.install(extension);
    }
    registry.install(infraExtension());
    // Code mode: the model may write one JavaScript script that calls the
    // conversation's tools (Rails' and the computer's) with loops and
    // Promise.all, in a QuickJS sandbox with no file system or network of its
    // own. Every call it makes is an ordinary tool call, so Rails' ledger and
    // approvals apply as usual. No model helpers: the sidecar runs one model.
    codemode = new CodemodeSandbox({ memoryLimitBytes: CODEMODE_MEMORY_BYTES });
    // One extension per capability; a conversation gets those its agent names.
    const capabilityExtensions = { codemode: createCodemodeExtension({ sandbox: codemode, models: false }),
      subagents: subagentExtension({ toolLine }),
      web_search: webSearchExtension({ credential, reserve: id => reserveRequest(id), fetch: dependencies.fetch }) };
    for (const extension of Object.values(capabilityExtensions)) registry.install(extension);
    for (const extension of dependencies.extensions ?? []) registry.install(extension);
    // Everything but agent definitions, computers and capabilities: what every
    // conversation in a scope gets.
    const isAgentExtension = extension => extension.name.startsWith('bot.');
    const forComputer = extension => computerExtensions.some(own => own.name === extension.name);
    const isCapability = extension => Object.values(capabilityExtensions).some(own => own.name === extension.name);
    const infraFor = () => registry.snapshot().installed().filter(extension => !isAgentExtension(extension) && !forComputer(extension) && !isCapability(extension));
    // The computer's tools; the desktop only where there is a screen, a Sprite.
    const computerFor = ({ computer }) => !computer ? [] :
      computerExtensions.filter(extension => extension !== desktopExtension || computer.provider === 'sprites');
    const capabilitiesFor = definition => (definition.capabilities ?? []).map(name => capabilityExtensions[name]).filter(Boolean);
    // An agent's tool may not take the name of one of the sidecar's, installed here or not.
    const reservedToolNames = () => new Set([...SIDECAR_TOOL_NAMES,
      ...registry.snapshot().installed().filter(e => !isAgentExtension(e)).flatMap(e => (e.tools ?? []).map(t => t.name))]);
    const installDefinition = definition => {
      const name = `bot.${definition.digest}`;
      if (!registry.snapshot().extension(name)) registry.install(agentExtension(definition, { ...limits, invoke, signIn }));
      return registry.snapshot().extension(name);
    };
    // The newest tool round: the entries after the newest assistant answer.
    const crashLoopedRound = async id => crashLoopAfter(await harness.conversation(id, context), entry => entry.kind === 'pi.assistant');
    // One request of a run's bound, for a model request or a web search; the
    // time the run has left.
    async function reserveRequest(id) {
      await checkPermission(await harness.snapshot(App, id, context));
      if (busy.delete(id)) throw new Error('computers_busy');
      // Since 1.5.0 a tool the restart limit cut off gets an error result and the
      // run would go on. Like the 1.4 park, stop instead: no further request
      // after crash-loop protection fired in the newest tool round.
      if (await crashLoopedRound(id)) throw new Error(CRASH_LOOP);
      return harness.commit(async tx => {
        // A helper's requests count against the run of the conversation it works for.
        const own = await tx.doc(App, id);
        const app = own.root ? await tx.doc(App, own.root.conversationId) : own;
        if (!app.actorId || !app.workspaceId) throw new Error('scope_missing');
        if (app.bounds.requests >= limits.maxRequests) throw new Error('request_limit');
        if (app.bounds.startedAt !== null && Date.now() - app.bounds.startedAt >= limits.maxRuntimeMs) throw new Error('runtime_limit');
        app.bounds.startedAt ??= Date.now();
        app.bounds.requests++;
        return Math.max(1, limits.maxRuntimeMs - (Date.now() - app.bounds.startedAt));
      }, context);
    }
    const safeModels = guardedModels(models, async sessionId => {
      if (!sessionId) throw new Error('scope_missing');
      const id = (await harness.snapshot(Admission, context))?.sessions[sessionId];
      if (!id) throw new Error('scope_missing');
      return reserveRequest(id);
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
        maxAgentDelayMs: 30000 }, compaction: { ...compaction, modelOverrides }, afterFailedRun: 'withdraw', progress: { persistWithinMs: limits.persistWithinMs },
        stream: { maxRetries: 0 }, restartLimit: limits.restartLimit, toolExecution: TOOL_EXECUTION },
      // Pi builds this for every model request and tool call of a conversation
      // whose agent has a computer; an agent without one never reaches a computer.
      env: async ({ conversationId, read }) => {
        const stored = await read.snapshot(Definitions, context);
        const computer = stored?.byDigest[stored.conversations[conversationId]]?.computer;
        if (!computer || offered[computer.provider] !== true) return undefined;
        return computerEnv(conversationId, computer, await read.snapshot(App, conversationId, context));
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
    // The conversation's totals, from the runtime's own count (it also counts
    // compaction and tools), priced only when its model has catalogue prices.
    async function conversationUsage(conversation) {
      const agent = await conversation.agent(context);
      return usageView(await harness.snapshot(UsageDoc, conversation.id, context),
        priced[agent?.model ? routeName(agent.model) : routeName(route)] === true);
    }
    const notifier = railsNotifier(harness, { frame, sync, intervalMs: limits.frameIntervalMs, usage: conversationUsage, notes: notesView });
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
    // The name of the Sprite behind a conversation's screen, for the person who owns
    // it; Rails names the agent's computer prefix, as in a definition.
    async function screenSprite(id, scope, prefix) {
      await access(id, scope);
      if (!sprites) throw new ApiError(422, 'computer_unavailable');
      if (validComputer({ provider: 'sprites', name: prefix }) === undefined) throw new ApiError(422, 'invalid_computer');
      try { return spriteName(prefix, Number(id)); } catch { throw new ApiError(422, 'invalid_computer'); }
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
    // A definition is Rails' word for what the agent is now. It must name itself
    // by its own digest, use an offered model, and declare plain JSON tools that
    // shadow none of the sidecar's own. A new digest reconfigures the
    // conversation from its next request.
    async function configureAs(conversation, definition, extension = installDefinition(definition), notes = null) {
      const [provider, modelId] = definition.model.split('/');
      // Rails offers each model's own levels, but an agent saved before may name
      // another; the model runs at its nearest supported level.
      const thinkingLevel = clampThinkingLevel(modelOf({ provider, modelId }), definition.thinkingLevel);
      const instructions = [definition.instructions, notes?.section].filter(Boolean).join('\n\n');
      await conversation.configure({ model: { provider, modelId }, thinkingLevel, instructions,
        extensions: [...infraFor(), extension, ...capabilitiesFor(definition), ...computerFor(definition)] }, context);
    }
    // Whether the model the conversation runs now can look at pictures.
    async function seesImages(conversation) {
      const model = (await conversation.agent(context))?.model ?? route;
      return models.getModel(model.provider, model.modelId)?.input?.includes('image') === true;
    }
    // The notes file as the agent reads it, appended to its instructions. Read
    // when a run starts, not before every request, so the prompt cache holds
    // within a run. Rails waits ten seconds for a submission, so a computer
    // slower than five (a Sprite waking) leaves the notes as last read.
    async function notesFor(conversation, definition) {
      if (definition.computer?.notesFile !== true) return null;
      const scope = await harness.snapshot(App, conversation.id, context);
      const notes = await Promise.race([computerEnv(conversation.id, definition.computer, scope).then(env => readNotes(env, context)),
        new Promise((_, reject) => setTimeout(() => reject(new Error('notes_timeout')), 5000).unref())]);
      if (!notes) return null;
      const section = `# Notes file (${NOTES_FILE})\n\n` + (notes.text ?? `Your notes file, ${NOTES_FILE} in your computer folder, is ${Math.ceil(notes.bytes / 1024)} KB, ` +
        `over the ${NOTES_LIMIT / 1024} KB that is read, so it was not read. Shorten it to have it read again.`);
      return { bytes: notes.bytes, section, digest: digest(section) };
    }
    async function runDefinition(conversation, input) {
      const definition = validDefinition(input.definition, routes, reservedToolNames(), offered);
      const extension = installDefinition(definition);
      const current = await harness.snapshot(Definitions, context);
      const same = current?.conversations[conversation.id] === definition.digest;
      const starting = !(await harness.snapshot(LiveDoc, conversation.id, context))?.run;
      if (same && !starting) return;
      const stored = current?.notes?.[conversation.id];
      let notes;
      try { notes = await notesFor(conversation, definition); } catch {
        // Unreadable now: run as before, and try again at the next run.
        if (same) return;
        notes = null;
      }
      if (same && stored !== undefined && (stored?.digest ?? null) === (notes?.digest ?? null)) return;
      await configureAs(conversation, definition, extension, notes);
      await harness.commit(async tx => {
        const stored = await tx.doc(Definitions);
        stored.byDigest[definition.digest] = definition;
        stored.conversations[conversation.id] = definition.digest;
        stored.notes ??= {};
        stored.notes[conversation.id] = notes ? { digest: notes.digest, bytes: notes.bytes } : null;
      }, context);
    }
    // What the page says about the notes file the conversation runs with.
    async function notesView(id) {
      const notes = (await harness.snapshot(Definitions, context))?.notes?.[id];
      return notes ? { bytes: notes.bytes } : null;
    }
    const runtime = {
      harness, registry, reports, limits, route, routes, execution, shellNetwork, offered,
      // Each subscription's custody, by provider, for the owner console (server.mjs).
      subscriptions,
      // The pasted API key's custody, by provider, for the same console.
      apiKeys,
      // The models this sidecar can run now, for Rails' agent settings.
      catalogue: () => ({ models: routes.map(candidate => modelView(modelOf(candidate), compactAtFor(candidate))) }),
      // Durable's compaction policy as this harness runs it, overrides included.
      compaction: Object.freeze({ ...compaction, modelOverrides, compactAt }),
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
        await conversation.configure({ model: route, thinkingLevel: clampThinkingLevel(modelOf(route), 'medium'), cwd: permission.cwd, extensions: infraFor() }, context);
        return { id };
      },
      // A new conversation that starts as a copy of this one up to and including
      // entry `at` and goes on on its own. Fork-aware entries include the
      // parent's history, so Rails' cursor pull fills the copy. The scope doc
      // forks as 'initial' (fresh admissions, requests and bounds), so the scope
      // is written in the creating commit, with the parent's definition: tools
      // work from the first message. This is what Conversation.fork(at, {init})
      // does, inside the commit that also checks the request id, so a repeat
      // answers the same fork. A fork's computer folder is its own
      // (<cwd>/<id>), so it starts empty.
      async fork(id, input) {
        const { app, conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        if (!Number.isSafeInteger(input.at) || input.at < 0) throw new ApiError(422, 'invalid_entry');
        const found = await conversation.entries({ order: 'ascending', minEntryId: input.at, maxEntryId: input.at }, 1, undefined, context);
        if (found.items[0]?.id !== input.at) throw new ApiError(422, 'invalid_entry');
        const key = digest(['fork', input.actorId, input.workspaceId, input.requestId]);
        const payload = digest({ parent: conversation.id, at: input.at });
        const forked = await harness.commit(async tx => {
          const admissions = await tx.doc(Admission);
          const prior = admissions.conversations[key];
          if (prior) { if (prior.digest !== payload) throw new ApiError(409, 'request_conflict'); return prior.id; }
          const record = await tx.forkConversation(conversation.id, input.at, { ownership: { kind: 'ownerless' } });
          const scope = await tx.doc(App, record.id);
          scope.actorId = app.actorId; scope.workspaceId = app.workspaceId; scope.cwd = app.cwd;
          const stored = await tx.doc(Definitions);
          if (stored.conversations[conversation.id]) stored.conversations[record.id] = stored.conversations[conversation.id];
          admissions.conversations[key] = { id: record.id, digest: payload };
          return record.id;
        }, context);
        // The fork keeps the agent its parent had at `at`; the definition copied
        // above is the parent's now. Configure to match, so an agent edited since
        // that entry is not skipped as current on the fork's first message.
        // Repeats configure again, which changes nothing.
        const stored = await harness.snapshot(Definitions, context);
        const definition = stored?.byDigest[stored.conversations[forked]];
        if (definition) await configureAs(await harness.conversation(forked, context), definition);
        return { id: forked };
      },
      async submit(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        const images = validContent(input.content);
        if (input.whenBusy !== undefined && !['steer', 'followUp', 'reject'].includes(input.whenBusy)) throw new ApiError(422, 'invalid_busy_mode');
        if (input.definition !== undefined) await runDefinition(conversation, input);
        // Refused before admission: a model without image input would fail the run, or worse, answer as if it had looked.
        if (images && !(await seesImages(conversation))) throw new ApiError(422, 'images_unsupported');
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
      // A summary the person asked for (/compact), with optional words on what
      // to keep. Durable makes it while the conversation goes on and places it
      // at the next turn boundary. Repeatable by request id.
      async compact(id, input) {
        const { app, conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        const instructions = input.instructions ?? null;
        if (instructions !== null && (typeof instructions !== 'string' || instructions.length > COMPACTION_INSTRUCTIONS_LIMIT))
          throw new ApiError(422, 'invalid_instructions');
        const key = digest(['compact', input.requestId]), payload = digest({ instructions });
        const recorded = doc => {
          const prior = doc?.compactions?.[key];
          if (prior && prior.digest !== payload) throw new ApiError(409, 'request_conflict');
          return prior?.id;
        };
        if (recorded(app) !== undefined) return { id: String(recorded(app)) };
        // A summary is not made in a transaction, so a retry of a request still
        // being made joins it rather than starting a second summary.
        const flight = `${conversation.id}:${key}`;
        let made = compacting.get(flight);
        if (made && made.digest !== payload) throw new ApiError(409, 'request_conflict');
        if (!made) {
          made = { digest: payload, task: (async () => {
            // The one before may have finished since `app` was read.
            const done = recorded(await harness.snapshot(App, conversation.id, context));
            if (done !== undefined) return done;
            const task = await conversation.compact(instructions?.trim() || undefined, context);
            await harness.commit(async tx => {
              const doc = await tx.doc(App, conversation.id);
              // A conversation created before compactions were recorded has none yet.
              doc.compactions ??= {};
              doc.compactions[key] = { digest: payload, id: task };
            }, context);
            return task;
          })().finally(() => compacting.delete(flight)) };
          compacting.set(flight, made);
        }
        const task = await made.task;
        void notifier.watch(conversation.id);
        return { id: String(task) };
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
      // The conversation's screen: wakes its Sprite and answers a process whose
      // stdin and stdout are a byte pipe to the screen's websockify. Rails
      // names the agent's computer prefix, as it does in every definition, so
      // the screen opens before the agent's first message too.
      async screen(id, scope, prefix) {
        const name = await screenSprite(id, scope, prefix);
        try { return await sprites.screen(name); } catch (error) {
          throw /\bcomputers_busy\b/.test(error?.message ?? '') ? new ApiError(429, 'computers_busy') : new ApiError(503, 'computer_unavailable');
        }
      },
      // `{waking: 'cold'}` when opening the screen would bring the conversation's
      // disk back from cold storage (up to a minute, not seconds), else
      // `{waking: null}`, so the page can say so. A lookup: nothing wakes.
      async computer(id, scope, prefix) {
        const name = await screenSprite(id, scope, prefix);
        return { waking: (await sprites.state(name)) === 'cold' ? 'cold' : null };
      },
      // The conversation's agent was deleted: its Sprite goes too.
      async removeComputer(id, scope, prefix) {
        const name = await screenSprite(id, scope, prefix);
        try { await sprites.destroy(name); } catch { throw new ApiError(502, 'sprite_unavailable'); }
        return { removed: true };
      },
      // One JSON-RPC message to a command connector (command-connectors.mjs)
      // on the conversation's own computer, which Rails names as in a definition.
      // Rails is the MCP client; this only keeps the process and the pipe.
      async connector(id, name, input) {
        const { app } = await access(id, input);
        if (!CONNECTOR_NAME.test(name)) throw new ApiError(404, 'not_found');
        const computer = validComputer(input.computer);
        if (!computer) throw new ApiError(422, 'invalid_computer');
        if (offered[computer.provider] !== true) throw new ApiError(422, 'computer_unavailable');
        const spec = input.entry && typeof input.entry === 'object' ? validSpec(input.entry) : undefined;
        if (!spec) throw new ApiError(422, 'invalid_connector');
        const message = input.message;
        if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string' || !['string', 'number'].includes(typeof message.id))
          throw new ApiError(422, 'invalid_message');
        const start = async () => {
          if (computer.provider !== 'sprites') {
            if (!isAbsolute(app.cwd ?? '')) throw new ApiError(422, 'computer_unavailable');
            return localCommand(spec, join(app.cwd, String(id)));
          }
          try { return await sprites.command(spriteName(computer.name, Number(id)), spec); } catch (error) {
            throw /\bcomputers_busy\b/.test(error?.message ?? '') ? new ApiError(429, 'computers_busy') : new ApiError(503, 'computer_unavailable');
          }
        };
        const where = computer.provider === 'sprites' ? computer.name : 'local';
        return { message: await connectors.message(`${id}:${name}`, { ...spec, where }, message, () => start()) };
      },
      // The whole history as pi's session file (session-file.mjs), one object
      // per line, read and written a page at a time. Rails names it: the title
      // is its, not the store's.
      async export(id, scope) {
        const { conversation } = await access(id, scope);
        const stored = await harness.snapshot(Definitions, context);
        return sessionFile(allEntries(conversation), {
          id: (await harness.snapshot(ProviderDoc, conversation.id, context)).sessionId, title: scope.title,
          instructions: stored?.byDigest[stored.conversations[conversation.id]]?.instructions,
          model: (await conversation.agent(context))?.model });
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
      // binding, task/call identity or other conversations' data. No history
      // either: Rails pages that from `entries`, and a page load asks for this,
      // so it reads only the newest run's entries however long the thread.
      async snapshot(id, scope) {
        const { conversation } = await access(id, scope);
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
        // Crash-loop protection ended the run's work (a task cut off restartLimit
        // times): recovery-needed, reported as `blocked`, not silently retried.
        // The run began at `first`, or else after the person's newest message.
        const runStart = runFailure?.first === undefined ? entry => entry.kind === 'pi.user' : entry => entry.id < runFailure.first;
        const crashLoop = runFailure !== undefined && (runFailure.reason === CRASH_LOOP || await crashLoopAfter(conversation, runStart));
        const failure = runFailure ? { reason: crashLoop ? CRASH_LOOP : failureReason(runFailure) } : null;
        // Stalled: the run's tasks, a helper's included, are there but none runs or
        // sleeps, so nothing will move them (a missed wake, as pi#11892 was).
        // A moment of it is ordinary between steps; Rails acts only on one that
        // lasts (Conversation#recover).
        const tree = new Set((await ownedTree(conversation.id)).tasks);
        const run = inspection.tasks.filter(t => tree.has(t.record.id));
        const stalled = stalledRun(run.map(t => t.state));
        const status = tasks.some(t => t.state.kind === 'blocked') || crashLoop ? 'blocked' : pendingInputs.length ? 'waiting' :
          stalled ? 'stalled' : tasks.length ? 'running' : submission?.status === 'unanswered' ?
            (['aborted', 'withdrawn', 'cancelled'].includes(submission.reason) ? 'cancelled' : 'error') : submission?.status === 'done' ? 'done' : 'idle';
        return { id: conversation.id, pendingInputs, status, failure, usage: await conversationUsage(conversation),
          compaction: liveCompaction(live), compactionFailed: compactionFailed(live), notesFile: await notesView(conversation.id) };
      },
      async close() { try { await harness.close(context); } finally { connectors.close(); await codemode?.close(); sprites?.close(); owner.release(); } }
    };
    return runtime;
  } catch (error) {
    try { if (harness) await harness.close(context); else await storage?.close(context);
      await codemode?.close(); sprites?.close(); } finally { owner.release(); }
    throw error;
  }
}
