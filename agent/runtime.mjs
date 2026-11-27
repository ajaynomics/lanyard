import { declarationsEqual } from '@earendil-works/pi-ai/utils/transcript';
import { isAbsolute, extname, join, normalize } from 'node:path';
import { spawnSync } from 'node:child_process';
import { access as fileExists } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels, getSupportedThinkingLevels, clampThinkingLevel } from '@earendil-works/pi-ai/models';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { localProvider } from './local-model.mjs';
import { currentInstructions } from './current-instructions.mjs';
import { subscriptionProvider, subscriptionCustody } from './claude-subscription.mjs';
import { borrowedCustody, validLending } from './subscription-lending.mjs';
import { DEFAULT_APPLICATION } from './subscription-credentials.mjs';
import { claudeRouter, claudeRouteList, validRouteName } from './claude-routes.mjs';
import { chatgptProvider, chatgptCustody, CHATGPT_PROVIDER } from './chatgpt-subscription.mjs';
import { borrowedChatgptProvider, borrowedChatgptCustody, BORROWED_CHATGPT_PROVIDER } from './chatgpt-lending.mjs';
import { apiKeyProvider, apiKeyCustody, API_KEY_PROVIDER } from './claude-api-key.mjs';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai';
import { Harness, createRegistry, ProviderDoc, LiveDoc, UsageDoc, InboxDoc, DEFAULT_COMPACTION_POLICY,
  defineExtension, hook, ToolTask, GenerationTask, CompactionTask, UserEntry, ConversationBusy } from '@earendil-works/pi-durable';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { createCodingTools } from '@earendil-works/pi-durable/tools';
import { createNodePhotonImages } from '@earendil-works/pi-durable/images/node';
import { createCodemodeExtension } from '@earendil-works/pi-durable/codemode';
import { CodemodeSandbox } from '@earendil-works/pi-codemode';
import { App, Admission, Definitions, MessageEntry, WaitingEntry, validAuthor, digest, ApiError, scopeMatches, requiredString } from './state.mjs';
import { infraExtension, agentExtension } from './extensions.mjs';
import { wholeResults } from './whole-results.mjs';
import { secretMask } from './secret-mask.mjs';
import { batchesExtension } from './batches.mjs';
import { waitingNote } from './waiting.mjs';
import { phoneInput, phoneInRun, phoneMessages, phoneRead, phoneScope } from './phone-scope.mjs';
import { saveHeld } from './files.mjs';
import { forgeFileRequest, transferForgeFile } from './forge-files.mjs';
import { liveInvocations } from './live-invocations.mjs';
import { ownStore } from './ownership.mjs';
import { validComputer, offeredComputers, localEnv, spritesComputers, spriteName, screenScript, readNotes, NOTES_FILE, NOTES_LIMIT } from './computers.mjs';
import { isConfiguredSsh, sshComputers, sshCommand } from './ssh-computers.mjs';
import { FILE_TOOLS, chooseComputer, validNamedComputers, namedCodingTools } from './named-computers.mjs';
import { boxdComputer } from './boxd-computer.mjs';
import { browserExtension, retainedVisit } from './browser.mjs';
import { sandboxBrowser } from './sandbox-browser.mjs';
import { desktopExtension, retainedDesktop } from './desktop.mjs';
import { bashLimit, BASH_DEFAULT_TIMEOUT_SECONDS, BASH_TIMEOUT_CAP_SECONDS } from './bash-limit.mjs';
import { subagentExtension, callsMade, steerHelper, startNamedHelper, usageRows, HELPER_TASK } from './subagent.mjs';
import { webSearchExtension } from './web-search.mjs';
import { sessionFile } from './session-file.mjs';
import { commandConnectors, localCommand, validSpec, CONNECTOR_NAME } from './command-connectors.mjs';
import { carrier, CARRIED } from './carry.mjs';

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
// As in pi, a turn has no time limit and no cap on its tool rounds: it runs
// until the model answers or the person stops it. Two guards stay. A model
// request (or a web search) that sends nothing for requestIdleMs is given up,
// as pi's provider timeout does (httpIdleTimeoutMs, five minutes). maxRequests
// is a safety stop for an agent stuck in a loop, high enough that no real turn
// meets it; it counts from the newest message the conversation received.
// persistWithinMs: how long streamed progress may stay in memory before it is
// stored (Durable's default is 1000 ms); a crash loses at most about this much.
// humanTimeoutMs bounds a wait for a person when Rails names no deadline;
// recheckMs is how often a waiting call asks Rails again without a doorbell.
// invokeRetries/invokeRetryMs: brief retries of a Rails callback that failed
// on the network (Rails restarting) before it becomes the call's error.
// helperRetryMs: the first wait before a background helper tells Rails again
// how it ended, doubling to ten minutes, for at most helperReportForMs (a day)
// (subagent.mjs).
// summaryBackoffMs: after a summary every model tried refused, how long no
// summary starts on its own (a person's /compact still does): 30 minutes.
export const DEFAULT_LIMITS = Object.freeze({ maxRequests: 300, requestIdleMs: 300000, helperRetryMs: 5000, helperReportForMs: 86400000,
  humanTimeoutMs: 86400000, recheckMs: 60000, invokeRetries: 3, invokeRetryMs: 1000,
  restartLimit: 5, maxRetries: 2, retryBaseDelayMs: 2000, persistWithinMs: 100, frameIntervalMs: 200, summaryBackoffMs: 1800000,
  bashTimeoutMs: BASH_DEFAULT_TIMEOUT_SECONDS * 1000 });
// Durable's automatic compaction (summarise older context before it overflows),
// on by default with Durable's thresholds; `config.compaction` overrides fields.
export const DEFAULT_COMPACTION = Object.freeze({ ...DEFAULT_COMPACTION_POLICY, enabled: true });
// Summarise at 180,000 tokens, however large the window. Every model call reads
// the whole context again, mostly from the prompt cache at a tenth of the input
// price, so that re-read is most of an agent's cost. Summarising earlier keeps
// the average call smaller; a summary costs a full-price read and rewrites the
// cache, so summarising much earlier than this costs more than it saves
// (the numbers: docs/agent.md, "Summaries and a provider's refusal"). A model
// also reasons worse over a very long context. `AGENT_COMPACT_AT_TOKENS` overrides it.
export const COMPACT_AT_TOKENS = 180000;
// Durable blocks to compact above contextWindow - reserveTokens, harness-wide,
// so a large window gets its own reserve to block at `compactAt` instead.
// backgroundTokens keeps its default: a background summary starts that much
// earlier (about 147k). A window already blocking below compactAt needs none.
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
// The longest task Rails gives a helper it starts (Helper::TASK_LIMIT).
export const HELPER_TASK_LIMIT = 10000;
// `host` (default): the tool shell keeps the host network. `isolated`: every tool
// shell command runs in a fresh unprivileged user+network namespace (Linux
// `unshare`), so it has no route off the host (not even host loopback).
// Readiness fails closed when the kernel refuses user namespaces.
export const SHELL_NETWORK_MODES = Object.freeze(['host', 'isolated']);
// Readiness reasons. Each is actionable and carries no path, token or raw error.
export const READINESS_REASONS = Object.freeze(['store_already_owned', 'storage_unavailable', 'store_recovery_failed',
  'approved_model_unavailable', 'incompatible_definitions', 'absolute_store_required', 'invalid_execution_mode',
  'shell_isolation_unavailable', 'provider_credential_missing', 'anthropic_credential_ambiguous',
  'claude_subscription_invalid', 'chatgpt_subscription_invalid', 'claude_lending_invalid', 'chatgpt_lending_invalid',
  'chatgpt_credential_ambiguous', 'claude_routes_invalid', 'claude_routes_ambiguous']);
// pi's default: a round of tool calls runs at once, unless one of its tools
// declares `executionMode: 'sequential'` (it shares state, as the screen's
// browser does). Results reach the model in the order it made the calls.
// Safe since pi-durable 1.5.1, which fixed pi#11892 (test/tool-calls.test.mjs).
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
// A paused agent's refusal (Sidecar::AccessesController answers {allowed: false, paused: true}).
const PAUSED = 'paused_by_owner';
// The fixed reason a run ended without an answer, the only part of
// pi.live.runFailure that leaves the sidecar. A provider's refusal for usage
// limits (HTTP 429, a subscription's limit) is told apart from other model
// errors, so the person learns to wait or switch, not that something broke.
// A model whose credential is missing (a subscription signed out, no API key
// pasted) is told apart too, so the person learns where to set it.
export function failureReason(runFailure) {
  if (!runFailure) return null;
  // The summary a request waited for failed; the person can ask for one again.
  // Refused by the provider on every model tried, the person learns that switching may help.
  if (runFailure.reason === 'model_error' && /^Compaction failed:/.test(runFailure.detail ?? '')) {
    return runFailure.detail.includes(SUMMARY_REFUSED) ? 'compaction_refused' : 'compaction_failed';
  }
  if (runFailure.reason === 'model_error' && /\b429\b|rate[_ ]limit/i.test(runFailure.detail ?? '')) return 'rate_limited';
  if (runFailure.reason === 'model_error' && /^Provider is not configured:/.test(runFailure.detail ?? '')) return 'credential_missing';
  // The conversation's computer could not wake: the platform's awake cap is reached,
  // or an operator holds it while rebuilding it (Computer#hold!).
  if (runFailure.reason === 'model_error' && /\bcomputers_busy\b/.test(runFailure.detail ?? '')) return 'computers_busy';
  if (runFailure.reason === 'model_error' && /\bcomputer_held\b/.test(runFailure.detail ?? '')) return 'computer_held';
  // A guard of this sidecar's stopped it: the safety stop on requests, or a model that went quiet.
  if (runFailure.reason === 'model_error' && ['request_limit', 'request_timeout'].includes(runFailure.detail)) return runFailure.detail;
  // Its owner paused the agent: the run was refused its next step.
  if (runFailure.reason === 'model_error' && runFailure.detail === PAUSED) return PAUSED;
  return runFailure.reason;
}

// A provider that declines to answer for safety (Anthropic's `refusal` and
// `sensitive`, OpenAI's `content_filter`, Google's `SAFETY` and kin, Bedrock's
// guardrail) ends the message in error with its own stop reason, which pi-ai
// keeps raw. That, not the provider's words, tells a refusal from a failure.
const REFUSAL_STOPS = /refusal|sensitive|content_filter|safety|prohibited_content|blocklist|spii|guardrail/i;
export const refusedSummary = message => message?.stopReason !== 'stop' && REFUSAL_STOPS.test(message?.rawStopReason ?? '');
// Marks a summary refused on every model tried, in the error Durable keeps,
// so the run's failure and the shown status can say so.
export const SUMMARY_REFUSED = 'summary_refused';
// The model a refused summary is asked of once more: `chosen` (the config
// file's `summaryFallback`, an offered route) when given, none when false,
// else by rule. Another offered route whose window holds at least as much,
// the same provider's first (its sign-in already works), the cheapest of
// those (a lighter model, its own safety judgement), in catalogue order on a tie.
export function summaryFallback(primary, routes, modelOf, chosen) {
  if (chosen === false) return undefined;
  const others = routes.filter(route => routeName(route) !== routeName(primary));
  if (typeof chosen === 'string') return others.find(route => routeName(route) === chosen);
  const window = modelOf(primary)?.contextWindow ?? 0;
  const price = route => modelOf(route)?.cost?.input ?? 0;
  const same = route => route.provider === primary.provider ? 0 : 1;
  return others.filter(route => (modelOf(route)?.contextWindow ?? 0) >= window)
    .sort((a, b) => same(a) - same(b) || price(a) - price(b))[0];
}
// The kind of a failed summary's error that Rails may show; never its words.
const summaryFailureReason = error => error?.includes(SUMMARY_REFUSED) ? 'refused' : /\b429\b|rate[_ ]limit/i.test(error ?? '') ? 'rate_limited' : null;
const crashLoopIn = entries => entries.some(entry => entry.kind === 'pi.tool-result' &&
  (entry.data?.diagnostics ?? []).some(d => d?.code === CRASH_LOOP));
// Image formats a reader might mistake for text. A file with one of these
// extensions that the read tool did not return as an image fails clearly.
// PPM and its kin are what pdftoppm draws a PDF's pages as unless told -png.
const IMAGE_EXTENSIONS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.tif', '.tiff', '.heic', '.heif',
  '.avif', '.ico', '.jxl', '.ppm', '.pgm', '.pbm', '.pnm']);
const readGuard = defineExtension({ name: 'omakase.read-guard', hooks: [hook(ToolTask, {
  afterTool: async (call, result) => {
    if (call.name !== 'read' || result.isError || typeof call.arguments?.path !== 'string') return undefined;
    if (!IMAGE_EXTENSIONS.has(extname(call.arguments.path).toLowerCase())) return undefined;
    if ((result.output ?? []).some(block => block.type === 'image')) return undefined;
    return { output: [{ type: 'text', text: `${call.arguments.path} is not a supported image (jpg, png, gif, webp, bmp); it was not read as text. ` +
      'Convert it first; draw a PDF\'s pages with `pdftoppm -png`.' }],
      isError: true, diagnostics: [{ severity: 'error', code: 'unsupported_image', message: 'unsupported image' }] };
  }
})] });
class BootError extends Error {}
// Usage as the runtime recorded it. Token counts are measured; a monetary amount
// is shown only when the model route has catalogue prices, and is then labelled
// an estimate, never a provider bill. Beside the sum, each model's and tool's
// own running total, which Rails meters (usageRows).
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
    { estimatedTotal: null, basis: 'price_unavailable' }, ...usageRows(usage) };
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
//
// claudeBorrow ({socketPath, secret}) reaches Claude through another install's
// subscription instead of this one's own grant (subscription-lending.mjs);
// claudeSubscription's file then only keeps the pasted API key.
//
// chatgptBorrow ({socketPath, secret}) reaches OpenAI through a lender's
// "Sign in with ChatGPT" (chatgpt-lending.mjs), the `openai-chatgpt` provider.
// It is a different sign-in from chatgptSubscription's Codex one, never
// beside it: one ChatGPT account per install, so a model never says one
// sign-in and runs on another.
//
// claudeRoutes ({routes, secret}) borrows instead from several lenders, named
// and in order (claude-routes.mjs): `claude` routes each Claude call, falling
// back to the next route at a usage limit. Never with claudeBorrow. With
// claudeSubscription too, the install's own grant stays `lendable`: how its
// own calls are routed has no bearing on what it lends.
export function productionModels({ openaiApiKey, anthropicApiKey, claudeSubscription, claudeBorrow, claudeRoutes, claudeLend, chatgptSubscription, chatgptBorrow, modelMode, now } = {}) {
  const keys = { openai: openaiApiKey, anthropic: anthropicApiKey };
  for (const [provider, key] of Object.entries(keys)) if (key !== undefined && key !== null && key !== '') requiredString(key, `${provider}_key`);
  if ((claudeSubscription || claudeBorrow || claudeRoutes) && anthropicApiKey) throw new Error('anthropic_credential_ambiguous');
  if (claudeRoutes && claudeBorrow) throw new Error('claude_routes_ambiguous');
  const claudeList = claudeRoutes ? claudeRouteList(claudeRoutes.routes) : null;
  if (claudeList?.some(route => !validLending({ socketPath: route.socketPath, secret: claudeRoutes.secret }))) throw new Error('claude_lending_invalid');
  if (claudeSubscription && !validSubscription(claudeSubscription)) throw new Error('claude_subscription_invalid');
  // The install's own Claude grant, the one it may lend: one custody, with its
  // one refresh queue, whether its own calls use it or go by route. A route
  // that is its own lend socket uses it directly, never through the socket.
  const lendable = claudeSubscription && !claudeBorrow ? subscriptionCustody(claudeSubscription) : null;
  const own = lendable && validLending(claudeLend)
    ? { socketPath: claudeLend.socketPath, custody: lendable, lender: claudeLend.lender ?? DEFAULT_APPLICATION } : undefined;
  const claude = claudeList && claudeRouter(claudeList, { secret: claudeRoutes.secret, own, now });
  if (claudeBorrow && !validLending(claudeBorrow)) throw new Error('claude_lending_invalid');
  if (chatgptSubscription && !validSubscription(chatgptSubscription)) throw new Error('chatgpt_subscription_invalid');
  if (chatgptBorrow && !validLending(chatgptBorrow)) throw new Error('chatgpt_lending_invalid');
  if (chatgptBorrow && chatgptSubscription) throw new Error('chatgpt_credential_ambiguous');
  const credentials = Object.fromEntries(Object.entries(keys).filter(([, key]) => key).map(([id, key]) => [id, { type: 'api_key', key }]));
  const subscriptions = {
    ...(claude ? { anthropic: claude.custody } : claudeBorrow ? { anthropic: borrowedCustody(claudeBorrow) }
      : lendable ? { anthropic: lendable } : {}),
    ...(chatgptSubscription ? { [CHATGPT_PROVIDER]: chatgptCustody(chatgptSubscription) } : {}),
    ...(chatgptBorrow ? { [BORROWED_CHATGPT_PROVIDER]: borrowedChatgptCustody(chatgptBorrow) } : {})
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
  const offer = provider => models.setProvider(currentInstructions(provider));
  if (credentials.openai) offer(openaiProvider());
  if (credentials.anthropic) offer(anthropicProvider());
  if (subscriptions.anthropic) offer(subscriptionProvider());
  if (subscriptions[CHATGPT_PROVIDER]) offer(chatgptProvider());
  if (subscriptions[BORROWED_CHATGPT_PROVIDER]) offer(borrowedChatgptProvider());
  if (apiKeys[API_KEY_PROVIDER]) offer(apiKeyProvider());
  const routes = models.getProviders().flatMap(provider => provider.getModels().map(model => ({ provider: provider.id, modelId: model.id })));
  if (modelMode === 'local') { offer(localProvider()); routes.unshift(LOCAL_ROUTE); }
  else if (modelMode !== undefined && modelMode !== null && modelMode !== '') throw new Error('invalid_model_mode');
  if (!routes.length) throw new Error('provider_credential_missing');
  // `read` is also web search's credential (web-search.mjs): the same key or
  // custody token the provider's chat uses.
  return { models, routes, subscriptions, apiKeys, credential: read, claude, lendable };
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
  if (entry.kind === WaitingEntry.kind) return [];
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
      // Who said a message, as its entry keeps it (MessageEntry), never read from its words.
      ...(MessageEntry.is(entry) && index === 0 ? messageOf(entry.data) : {}),
      // A helper's calls, settled (subagent.mjs), which Rails keeps under its line.
      ...(message.role === 'toolResult' && Array.isArray(message.details?.tools) ?
        { calls: message.details.tools, callCount: message.details.count ?? message.details.tools.length } : {}),
      ...(message.role === 'assistant' && message.usage ? { usage: replyUsage(message.usage) } : {}),
      // When the reply's request began, which is when the provider read its prompt cache, and the
      // model that ran it: Rails tells a cache miss from these (Message#note_cache_miss).
      ...(message.role === 'assistant' && Number.isFinite(message.timestamp) ? { at: message.timestamp } : {}),
      ...(message.role === 'assistant' && message.provider && message.model ? { model: `${message.provider}/${message.model}` } : {}) };
  });
}
const messageOf = data => ({ ...(typeof data?.requestId === 'string' ? { requestId: data.requestId } : {}),
  ...(data?.author ? { author: data.author } : {}) });
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
// Another agent of the same actor a fork goes to: its workspace, as any scope
// names one, and its absolute folder, nothing else.
export function validInto(into) {
  if (into === null || typeof into !== 'object' || Array.isArray(into) || Object.keys(into).some(key => !['workspaceId', 'cwd'].includes(key)))
    throw new ApiError(422, 'invalid_into');
  requiredString(into.workspaceId, 'workspace');
  if (typeof into.cwd !== 'string' || into.cwd.length > 1024 || !isAbsolute(into.cwd) || normalize(into.cwd) !== into.cwd) throw new ApiError(422, 'invalid_into');
  return { workspaceId: into.workspaceId, cwd: into.cwd };
}
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
export const SIDECAR_TOOL_NAMES = Object.freeze(['read', 'write', 'edit', 'bash', 'visit_website', 'desktop', 'browser_upload', 'codemode', 'subagent', 'message_helper', 'web_search', 'tool_search']);
// The sidecar's built-in abilities, which Rails switches on per agent through the
// definition's `capabilities`. No hosted agent runs code of its
// own making: the list is fixed here.
export const CAPABILITIES = Object.freeze(['codemode', 'subagents', 'web_search']);
// Memory one code mode script's VM may allocate.
export const CODEMODE_MEMORY_BYTES = 64 * 1024 * 1024;
const TOOL_NAME = /^[a-z][a-z0-9_]{0,63}$/;
// The most active tools the model sees, including the sidecar's own and tools
// loaded by search. Rails declares fewer to leave room for those loads.
export const TOOL_LIMIT = 64;
// The tools the sidecar adds, by ability and computer, and tool_search beside
// lookup tools. Rails reads the same file (Agent#sidecar_tool_names,
// Agent#lookup_sidecar_tool_names), so both count what the model sees.
export const OWN_TOOLS = Object.freeze(JSON.parse(readFileSync(new URL('./own-tools.json', import.meta.url), 'utf8')));
export const ownToolNames = ({ capabilities = [], computer, lookup }) => [...capabilities.flatMap(name => OWN_TOOLS.capabilities[name] ?? []),
  ...(computer ? [...OWN_TOOLS.computer, ...(computer.provider === 'sprites' ? OWN_TOOLS.sprites : []),
    ...(computer.retainedBrowser ? OWN_TOOLS.retainedBrowser : [])] : []),
  ...(lookup?.length ? OWN_TOOLS.lookup : [])];
// The most lookup tools one definition carries (Agent::LOOKUP_LIMIT): tools
// the model is offered only once tool_search finds them, and a code mode
// script finds with searchTools() and calls as tools.<name> (agentExtension).
export const LOOKUP_LIMIT = 1024;
export function validDefinition(input, routes, reserved = new Set(), offered = {}) {
  const invalid = category => new ApiError(422, category);
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw invalid('invalid_definition');
  const { digest: claimed, ...body } = input;
  const keys = Object.keys(body).filter(key => !['computer', 'namedComputers', 'capabilities', 'lookup', 'claudeRoute', 'helperModels'].includes(key)).sort().join(',');
  if (keys !== 'instructions,model,thinkingLevel,tools') throw invalid('invalid_definition');
  if (typeof claimed !== 'string' || digest(body) !== claimed) throw invalid('definition_digest_mismatch');
  if (typeof body.instructions !== 'string' || body.instructions.length > 65536) throw invalid('invalid_instructions');
  if (!routes.some(route => routeName(route) === body.model)) throw invalid('model_unavailable');
  if (!THINKING_LEVELS.includes(body.thinkingLevel)) throw invalid('invalid_thinking_level');
  // The Claude route its calls go to first (claude-routes.mjs); one this
  // sidecar has not got is no route at all, so the install's order stands.
  if (body.claudeRoute !== undefined && !validRouteName(body.claudeRoute)) throw invalid('invalid_claude_route');
  const computer = validComputer(body.computer);
  if (computer === undefined) throw invalid('invalid_computer');
  if (computer && offered[computer.provider] !== true) throw invalid('computer_unavailable');
  if (body.namedComputers !== undefined && !validNamedComputers(body.namedComputers)) throw invalid('invalid_named_computers');
  if (!Array.isArray(body.tools)) throw invalid('invalid_tools');
  // One set of names for declared and lookup tools alike: a script calls each by its name.
  const names = new Set();
  const check = (tool, category) => {
    // `files`: an argument listing paths on the computer, and their limits (attachments.mjs).
    const files = tool?.files;
    if (files !== undefined && (!files || typeof files !== 'object' || Object.keys(files).sort().join(',') !== 'argument,maxBytes,maxTotalBytes' ||
      typeof files.argument !== 'string' || tool.parameters?.properties?.[files.argument]?.type !== 'array' ||
      !Number.isInteger(files.maxBytes) || files.maxBytes < 1 || !Number.isInteger(files.maxTotalBytes) || files.maxTotalBytes < 1)) throw invalid(category);
    if (!tool || typeof tool !== 'object' || Object.keys(tool).filter(key => key !== 'files').sort().join(',') !== 'description,name,parameters' ||
      typeof tool.name !== 'string' || !TOOL_NAME.test(tool.name) || names.has(tool.name) || reserved.has(tool.name) ||
      typeof tool.description !== 'string' || tool.description.length > 2048 ||
      !tool.parameters || typeof tool.parameters !== 'object' || tool.parameters.type !== 'object') throw invalid(category);
    names.add(tool.name);
  };
  for (const tool of body.tools) check(tool, 'invalid_tools');
  const capabilities = body.capabilities ?? [];
  if (!Array.isArray(capabilities) || new Set(capabilities).size !== capabilities.length ||
    capabilities.some(name => !CAPABILITIES.includes(name))) throw invalid('invalid_capabilities');
  // Absent (a Rails that predates them) means none.
  if (body.lookup !== undefined) {
    if (!Array.isArray(body.lookup)) throw invalid('invalid_lookup');
    for (const tool of body.lookup) check(tool, 'invalid_lookup');
    if (body.lookup.length > LOOKUP_LIMIT) throw new ApiError(422, 'lookup_limit', `${body.lookup.length} lookup tools, and the most is ${LOOKUP_LIMIT}`);
  }
  // Too many, and nothing else wrong: said apart, so Rails can say why.
  const seen = body.tools.length + ownToolNames({ capabilities, computer, lookup: body.lookup }).length;
  if (seen > TOOL_LIMIT) throw new ApiError(422, 'tool_limit', `${seen} tools, and the most is ${TOOL_LIMIT}`);
  // The models a helper may run on, as the agent's settings name them (subagent.mjs chooseModel).
  if (body.helperModels !== undefined && (!Array.isArray(body.helperModels) || body.helperModels.length > 256 ||
    body.helperModels.some(choice => !choice || typeof choice !== 'object' || Object.keys(choice).sort().join(',') !== 'id,label,name' ||
      Object.values(choice).some(value => typeof value !== 'string' || !value.trim() || value.length > 200)))) throw invalid('invalid_helper_models');
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
// A helper's call (subagent.mjs) carries its child's calls in its details,
// with how many it has made; they show under it, named `<helper call>/<child call>`.
export const toolLine = slot => ({ callId: slot.callId, name: slot.name, status: slot.status, output: outputTail(slot.output) });
function liveTools(live) {
  return [...(live?.tools ?? []).filter(slot => slot.status !== 'done'), ...(live?.nestedTools ?? [])].flatMap(slot => [
    { ...toolLine(slot), ...(Number.isInteger(slot.details?.count) ? { count: slot.details.count } : {}) },
    ...(Array.isArray(slot.details?.tools) ? slot.details.tools : []).map(tool => ({ ...tool, callId: `${slot.callId}/${tool.callId}` }))]);
}

// The messages waiting for the agent to take them in (pi.inbox): a steer goes
// in after the step it is on, a follow-up when it would stop. Their words and
// how many pictures; Rails has the rest.
export function queuedView(inbox) {
  return (inbox?.items ?? []).filter(item => item.mode !== 'write').map(item => {
    const blocks = typeof item.content === 'string' ? [{ type: 'text', text: item.content }] : (item.content ?? []);
    return { id: String(item.id), mode: item.mode, text: blocks.filter(block => block.type === 'text').map(block => block.text).join(''),
      pictures: blocks.filter(block => block.type === 'image').length, ...(phoneInput(item.entry) ? { phone: true } : {}) };
  });
}

const userIndexes = items => items.flatMap((item, index) => item.mode === 'write' ? [] : [index]);

// A summary being made, and the newest one that failed, by what started it.
// The error text stays here: it is a provider's words. Only its kind leaves,
// when it is one Rails can explain (summaryFailureReason).
const liveCompaction = live => live?.compactions?.length ? { trigger: live.compactions[0].trigger } : null;
function compactionFailed(live) {
  if (!live?.compactionFailure) return null;
  const reason = summaryFailureReason(live.compactionFailure.error);
  return { trigger: live.compactionFailure.trigger, ...(reason ? { reason } : {}) };
}

// Pushes to Rails while a conversation runs: a frame with the whole live tail
// (Rails replaces, never appends, so a lost or reordered frame cannot corrupt
// the page) and a sync ping when entries commit (Rails pulls them, so a missed
// ping heals at the next). Both are best effort and throttled.
// How often a frame carries the whole live reply rather than what changed:
// how long a page that missed a frame, or opened mid-reply, shows it partly.
const WHOLE_FRAME_MS = 2000;

// Rails answers 404 when it has no such conversation (a helper's, or one it
// deleted); that will not change, so the conversation stops streaming at once.
const gone = error => error?.status === 404;

function railsNotifier(harness, { frame, sync, intervalMs, usage, notes, log = line => console.error(line) }) {
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
      let value = handle.value, timer, lastText, lastThinking, lastBusy, lastTools, lastCompaction, lastQueued, lastEntry = value.entries.at(-1)?.id, stopped = false, seenBusy = false;
      // What Rails last took, so a frame can carry only what follows it; the
      // whole reply goes every WHOLE_FRAME_MS, and after any frame that failed.
      let sent = null, wholeAt = 0;
      const stop = async () => {
        if (stopped) return;
        stopped = true; clearTimeout(timer); watching.delete(id);
        await handle.stop();
        if (again.delete(id)) void watch(id);
      };
      // A watch asked for meanwhile is dropped too: Rails would refuse it the same way.
      const refused = async kind => {
        log(`sidecar: Rails has no conversation ${id} (${kind} answered 404); its live view stops`);
        again.delete(id);
        await stop();
      };
      const flush = async () => {
        timer = undefined;
        if (stopped) return;
        const live = value.docs['pi.live'];
        const text = liveText(live), thinking = liveThinking(live), busy = live?.run !== undefined;
        const tools = busy ? liveTools(live) : [], toolsKey = JSON.stringify(tools);
        // A summary runs beside a run or, asked for, while the conversation is idle.
        const compaction = liveCompaction(live), failed = compactionFailed(live), compactionKey = JSON.stringify([compaction, failed]);
        const queued = queuedView(value.docs['pi.inbox']), queuedKey = JSON.stringify(queued);
        const newest = value.entries.at(-1)?.id;
        if (newest !== lastEntry) {
          lastEntry = newest;
          if (await sync?.(scope).then(() => false, gone)) return refused('sync');
        }
        if (text !== lastText || thinking !== lastThinking || busy !== lastBusy || toolsKey !== lastTools || compactionKey !== lastCompaction || queuedKey !== lastQueued) {
          // The waiting messages go when they change, and with every whole frame.
          const queuedChanged = queuedKey !== lastQueued;
          lastText = text; lastThinking = thinking; lastBusy = busy; lastTools = toolsKey; lastCompaction = compactionKey; lastQueued = queuedKey;
          // No frame follows the last one, so it alone is retried before giving up
          // (the page then corrects its status when it next loads). It carries the
          // conversation's totals, which only settle when the run ends.
          const shape = JSON.stringify([busy, compactionKey]);
          const follows = busy && sent?.shape === shape && Date.now() - wholeAt < WHOLE_FRAME_MS &&
            (text ?? '').startsWith(sent.text) && (thinking ?? '').startsWith(sent.thinking);
          const payload = { ...scope, seq: nextSeq(), busy, tail: text, thinking, tools, failure: busy ? null : failureReason(live?.runFailure),
            ...(queuedChanged || !follows ? { queued } : {}),
            sent: follows ? { tail: Buffer.byteLength(sent.text), thinking: Buffer.byteLength(sent.thinking) } : null,
            compaction, compactionFailed: failed,
            ...(busy ? {} : { usage: usage ? await usage(conversation).catch(() => null) : null,
              notesFile: notes ? await notes(conversation.id).catch(() => null) : null }) };
          for (let attempt = 0; attempt < (busy ? 1 : 4); attempt++) {
            if (attempt) await new Promise(resolve => setTimeout(resolve, intervalMs * 2 ** attempt));
            const outcome = await frame?.(payload).then(() => true, error => gone(error) ? 'gone' : false);
            if (outcome === 'gone') return refused('frame');
            if (outcome) {
              if (!follows) wholeAt = Date.now();
              sent = { shape, text: text ?? '', thinking: thinking ?? '' };
              break;
            }
            sent = null;
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

// Anthropic keeps the prompt cache an hour, not five minutes: a person's
// replies are often minutes apart, and a lapsed cache reads the whole thread
// again. Writing it costs 2x the input price instead of 1.25x; the subscription
// honours it (docs/prompt-cache.md). A call that asks for none (compaction) keeps none.
export const cacheRetention = (model, opts) => opts.cacheRetention ?? (model.api === 'anthropic-messages' ? 'long' : undefined);

// The tools in the order the conversation already has them, new and changed
// ones last. pi-durable re-declares every tool when a change would leave them in
// another order, and Anthropic then drops the thread's earlier thinking and
// caches nothing, so the next two requests read the whole thread again
// (docs/prompt-cache.md). Appended, a change costs only what it adds.
export const stableToolOrder = (before, now) => {
  const kept = before.filter(tool => now.some(next => next.name === tool.name && declarationsEqual(tool, next)));
  return [...kept, ...now.filter(tool => !kept.some(own => own.name === tool.name))];
};

// Durable's compaction is the one caller of completeSimple: the summarizer.
// A summary its model's provider refused is asked once more of the fallback
// route, and the summary that one writes says which model wrote it and why,
// so the record shows it (pi.compaction keeps only the text). Refused there
// too, or with no fallback, the error is marked SUMMARY_REFUSED.
function summaryModels(models, { fallbackFor, modelOf, refusedUsage, refusedEverywhere, summarised }) {
  const completeSimple = async (model, transcript, opts = {}) => {
    const first = await models.completeSimple(model, transcript, opts);
    if (!refusedSummary(first)) {
      if (first.stopReason === 'stop') await summarised(opts.sessionId);
      return first;
    }
    const primary = { provider: model.provider, modelId: model.id };
    const next = fallbackFor(primary);
    let last = first;
    if (next) {
      await refusedUsage(opts.sessionId, first);
      const fallback = modelOf(next);
      const { reasoning, ...rest } = opts;
      const level = reasoning && clampThinkingLevel(fallback, reasoning);
      const answer = await models.completeSimple(fallback, transcript, { ...rest,
        ...(fallback.maxTokens > 0 && opts.maxTokens > fallback.maxTokens ? { maxTokens: fallback.maxTokens } : {}),
        ...(level && level !== 'off' ? { reasoning: level } : {}) });
      if (!refusedSummary(answer)) {
        if (answer.stopReason !== 'stop') return answer;
        await summarised(opts.sessionId);
        const note = `(Summarized by ${routeName(next)}: ${routeName(primary)}'s provider refused to summarize.)`;
        return { ...answer, content: [...answer.content, { type: 'text', text: `\n${note}` }] };
      }
      last = answer;
    }
    await refusedEverywhere(opts.sessionId);
    return { ...last, errorMessage: `${SUMMARY_REFUSED}: ${last.errorMessage ?? last.rawStopReason}` };
  };
  return new Proxy(models, { get: (target, key) => key === 'completeSimple' ? completeSimple : target[key] });
}

// Adds a model request's usage to pi.usage's row for `key`, as Durable does.
function addUsage(rows, key, usage) {
  const add = (total, more) => {
    for (const [name, value] of Object.entries(more ?? {})) {
      if (typeof value === 'number') total[name] = (total[name] ?? 0) + value;
      else if (value && typeof value === 'object') add(total[name] ??= {}, value);
    }
  };
  if (!Object.hasOwn(rows, key)) rows[key] = {};
  add(rows[key], usage);
}

// A hook throw is not a hard stop in Durable. Reserve a persisted request slot
// immediately before dispatch to Models, and reject before the provider sees it.
// A request that sends nothing for idleMs is given up (`request_timeout`); one
// that keeps streaming runs as long as its answer takes.
function guardedModels(models, reserve, routes, idleMs) {
  const dispatch = method => (model, transcript, opts = {}) => {
    const stream = new AssistantMessageEventStream();
    void (async () => {
      const idle = new AbortController();
      let timer;
      const quiet = () => { clearTimeout(timer); timer = setTimeout(() => idle.abort(new Error('request_timeout')), idleMs); };
      try {
        if (!routes.some(route => model.provider === route.provider && model.id === route.modelId)) throw new Error('model_route_denied');
        await reserve(opts.sessionId);
        quiet();
        const signal = opts.signal ? AbortSignal.any([opts.signal, idle.signal]) : idle.signal;
        const source = models[method](model, transcript, { ...opts, signal, maxRetries: 0, cacheRetention: cacheRetention(model, opts) });
        // Once given up, what the request says about its own end is not passed on.
        for await (const event of source) { if (idle.signal.aborted) break; quiet(); stream.push(event); }
        if (idle.signal.aborted) throw idle.signal.reason;
        stream.end(await source.result());
      } catch (error) {
        const reason = idle.signal.aborted ? 'request_timeout' : error.message;
        const message = failure(model, ['model_route_denied', 'request_limit', 'request_timeout', 'scope_missing', 'computers_busy', 'computer_held', PAUSED, CRASH_LOOP].includes(reason) ? reason : 'model_request_failed');
        stream.push({ type: 'error', reason: 'error', error: message });
        stream.end(message);
      } finally { clearTimeout(timer); }
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
  if (limits.bashTimeoutMs > BASH_TIMEOUT_CAP_SECONDS * 1000) throw new Error('invalid_bound_bashTimeoutMs');
  const compaction = compactionSettings(config.compaction);
  const compactAt = config.compactAtTokens ?? COMPACT_AT_TOKENS;
  if (!Number.isInteger(compactAt) || compactAt < 1024) throw new Error('invalid_compact_at');
  if (!isAbsolute(config.storePath ?? '')) throw new Error('absolute_store_required');
  // Injected models (tests) serve exactly the injected route, or routes.
  if (dependencies.models && !dependencies.model) throw new Error('approved_model_unavailable');
  const catalogue = dependencies.models ? { models: dependencies.models, routes: dependencies.routes ?? [dependencies.model], subscriptions: {}, apiKeys: {},
    credential: dependencies.credential ?? (async () => undefined) } : await boot('provider_credential_missing', () => productionModels({ ...config, now: dependencies.now }));
  const { models, routes, subscriptions, apiKeys, credential, claude, lendable } = catalogue;
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
  // The model of a route this sidecar runs, by its name, else undefined.
  const routeModel = name => { const candidate = routes.find(each => routeName(each) === name); return candidate && modelOf(candidate); };
  // Which model a summary its own model's provider refused is asked of (summaryFallback).
  const chosenFallback = config.summaryFallback;
  if (chosenFallback !== undefined && chosenFallback !== false && !routes.some(candidate => routeName(candidate) === chosenFallback)) {
    throw new Error('invalid_summary_fallback');
  }
  const fallbackFor = primary => summaryFallback(primary, routes, modelOf, chosenFallback);
  // The clock of the summary back-off; tests move it.
  const now = dependencies.now ?? Date.now;
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
  // An approved payment's one-time card, fetched for the browser alone (card.mjs).
  const card = dependencies.card ?? config.card;
  const fetchFile = dependencies.fetchFile ?? config.fetchFile;
  const live = dependencies.liveInvocations ?? liveInvocations();
  // A tool's files, read from the computer and handed over before its call (attachments.mjs).
  const uploadFile = dependencies.uploadFile ?? config.uploadFile;
  // A background helper's news: started, what it is doing, how it ended (subagent.mjs).
  const helperReport = dependencies.helper ?? config.helper;
  // Best-effort pushes to Rails; the page heals on load if one is lost.
  const frame = dependencies.frame ?? config.frame;
  const sync = dependencies.sync ?? config.sync;
  const execution = config.execution ?? 'none';
  if (!EXECUTION_MODES.includes(execution)) throw new Error('invalid_execution_mode');
  const shellNetwork = config.shellNetwork ?? 'host';
  if (!SHELL_NETWORK_MODES.includes(shellNetwork)) throw new Error('invalid_execution_mode');
  if (shellNetwork === 'isolated' && !shellIsolationAvailable()) throw new Error('shell_isolation_unavailable');
  // Which computers this sidecar can give an agent; the agent's definition picks one.
  const offered = offeredComputers({ execution, sprites: config.sprites, ssh: config.ssh });
  const sprites = offered.sprites ? spritesComputers({ ...config.sprites, onLog: dependencies.onComputerLog }) : undefined;
  const ssh = offered.ssh ? sshComputers({ ...config.ssh, onLog: dependencies.onComputerLog }) : undefined;
  const boxd = boxdComputer(dependencies.boxdPilot);
  // Command connectors' processes, each on its agent's computer.
  const connectors = commandConnectors(dependencies.connectorTimings);
  const carried = carrier({ storePath: config.storePath, models, context });
  const owner = await boot('storage_unavailable', () => ownStore(config.storePath));
  let harness, storage, codemode;
  const reports = [];
  try {
    const registry = createRegistry();
    const checkPermission = async (scope, computer, conversationId, sandboxConversation) => {
      if (!scope?.actorId || !scope.workspaceId) throw new Error('scope_missing');
      const configured = isConfiguredSsh(computer);
      const permission = await authorize({ actorId: scope.actorId, workspaceId: scope.workspaceId,
        ...(configured || conversationId !== undefined ? { configuredSsh: true } : {}),
        ...(conversationId !== undefined ? { retainedBrowser: true, conversationId: String(conversationId) } : {}),
        ...(sandboxConversation !== undefined ? { sandboxBrowser: true, conversationId: String(sandboxConversation) } : {}) });
      // A paused agent says so: the model reads "Tool call blocked: paused_by_owner", and the run's end is
      // told to Rails under that reason, which it records as idle, not an error (Conversation::Activity).
      if (permission?.paused === true) throw new Error(PAUSED);
      if (permission?.allowed !== true || !scopeMatches(permission, scope) || permission.cwd !== scope.cwd) throw new Error('access_denied');
      // Queued work can still carry an old definition after the agent moves or loses SSH.
      if (configured && !['host', 'user', 'folder', 'keyring'].every(key => permission.configuredSsh?.[key] === computer[key]))
        throw new Error('configured_ssh_unavailable');
      return permission;
    };
    const retainedTarget = async (scope, conversationId, computer) => {
      if (!sprites || scope?.root) throw new Error('retained_browser_unavailable');
      const permission = await checkPermission(scope, computer, conversationId);
      // Rails grants it afresh, only while an SSH computer of either kind keeps the Sprite (Computer#retains_browser?).
      const target = permission.retainedBrowser;
      if (target?.conversationId !== String(conversationId) || !validComputer({ provider: 'sprites', name: target.prefix }))
        throw new Error('retained_browser_unavailable');
      return spriteName(target.prefix, conversationId);
    };
    registry.install(defineExtension({ name: 'omakase.authority', hooks: [hook(GenerationTask, {
      beforeRequest: async ({ messages }, api, ctx) => {
        if (await phoneScope(api, ctx)) return { messages: phoneMessages(messages) };
      }
    }), hook(ToolTask, {
      beforeTool: async (call, api, ctx) => {
        if (await phoneScope(api, ctx) && (call.parent || !phoneRead(call.name))) return { block: 'phone_read_only' };
        const scope = await api.snapshot(App, api.conversationId, ctx);
        await checkPermission(scope, (await definitionOf(api.conversationId, api, ctx))?.computer);
        if (FILE_TOOLS.includes(call.name) && call.arguments?.computer !== undefined) {
          await namedTarget(api, call.arguments.computer, ctx, scope);
        }
      }
    })] }));
    // Conversations whose computer could not wake because too many are
    // awake, or because an operator holds it; their next model request ends
    // the run as `computers_busy` or `computer_held`.
    const busy = new Map();
    // Summaries asked for and still being made, by conversation and request.
    const compacting = new Map();
    // The conversation's own computer. A helper uses the computer of the
    // conversation it works for. A held one is neither woken nor made: its
    // Sprite may be gone while an operator rebuilds it.
    const computerEnv = async (conversationId, computer, scope) => {
      const owner = scope?.root?.conversationId ?? conversationId;
      if (computer.held) { busy.set(conversationId, 'computer_held'); throw new Error('computer_held'); }
      if (computer.provider === 'ssh') {
        if (isConfiguredSsh(computer)) await checkPermission(scope, computer);
        return ssh.env(computer);
      }
      if (computer.provider === 'sprites') {
        try { return await sprites.env(spriteName(computer.name, owner), computer.size); } catch (error) {
          if (/\bcomputers_busy\b/.test(error?.message ?? '')) busy.set(conversationId, 'computers_busy');
          throw error;
        }
      }
      if (!scope?.cwd || !isAbsolute(scope.cwd)) throw new Error('scope_missing');
      return localEnv({ root: scope.cwd, conversationId: owner, shellNetwork, shellTmpDir: config.shellTmpDir,
        isolate: command => ['unshare', '--user', '--map-current-user', '--net', '--', ...(typeof command === 'string' ? ['/bin/bash', '-c', command] : command)] });
    };
    const definitionOf = async (conversationId, read, ctx) => {
      const stored = await read.snapshot(Definitions, ctx);
      return stored?.byDigest[stored.conversations[conversationId]];
    };
    const namedTarget = async (api, alias, ctx, scope) => {
      const definition = await definitionOf(api.conversationId, api, ctx);
      const computer = chooseComputer(null, definition?.namedComputers, alias);
      if (!boxd.admits(computer, scope)) throw new Error('boxd_unavailable');
      return computer;
    };
    const namedEnv = async (api, alias, ctx) => {
      const scope = await api.snapshot(App, api.conversationId, ctx);
      return boxd.env(await namedTarget(api, alias, ctx, scope), scope);
    };
    const phoneForConversation = async (id, ctx) => {
      const live = await harness.snapshot(LiveDoc, id, ctx);
      let conversation;
      return phoneInRun(live, async (...args) => (conversation ??= await harness.conversation(id, ctx)).entries(...args, ctx));
    };
    // Pi builds the usual computer for prompts and legacy tool calls. Only
    // the file and shell tools given an explicit name use the pilot one.
    const conversationEnv = async (conversationId, read) => {
      const computer = (await definitionOf(conversationId, read, context))?.computer;
      if (!computer || offered[computer.provider] !== true) return undefined;
      // Durable builds an env even for a Rails read or in generation's prompt setup.
      if (await phoneForConversation(conversationId, context)) return undefined;
      return computerEnv(conversationId, computer, await read.snapshot(App, conversationId, context));
    };
    const namedCoding = namedCodingTools(namedEnv);
    // The existing Sprite an SSH computer keeps for its screen.
    const retainedName = async (api, ctx) => {
      const computer = (await definitionOf(api.conversationId, api, ctx))?.computer;
      if (!computer?.retainedBrowser || computer.held) throw new Error('retained_browser_unavailable');
      return retainedTarget(await api.snapshot(App, api.conversationId, ctx), api.conversationId, computer);
    };
    // Its screen's scripts (a visit, a fill) run there as `browser`, where its desktop acts, and never make it.
    const retainedScreen = async (api, ctx) => {
      const name = await retainedName(api, ctx).catch(() => undefined);
      return name && { id: `sprites:${name}`, onScreen: (argv, options, context) => screenScript(name, argv, { ...options, existing: true }, context) };
    };
    const retainedExtension = retainedDesktop(retainedName, [retainedVisit(retainedScreen)]);
    const sandbox = sandboxBrowser(async (api, ctx) => {
      const computer = (await definitionOf(api.conversationId, api, ctx))?.computer;
      const scope = await api.snapshot(App, api.conversationId, ctx);
      if (!computer?.sandboxBrowser || computer.provider !== 'ssh' || computer.held || scope?.root) return null;
      const { sandboxBrowser: target } = await checkPermission(scope, computer, undefined, api.conversationId);
      if (target?.conversationId !== String(api.conversationId) ||
          !['host', 'user', 'folder', 'keyring'].every(key => target.ssh?.[key] === computer[key])) return null;
      return { name: target.name, env: api.env };
    }, { root: dependencies.sandboxBrowserRoot });
    const computerExtensions = [];
    if (offered.local || offered.sprites || offered.ssh) {
      const images = await createNodePhotonImages({ worker: false });
      computerExtensions.push(createCodingTools({ images }), bashLimit({ defaultSeconds: limits.bashTimeoutMs / 1000 }), readGuard,
        browserExtension, desktopExtension, retainedExtension, sandbox.extension, namedCoding);
      for (const extension of computerExtensions) registry.install(extension);
    }
    registry.install(infraExtension());
    registry.install(wholeResults({ envOf: (api, ctx, call) =>
      FILE_TOOLS.includes(call.name) && call.arguments?.computer !== undefined
        ? namedEnv(api, call.arguments.computer, ctx) : conversationEnv(api.conversationId, api) }));
    // Masking is a backstop, not a permission: agents still never print secrets.
    registry.install(secretMask({ appUrl: config.appUrl, log: dependencies.log }));
    // What piled up while the agent worked goes in together, saying so (batches.mjs).
    registry.install(batchesExtension());
    // After a summary every model tried refused, no summary starts on its own
    // for limits.summaryBackoffMs; a person's /compact, and one the model's
    // window forces (overflow), still do. A declined one leaves the request as
    // it was, which still fits the window: the threshold sits well below it.
    registry.install(defineExtension({ name: 'omakase.summary-backoff', hooks: [hook(CompactionTask, {
      beforeCompact: async (compaction, api, ctx) => {
        if (compaction.reason !== 'threshold') return undefined;
        const until = (await api.snapshot(App, api.conversationId, ctx))?.summaryRefusedUntil;
        return Number.isInteger(until) && now() < until ? { kind: 'decline' } : undefined;
      }
    })] }));
    // Code mode: the model may write one JavaScript script that calls the
    // conversation's tools (Rails' and the computer's) with loops and
    // Promise.all, in a QuickJS sandbox with no file system or network of its
    // own. Every call it makes is an ordinary tool call, so Rails' ledger and
    // approvals apply as usual. No model helpers: the sidecar runs one model.
    codemode = new CodemodeSandbox({ memoryLimitBytes: CODEMODE_MEMORY_BYTES });
    // One extension per capability; a conversation gets those its agent names.
    const capabilityExtensions = { codemode: createCodemodeExtension({ sandbox: codemode, models: false }),
      subagents: subagentExtension({ toolLine, report: helperReport, retryMs: limits.helperRetryMs, reportForMs: limits.helperReportForMs, now, modelOf: routeModel }),
      web_search: webSearchExtension({ credential, reserve: id => reserveRequest(id), timeoutMs: limits.requestIdleMs, fetch: dependencies.fetch }) };
    for (const extension of Object.values(capabilityExtensions)) registry.install(extension);
    for (const extension of dependencies.extensions ?? []) registry.install(extension);
    // Everything but agent definitions, computers and capabilities: what every
    // conversation in a scope gets.
    const isAgentExtension = extension => extension.name.startsWith('bot.');
    const forComputer = extension => computerExtensions.some(own => own.name === extension.name);
    const isCapability = extension => Object.values(capabilityExtensions).some(own => own.name === extension.name);
    const infraFor = () => registry.snapshot().installed().filter(extension => !isAgentExtension(extension) && !forComputer(extension) && !isCapability(extension));
    // A retained or sandbox browser replaces the SSH headless visit, never adds a second route.
    const computerFor = ({ computer, namedComputers }) => !computer ? [] :
      computerExtensions.filter(extension => (extension !== desktopExtension || computer.provider === 'sprites') &&
        (extension !== retainedExtension || (sprites && computer.retainedBrowser)) &&
        (extension !== sandbox.extension || computer.sandboxBrowser) &&
        (extension !== browserExtension || !(computer.retainedBrowser || computer.sandboxBrowser)) &&
        (extension !== namedCoding || (boxd.configured && namedComputers !== undefined)));
    const capabilitiesFor = definition => (definition.capabilities ?? []).map(name => capabilityExtensions[name]).filter(Boolean);
    // An agent's tool may not take the name of one of the sidecar's, installed here or not.
    const reservedToolNames = () => new Set([...SIDECAR_TOOL_NAMES,
      ...registry.snapshot().installed().filter(e => !isAgentExtension(e)).flatMap(e => (e.tools ?? []).map(t => t.name))]);
    const installDefinition = definition => {
      const name = `bot.${definition.digest}`;
      if (!registry.snapshot().extension(name)) registry.install(agentExtension(definition, { ...limits, toolLimit: TOOL_LIMIT - ownToolNames(definition).length,
        invoke, signIn, card, fetchFile, uploadFile, live, retainedScreen, phoneForConversation }));
      return registry.snapshot().extension(name);
    };
    // The newest tool round: the entries after the newest assistant answer.
    const crashLoopedRound = async id => crashLoopAfter(await harness.conversation(id, context), entry => entry.kind === 'pi.assistant');
    // One request of a run's bound, for a model request or a web search; the
    // time the run has left.
    async function reserveRequest(id) {
      await checkPermission(await harness.snapshot(App, id, context));
      const stopped = busy.get(id);
      if (stopped) { busy.delete(id); throw new Error(stopped); }
      // Since 1.5.0 a tool the restart limit cut off gets an error result and the
      // run would go on. Like the 1.4 park, stop instead: no further request
      // after crash-loop protection fired in the newest tool round.
      if (await crashLoopedRound(id)) throw new Error(CRASH_LOOP);
      return harness.commit(async tx => {
        // A helper's requests count against the run of the conversation it works
        // for; a background helper's, which outlives that run, against its own.
        const own = await tx.doc(App, id);
        const app = own.root && !own.root.background ? await tx.doc(App, own.root.conversationId) : own;
        if (!app.actorId || !app.workspaceId) throw new Error('scope_missing');
        if (app.bounds.requests >= limits.maxRequests) throw new Error('request_limit');
        app.bounds.requests++;
      }, context);
    }
    // The Claude route its agent named, if any (Agent#claude_route); a
    // helper's calls go by the conversation it works for.
    const claudeRouteOf = async sessionId => {
      const id = sessionId && (await harness.snapshot(Admission, context))?.sessions[sessionId];
      if (!id) return undefined;
      const owner = (await harness.snapshot(App, id, context))?.root?.conversationId ?? id;
      const stored = await harness.snapshot(Definitions, context);
      return stored?.byDigest[stored.conversations[owner]]?.claudeRoute;
    };
    const safeModels = guardedModels(claude ? claude.wrap(models, claudeRouteOf) : models, async sessionId => {
      if (!sessionId) throw new Error('scope_missing');
      const id = (await harness.snapshot(Admission, context))?.sessions[sessionId];
      if (!id) throw new Error('scope_missing');
      return reserveRequest(id);
    }, routes, limits.requestIdleMs);
    // The conversation a model request is for, as reserveRequest finds it.
    const sessionConversation = async sessionId => sessionId && (await harness.snapshot(Admission, context))?.sessions[sessionId];
    const summarising = summaryModels(safeModels, { fallbackFor, modelOf,
      // The refused request was made and may be billed: counted under its model, as Durable counts the summary it keeps.
      refusedUsage: async (sessionId, message) => {
        const id = await sessionConversation(sessionId);
        if (id) await harness.commit(async tx => addUsage((await tx.doc(UsageDoc, id)).models, `${message.provider}/${message.model}`, message.usage), context);
      },
      refusedEverywhere: async sessionId => {
        const id = await sessionConversation(sessionId);
        if (id) await harness.commit(async tx => { (await tx.doc(App, id)).summaryRefusedUntil = now() + limits.summaryBackoffMs; }, context);
      },
      summarised: async sessionId => {
        const id = await sessionConversation(sessionId);
        if (id && (await harness.snapshot(App, id, context))?.summaryRefusedUntil !== undefined) {
          await harness.commit(async tx => { delete (await tx.doc(App, id)).summaryRefusedUntil; }, context);
        }
      } });
    // A store that cannot be created is a storage problem; a retained store that
    // exists but cannot be opened or recovered needs restore or repair.
    const retained = await fileExists(owner.storePath).then(() => true, () => false);
    storage = await boot(retained ? 'store_recovery_failed' : 'storage_unavailable', () => openNodeSqliteStorage(owner.storePath));
    harness = await boot('store_recovery_failed', () => Harness.open(storage, { models: summarising, registry,
      // Retries are Durable's generation attempts: each goes through the Models
      // seam and reserves a request slot. SDK retries inside one attempt stay off,
      // so no request bypasses that bound.
      settings: { retry: { enabled: limits.maxRetries > 0, maxRetries: limits.maxRetries, baseDelayMs: limits.retryBaseDelayMs,
        maxAgentDelayMs: 30000 }, compaction: { ...compaction, modelOverrides }, afterFailedRun: 'keep', progress: { persistWithinMs: limits.persistWithinMs },
        stream: { maxRetries: 0 }, restartLimit: limits.restartLimit, toolExecution: TOOL_EXECUTION,
        // Every waiting message at once, as one batch (batches.mjs), not one a step.
        steeringMode: 'all', followUpMode: 'all' },
      env: ({ conversationId, read }) => conversationEnv(conversationId, read),
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
    const notifier = railsNotifier(harness, { frame, sync, intervalMs: limits.frameIntervalMs, usage: conversationUsage, notes: notesView,
      log: dependencies.log });
    harness.resume();
    // Only conversations Rails made stream, as when it submits: a helper's own
    // (owned by its task) has no row there, so its frames would only be refused.
    for (const record of records.items) if (!record.owner && (await harness.snapshot(LiveDoc, record.id, context))?.run) void notifier.watch(record.id);
    async function access(id, scope) {
      requiredString(scope.actorId, 'actor'); requiredString(scope.workspaceId, 'workspace');
      const app = await harness.snapshot(App, Number(id), context);
      if (!scopeMatches(app, scope)) throw new ApiError(404, 'not_found');
      // Rails sent this command with its token, so it is not asked again here;
      // access is checked before every tool call and model request instead.
      return { app, conversation: await harness.conversation(Number(id), context) };
    }
    // A background helper's task, by the call that started it; 404 when none.
    async function helperTask(conversation, callId) {
      requiredString(callId, 'call');
      const page = await harness.commit(tx => tx.scanTasks({ conversationId: conversation.id, kind: HELPER_TASK, order: 'descending' }, 1000), context);
      const task = page.items.find(record => record.input?.callId === callId);
      if (!task) throw new ApiError(404, 'not_found');
      return task;
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
    // Background helpers are left out unless asked for: the agent's Stop leaves
    // them running, and they never keep it busy. Each is cancelled on its own
    // (cancelHelper); a person's answer still reaches one (wake).
    async function ownedTree(root, { helpers = false } = {}) {
      const nodes = Object.values((await liveTaskGraph(harness)).tasks).filter(node => helpers || node.kind !== HELPER_TASK);
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
    // Conversation.abort() leaves background subtrees running: a helper's, as
    // meant, and a background summary's, which is among the recorded tasks
    // marked and joined explicitly here.
    async function settleCancellation(record) {
      for (const submission of record.submissions) await harness.abortSubmission(submission.id ?? submission, context, submission.conversationId);
      // A retry only re-settles the recorded tasks; aborting the conversation again
      // would cancel work admitted after the original cancellation.
      if (!record.retry) for (const id of record.conversations ?? []) {
        const owned = await harness.conversation(id, context);
        if (owned) await owned.abort(context);
      }
      for (const id of record.tasks) await harness.abortTask(id, context);
      for (const id of record.tasks) await harness.waitForTask(id, context);
    }
    // Pending human input of a conversation and the live conversations its tasks
    // own (workflow children), so a child's question or approval reaches the
    // same Rails page as the parent's.
    async function pendingRequests(id, options) {
      const tree = await ownedTree(id, options);
      const rows = [];
      for (const owned of tree.conversations) {
        const app = await harness.snapshot(App, owned, context);
        for (const request of Object.values(app?.requests ?? {})) rows.push({ request, conversationId: owned });
      }
      return rows;
    }
    // Whether a tool call's task has ended: a wait it holds will never be heard.
    async function callEnded(taskId) {
      const task = await harness.getTask(taskId, context);
      return !task || task.state.status === 'terminal';
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
      const before = (await conversation.agent(context))?.tools ?? [];
      await conversation.configure({ model: { provider, modelId }, thinkingLevel, instructions, modelTools: null,
        extensions: [...infraFor(), extension, ...capabilitiesFor(definition), ...computerFor(definition)] }, context);
      // A deferred tool the model loaded (tool_search) is not among the new
      // definition's tools, yet the model was offered it: it stays loaded.
      const { tools, deferred } = await conversation.agent(context);
      const loaded = deferred.filter(tool => before.some(old => old.name === tool.name));
      await conversation.configure({ modelTools: stableToolOrder(before, [...tools, ...loaded]) }, context);
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
    // The person's own message (Rails sends fromPerson) is marked so on its
    // waiting item, and a steer of his goes after his last waiting steer, or
    // to the front: ahead of everyone else's, his own order kept. Marked and
    // moved in one commit, so the same request again moves nothing.
    // Follow-ups keep their place.
    async function placeOwn(conversation, submissionId) {
      await harness.commit(async tx => {
        const { items } = await tx.doc(InboxDoc, conversation.id);
        const at = items.findIndex(item => item.id === submissionId);
        if (at < 0 || items[at].fromPerson || phoneInput(items[at].entry)) return;
        items[at].fromPerson = true;
        if (items[at].mode !== 'steer') return;
        const users = userIndexes(items).filter(index => index !== at);
        const own = users.findLast(index => items[index].fromPerson && items[index].mode === 'steer');
        const to = own === undefined ? users[0] : own + 1;
        if (to < at) items.splice(to, 0, ...items.splice(at, 1));
      }, context);
    }
    // Someone else's message that waits for the turn to end is announced at
    // the agent's next step (waiting.mjs): a write, placed at the next
    // boundary and kept, so the cached prefix holds. Under its own request
    // id, so the same request again announces nothing more.
    async function announceWaiting(conversation, requestId, content, author) {
      const { items } = await harness.snapshot(InboxDoc, conversation.id, context);
      const count = items.filter(item => item.mode === 'followUp' && !item.fromPerson && !phoneInput(item.entry)).length;
      if (count === 0) return;
      await conversation.submit({ type: 'write', requestId: `${requestId}:waiting`, entry: { kind: WaitingEntry.kind,
        model: [{ role: 'user', content: waitingNote(content, author, count), timestamp: now() }] } }, context);
    }
    async function runDefinition(conversation, input, phone) {
      const definition = validDefinition(input.definition, routes, reservedToolNames(), offered);
      const extension = installDefinition(definition);
      const current = await harness.snapshot(Definitions, context);
      const same = current?.conversations[conversation.id] === definition.digest;
      const starting = !(await harness.snapshot(LiveDoc, conversation.id, context))?.run;
      if (same && (!starting || phone)) return;
      const stored = current?.notes?.[conversation.id];
      let notes;
      try { notes = phone ? null : await notesFor(conversation, definition); } catch {
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
      // The install's own Claude grant, which it lends (server.mjs), if it has one.
      lendable,
      // The pasted API key's custody, by provider, for the same console.
      apiKeys,
      // The models this sidecar can run now, for Rails' agent settings.
      // An SSH computer's key and the hosts it trusts (ssh-computers.mjs), for
      // the agent's Computer page. Not about one conversation: both belong to
      // the computer's keyring, named by Rails.
      async sshKey(keyring) {
        if (!ssh) throw new ApiError(422, 'computer_unavailable');
        try { return { publicKey: await ssh.publicKey(keyring) }; } catch (error) {
          if (error?.message === 'invalid_computer') throw new ApiError(422, 'invalid_computer');
          throw error;
        }
      },
      async sshHost(where) {
        if (!ssh) throw new ApiError(422, 'computer_unavailable');
        try { return await ssh.hostKey(where); } catch (error) {
          throw error?.message === 'invalid_computer' ? new ApiError(422, 'invalid_computer') : new ApiError(502, 'host_unreachable');
        }
      },
      async trustSshHost(where, fingerprints) {
        if (!ssh) throw new ApiError(422, 'computer_unavailable');
        try { return await ssh.trust(where, fingerprints); } catch (error) {
          if (error?.message === 'invalid_computer') throw new ApiError(422, 'invalid_computer');
          throw error?.message === 'host_key_changed' ? new ApiError(409, 'host_key_changed') : new ApiError(502, 'host_unreachable');
        }
      },
      catalogue: () => ({ models: routes.map(candidate => modelView(modelOf(candidate), compactAtFor(candidate))) }),
      // Durable's compaction policy as this harness runs it, overrides included.
      compaction: Object.freeze({ ...compaction, modelOverrides, compactAt }),
      // With `carry` ({ store, conversationId }), the thread another install
      // ran, moved in with its workspace, starts with what its model saw there
      // (carry.mjs); `carried` is that entry, which Rails already shows.
      async create(scope) {
        requiredString(scope.requestId, 'request'); requiredString(scope.actorId, 'actor'); requiredString(scope.workspaceId, 'workspace');
        const carry = carried.valid(scope.carry);
        const permission = await authorize({ actorId: scope.actorId, workspaceId: scope.workspaceId });
        if (permission?.allowed !== true || !scopeMatches(permission, scope) || !isAbsolute(permission.cwd ?? '')) throw new ApiError(403, 'access_denied');
        const key = digest([scope.actorId, scope.workspaceId, scope.requestId]);
        const payload = digest({ actorId: scope.actorId, workspaceId: scope.workspaceId, cwd: permission.cwd, ...(carry ? { carry } : {}) });
        const known = (await harness.snapshot(Admission, context))?.conversations[key];
        const history = carry && !known ? await carried.messages(carry) : undefined;
        const made = await harness.commit(async tx => {
          const admissions = await tx.doc(Admission);
          const prior = admissions.conversations[key];
          if (prior) { if (prior.digest !== payload) throw new ApiError(409, 'request_conflict'); return { id: prior.id, carried: prior.carried }; }
          if (carry && !history) throw new ApiError(409, 'request_conflict');
          const created = await tx.createConversation({ ownership: { kind: 'ownerless' } });
          const app = await tx.doc(App, created.id);
          app.actorId = scope.actorId; app.workspaceId = scope.workspaceId; app.cwd = permission.cwd;
          const entry = history && await tx.appendEntry(created.id, { kind: CARRIED, model: history, data: { conversationId: carry.conversationId } });
          admissions.conversations[key] = { id: created.id, digest: payload, ...(entry ? { carried: entry.id } : {}) };
          return { id: created.id, carried: entry?.id };
        }, context);
        const conversation = await harness.conversation(made.id, context);
        // Scope came from the Rails callback, never a browser-supplied cwd.
        await conversation.configure({ model: route, thinkingLevel: clampThinkingLevel(modelOf(route), 'medium'), cwd: permission.cwd, extensions: infraFor() }, context);
        return { id: made.id, ...(made.carried ? { carried: made.carried } : {}) };
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
      //
      // With `into` ({ workspaceId, cwd }), the fork is another agent's thread
      // ("New agent from here"): the same actor, that agent's workspace and
      // folder, which Rails minted with its token as it mints every scope. The
      // parent's definition is not copied: Rails sends the new agent's with its
      // first message. The target is part of the payload, so a repeat answers
      // the same fork and the same request id for another target conflicts.
      async fork(id, input) {
        const { app, conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        const into = input.into === undefined ? undefined : validInto(input.into);
        if (!Number.isSafeInteger(input.at) || input.at < 0) throw new ApiError(422, 'invalid_entry');
        const found = await conversation.entries({ order: 'ascending', minEntryId: input.at, maxEntryId: input.at }, 1, undefined, context);
        if (found.items[0]?.id !== input.at) throw new ApiError(422, 'invalid_entry');
        const key = digest(['fork', input.actorId, input.workspaceId, input.requestId]);
        const payload = digest(into ? { parent: conversation.id, at: input.at, into } : { parent: conversation.id, at: input.at });
        const forked = await harness.commit(async tx => {
          const admissions = await tx.doc(Admission);
          const prior = admissions.conversations[key];
          if (prior) { if (prior.digest !== payload) throw new ApiError(409, 'request_conflict'); return prior.id; }
          const record = await tx.forkConversation(conversation.id, input.at, { ownership: { kind: 'ownerless' } });
          const scope = await tx.doc(App, record.id);
          scope.actorId = app.actorId; scope.workspaceId = into?.workspaceId ?? app.workspaceId; scope.cwd = into?.cwd ?? app.cwd;
          const stored = await tx.doc(Definitions);
          if (!into && stored.conversations[conversation.id]) stored.conversations[record.id] = stored.conversations[conversation.id];
          admissions.conversations[key] = { id: record.id, digest: payload };
          return record.id;
        }, context);
        // Until the new agent's first message, the copy runs as a new
        // conversation does, in its own folder, with none of the parent's agent.
        if (into) {
          await (await harness.conversation(forked, context)).configure({ model: route, thinkingLevel: clampThinkingLevel(modelOf(route), 'medium'),
            instructions: null, cwd: into.cwd, extensions: infraFor() }, context);
          return { id: forked };
        }
        // The fork keeps the agent its parent had at `at`; the definition copied
        // above is the parent's now. Configure to match, so an agent edited since
        // that entry is not skipped as current on the fork's first message.
        // Repeats configure again, which changes nothing.
        const stored = await harness.snapshot(Definitions, context);
        const definition = stored?.byDigest[stored.conversations[forked]];
        if (definition) await configureAs(await harness.conversation(forked, context), definition);
        return { id: forked };
      },
      async submit(id, input, phone = false) {
        const { conversation } = await access(id, input);
        if (phone && (!['followUp', 'reject'].includes(input.whenBusy) || input.fromPerson === true))
          throw new ApiError(422, 'invalid_phone_submission');
        requiredString(input.requestId, 'request');
        const images = validContent(input.content);
        if (input.whenBusy !== undefined && !['steer', 'followUp', 'reject'].includes(input.whenBusy)) throw new ApiError(422, 'invalid_busy_mode');
        if (input.definition !== undefined) await runDefinition(conversation, input, phone);
        // Refused before admission: a model without image input would fail the run, or worse, answer as if it had looked.
        if (images && !(await seesImages(conversation))) throw new ApiError(422, 'images_unsupported');
        const author = validAuthor(input.author);
        const draft = { type: 'input', requestId: input.requestId, content: input.content, ...(input.whenBusy ? { whenBusy: input.whenBusy } : {}) };
        // Keep old request digests; only the private phone route supplies this marker.
        const origin = { ...(author ? { author } : {}), ...(phone ? { phone: true } : {}) };
        const payload = digest({ ...draft, ...origin });
        await conversation.commit(async tx => {
          const app = await tx.doc(App, conversation.id);
          const key = digest(input.requestId);
          if (app.admissions[key] && app.admissions[key] !== payload) throw new ApiError(409, 'request_conflict');
          app.admissions[key] = payload;
          // The request bound counts from the newest message: a steer or a
          // follow-up gives the turn it joins a fresh budget, so only an agent
          // that runs on with nobody writing to it meets the bound.
          app.bounds = { requests: 0 };
        }, context);
        const submission = await conversation.submit({ ...draft,
          entry: { kind: MessageEntry.kind, data: { requestId: input.requestId, ...origin } } }, context).catch(error => {
          if (phone && error instanceof ConversationBusy) throw new ApiError(409, 'conversation_busy');
          throw error;
        });
        if (!phone && input.fromPerson === true) await placeOwn(conversation, submission.id);
        const status = await submission.status(context);
        // Even quoting a queued phone message would let it influence the run before the boundary.
        if (!phone && status.status === 'queued' && input.whenBusy !== 'steer' && input.fromPerson !== true)
          await announceWaiting(conversation, input.requestId, input.content, author);
        void notifier.watch(conversation.id);
        return { id: submission.id, ...status };
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
      // A ring for a wait whose call has ended is one nobody hears: the call
      // left it (as calls did before they ended their waits, extensions.mjs
      // endWaits), and the ring settles it rather than leave the conversation
      // "waiting" until it expires (Conversation::AnsweredWaits rings these).
      async wake(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.key, 'key');
        const rows = (await pendingRequests(conversation.id, { helpers: true })).filter(row => row.request.key === input.key);
        const held = rows.find(row => row.request.status === 'pending');
        const owner = (held ?? rows[0])?.conversationId ?? conversation.id;
        const ended = held?.request.taskId !== undefined && await callEnded(held.request.taskId);
        return harness.commit(async tx => {
          const app = await tx.doc(App, owner);
          const request = Object.values(app.requests).find(r => r.key === input.key && r.status === 'pending');
          if (request && ended) request.status = 'settled';
          else if (request) request.rings++;
          else if (!app.requests[`person:${input.key}`]) app.requests[`person:${input.key}`] = { id: `person:${input.key}`, kind: 'person', key: input.key,
            actorId: app.actorId, workspaceId: app.workspaceId, status: 'pending', rings: 1, early: true, expiresAt: Date.now() + limits.humanTimeoutMs };
          return { rung: true };
        }, context);
      },
      async phoneReply(id, scope, submissionId) {
        const { conversation } = await access(id, scope);
        const number = Number(submissionId);
        if (!Number.isSafeInteger(number) || number < 1) throw new ApiError(404, 'not_found');
        const record = await (await harness.submission(number, context))?.status(context);
        if (record?.conversationId !== conversation.id || record.type !== 'input' || !Number.isSafeInteger(record.entry))
          throw new ApiError(404, 'not_found');
        const entry = async entryId => (await conversation.entries({ minEntryId: entryId, maxEntryId: entryId }, 1, undefined, context)).items[0];
        if (!phoneInput(await entry(record.entry))) throw new ApiError(404, 'not_found');
        if (record.status !== 'done') return { status: record.status };
        const final = Number.isSafeInteger(record.answer) ? await entry(record.answer) : undefined;
        const answer = final && entryView(final).find(message => message.role === 'assistant' && !message.toolCalls);
        return { status: record.status, answer: answer?.content.slice(0, 2_000) ?? '' };
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
      async screen(id, scope, prefix, size) {
        // Rails supplies no prefix for a retained screen; it must be resolved afresh.
        if (prefix == null) {
          const { app } = await access(id, scope);
          try {
            const name = await retainedTarget(app, Number(id));
            return await sprites.screen(name, undefined, { existing: true });
          } catch { throw new ApiError(404, 'computer_unavailable'); }
        }
        const name = await screenSprite(id, scope, prefix);
        try { return await sprites.screen(name, size); } catch (error) {
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
        if (computer.held) throw new ApiError(503, 'computer_held');
        const spec = input.entry && typeof input.entry === 'object' ? validSpec(input.entry) : undefined;
        if (!spec) throw new ApiError(422, 'invalid_connector');
        const message = input.message;
        if (!message || message.jsonrpc !== '2.0' || typeof message.method !== 'string' || !['string', 'number'].includes(typeof message.id))
          throw new ApiError(422, 'invalid_message');
        const start = async () => {
          // The agent's own connection, checked as its shell's is (computerEnv).
          if (computer.provider === 'ssh') {
            let env;
            try { env = await computerEnv(Number(id), computer, app); } catch { throw new ApiError(503, 'computer_unavailable'); }
            return sshCommand(env, spec);
          }
          if (computer.provider !== 'sprites') {
            if (!isAbsolute(app.cwd ?? '')) throw new ApiError(422, 'computer_unavailable');
            return localCommand(spec, join(app.cwd, String(id)));
          }
          try { return await sprites.command(spriteName(computer.name, Number(id)), spec, computer.size); } catch (error) {
            throw /\bcomputers_busy\b/.test(error?.message ?? '') ? new ApiError(429, 'computers_busy') : new ApiError(503, 'computer_unavailable');
          }
        };
        // Part of the entry's digest, so moving the agent to another machine or folder starts it afresh.
        const where = computer.provider === 'sprites' ? computer.name
          : computer.provider === 'ssh' ? `${computer.keyring}:${computer.user}@${computer.host}:${computer.folder}` : 'local';
        return { message: await connectors.message(`${id}:${name}`, { ...spec, where }, message, () => start()) };
      },
      // Files Rails holds on a ledger row of its own, not a tool call's: an
      // email's attachments (Rails' ReceivedMail::Files). Saved on the
      // conversation's computer, which Rails names as in a definition, as a
      // connector's files are (files.mjs saveHeld): each fetched back from
      // Rails by its place. Any computer this sidecar offers takes files; a held
      // one is neither woken nor made. What was said of each file, in order.
      async saveFiles(id, input) {
        const { app } = await access(id, input);
        if (input.forge !== undefined) {
          const call = forgeFileRequest(id, input);
          const proof = live.get(call);
          if (app.root || !proof || !config.forgeFiles) throw new ApiError(403, 'forge_call_not_live');
          return transferForgeFile(config.forgeFiles, call, proof);
        }
        const computer = validComputer(input.computer);
        if (!computer) throw new ApiError(422, 'invalid_computer');
        if (computer.held) throw new ApiError(503, 'computer_held');
        const { taskId, callId, files } = input;
        const named = value => typeof value === 'string' && value.length > 0 && value.length <= 512;
        if (!named(taskId) || !named(callId) || !Array.isArray(files) || files.length === 0 || files.length > 1000 ||
          !files.every(file => file && typeof file.name === 'string' && typeof file.type === 'string' && Number.isInteger(file.size) && Number.isInteger(file.held)))
          throw new ApiError(422, 'invalid_files');
        const listed = files.map(({ name, type, size, held }) => ({ name, type, size, held }));
        let env;
        if (computer.provider === 'sprites' && sprites) {
          try { env = await sprites.env(spriteName(computer.name, app.root?.conversationId ?? Number(id)), computer.size); } catch (error) {
            throw /\bcomputers_busy\b/.test(error?.message ?? '') ? new ApiError(429, 'computers_busy') : new ApiError(503, 'computer_unavailable');
          }
        } else if (offered[computer.provider] === true) {
          try { env = await computerEnv(Number(id), computer, app); } catch { throw new ApiError(503, 'computer_unavailable'); }
        }
        const call = { actorId: input.actorId, workspaceId: input.workspaceId, conversationId: String(id), taskId, callId };
        return { files: await saveHeld(fetchFile, call, listed, env, context) };
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
      // A waiting message made a steer, or a follow-up, before the agent takes
      // it in; it keeps its place in the queue, or with `first` goes to its
      // front (Send now). One already taken in is left alone:
      // `{ changed: false }`. Durable's inbox is written directly, in one
      // commit with the check, as its boundaries read it: they take user items
      // in the order of `items`. The item keeps its id, so it is placed once;
      // the parity test holds that a switched message is taken in as switched.
      async changeQueued(id, input) {
        const { conversation } = await access(id, input);
        if (!['steer', 'followUp'].includes(input.whenBusy)) throw new ApiError(422, 'invalid_busy_mode');
        return harness.commit(async tx => {
          const { items } = await tx.doc(InboxDoc, conversation.id);
          const users = userIndexes(items), at = users.find(index => String(items[index].id) === String(input.id));
          if (at === undefined) return { changed: false };
          if (input.whenBusy === 'steer' && phoneInput(items[at].entry))
            return { changed: false };
          items[at].mode = input.whenBusy;
          if (input.first === true) items.splice(users[0], 0, ...items.splice(at, 1));
          return { changed: true };
        }, context);
      },
      // A waiting message moved one place up or down among the others (writes
      // are not the person's and keep theirs), in one commit. At either end it
      // stays; one already taken in is `{ moved: false }`.
      async moveQueued(id, input) {
        const { conversation } = await access(id, input);
        if (!['up', 'down'].includes(input.to)) throw new ApiError(422, 'invalid_position');
        return harness.commit(async tx => {
          const { items } = await tx.doc(InboxDoc, conversation.id);
          const users = userIndexes(items), at = users.findIndex(index => String(items[index].id) === String(input.id));
          if (at < 0) return { moved: false };
          const [from, to] = [users[at], users[at + (input.to === 'up' ? -1 : 1)]];
          if (to !== undefined) [items[from], items[to]] = [items[to], items[from]];
          return { moved: true };
        }, context);
      },
      // A waiting message taken back; one already taken in stays, `{ withdrawn: false }`.
      async withdrawQueued(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.id, 'submission');
        const result = await harness.abortSubmission(Number(input.id), context, conversation.id);
        return { withdrawn: result === 'aborted' };
      },
      async cancel(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.requestId, 'request');
        const key = digest(input.requestId);
        const tree = await ownedTree(conversation.id);
        const preserveQueue = input.preserveQueue === true;
        const current = preserveQueue ? undefined : await harness.inspect(context);
        // The record is the authority for restart: only work live at admission is
        // cancelled again, so a retried request never cancels newer work.
        const cancellation = await harness.commit(async tx => {
          const app = await tx.doc(App, conversation.id);
          if (app.cancellations[key]) return { ...JSON.parse(JSON.stringify(app.cancellations[key])), retry: true };
          // Conversation.abort() is a bulk operation: it withdraws even inputs
          // not listed here. The person's Stop only marks the captured tasks.
          const record = { tasks: tree.tasks, submissions: [] };
          if (current) {
            record.conversations = tree.conversations;
            record.submissions = current.submissions.filter(s => tree.conversations.includes(s.conversationId) && s.status === 'queued')
              .map(s => ({ id: s.id, conversationId: s.conversationId }));
          }
          app.cancellations[key] = record;
          for (const owned of tree.conversations) {
            const doc = owned === conversation.id ? app : await tx.doc(App, owned);
            for (const request of Object.values(doc.requests)) {
              if (request.status === 'pending' && (!preserveQueue || tree.tasks.includes(request.taskId))) request.status = 'cancelled';
            }
          }
          return record;
        }, context);
        await settleCancellation(cancellation);
        return { cancelled: true };
      },
      // A background helper Rails starts for a step of a workflow, named by a
      // call of Rails' own (no slash: its calls are `<call>/<its call>`), with
      // the task and what the step before it found. Once per call, whatever
      // happened since; at the caps it is refused, 429, for Rails to ask later.
      async startHelper(id, input) {
        const { conversation } = await access(id, input);
        if (typeof input.callId !== 'string' || !/^[\w.:|+=-]{1,200}$/.test(input.callId)) throw new ApiError(422, 'invalid_call');
        if (typeof input.task !== 'string' || !input.task.trim() || input.task.length > HELPER_TASK_LIMIT) throw new ApiError(422, 'invalid_task');
        if (input.context != null && (typeof input.context !== 'string' || input.context.length > HELPER_TASK_LIMIT * 4)) throw new ApiError(422, 'invalid_context');
        for (const key of ['model', 'thinking']) {
          if (input[key] != null && (typeof input[key] !== 'string' || !input[key].trim() || input[key].length > 200)) throw new ApiError(422, `invalid_${key}`);
        }
        // A helper is the agent its conversation runs: one Rails never sent a definition has none yet.
        if (!(await harness.snapshot(Definitions, context))?.conversations[conversation.id]) throw new ApiError(409, 'conversation_not_started');
        const helper = capabilityExtensions.subagents.tasks.find(task => task.definition.name === HELPER_TASK);
        const answer = await harness.commit(tx => startNamedHelper(tx, helper,
          { conversationId: conversation.id, callId: input.callId, task: input.task, context: input.context ?? null,
            model: input.model, thinking: input.thinking, modelOf: routeModel }), context);
        if (answer.invalid) throw new ApiError(422, 'helper_model_refused', answer.invalid);
        if (answer.refusal) throw new ApiError(429, 'helpers_busy', answer.refusal);
        return answer;
      },
      // A person's Cancel for one background helper, named by the call that
      // started it: its task is aborted, with the conversation it owns, and the
      // answer says what it had done. Cancelled once; a helper that already
      // ended says so.
      async cancelHelper(id, input) {
        const { conversation } = await access(id, input);
        const task = await helperTask(conversation, input.callId);
        const cancelled = task.state.status !== 'terminal';
        if (cancelled) { await harness.abortTask(task.id, context); await harness.waitForTask(task.id, context); }
        const child = (await harness.commit(tx => tx.scanConversations({ ownerTaskId: task.id }, 1), context)).items[0];
        const entries = [];
        if (child) for await (const entry of allEntries(await harness.conversation(child.id, context))) entries.push(entry);
        return { cancelled, ...callsMade(entries) };
      },
      // Whether one background helper, named by the call that started it, still
      // runs: Rails' minute sweep settles one whose end report never came
      // (Helper.settle_lost). A lookup; nothing stops.
      async helper(id, input) {
        const { conversation } = await access(id, input);
        const task = await helperTask(conversation, input.callId);
        return { status: task.state.status === 'terminal' ? 'terminal' : 'running' };
      },
      // A person's message for one background helper, named by the call that
      // started it, which it reads at its next step (subagent.mjs
      // `steerHelper`). Rails words it. `{ delivered: false }` when the helper
      // has no turn to join: it ended, or is ending.
      async messageHelper(id, input) {
        const { conversation } = await access(id, input);
        requiredString(input.callId, 'call');
        requiredString(input.requestId, 'request');
        if (typeof input.text !== 'string' || !input.text.trim() || input.text.length > TEXT_LIMIT) throw new ApiError(422, 'invalid_content');
        const delivered = await steerHelper({ commit: change => harness.commit(change, context), conversation: child => harness.conversation(child, context) },
          { conversationId: conversation.id, callId: input.callId, requestId: input.requestId, content: input.text });
        if (delivered === undefined) throw new ApiError(404, 'not_found');
        return { delivered };
      },
      // A yes/no attestation on the private snapshot route; never enumerate active calls.
      async activeInvocation(id, scope, identity) {
        const { conversation } = await access(id, scope);
        return { activeInvocation: live.includes({ ...identity, ...scope, conversationId: conversation.id }) };
      },
      // The browser-facing DTO only: no raw Durable state, task inspection, scope
      // binding, task/call identity or other conversations' data. No history
      // either: Rails pages that from `entries`, and a page load asks for this,
      // so it reads only the newest run's entries however long the thread.
      async snapshot(id, scope) {
        const { conversation } = await access(id, scope);
        const inspection = await harness.inspect(context);
        const tasks = inspection.tasks.filter(t => t.record.conversationId === conversation.id && t.record.kind !== HELPER_TASK);
        // How the newest message the agent took in ended: one withdrawn before it
        // was taken in (never placed) says nothing about the run.
        const last = await storage.scanSubmissions({ conversationId: conversation.id, order: 'descending' }, 16, undefined, context);
        const submission = last.items.find(each => !(each.status === 'unanswered' && each.entry === undefined)) ?? last.items[0];
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
        const runStart = runFailure?.first === undefined ? entry => UserEntry.is(entry) || MessageEntry.is(entry) : entry => entry.id < runFailure.first;
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
          compaction: liveCompaction(live), compactionFailed: compactionFailed(live), notesFile: await notesView(conversation.id),
          queued: queuedView(await harness.snapshot(InboxDoc, conversation.id, context)) };
      },
      async close() { try { await harness.close(context); } finally { await carried.close(); connectors.close(); await codemode?.close(); sprites?.close(); ssh?.close(); owner.release(); } }
    };
    return runtime;
  } catch (error) {
    try { if (harness) await harness.close(context); else await storage?.close(context);
      await codemode?.close(); sprites?.close(); ssh?.close(); } finally { owner.release(); }
    throw error;
  }
}
