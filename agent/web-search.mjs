import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { calculateCost } from '@earendil-works/pi-ai/models';
import { anthropicProvider } from '@earendil-works/pi-ai/providers/anthropic';
import { openaiCodexProvider } from '@earendil-works/pi-ai/providers/openai-codex';
import { CLAUDE_CODE_VERSION, shapePayload } from './claude-subscription.mjs';
import { CHATGPT_PROVIDER } from './chatgpt-subscription.mjs';
import { API_KEY_PROVIDER } from './claude-api-key.mjs';
import { accountId } from './openai-codex-oauth.mjs';

// Web search: the provider's own search tool, through the
// credential the conversation's model already uses, which lives only in this
// sidecar. The request shapes are pi-web-search's (anthropic.ts, openai.ts):
// Anthropic Messages with `web_search_20250305` on a small fast model, as
// Claude Code (the subscription's identity, and our billing block), and the
// ChatGPT subscription's Codex Responses with `web_search`. On the pasted
// Anthropic API key, the same Anthropic search as plain API traffic. The answer comes
// back with its sources as links. Each search reserves a request in the run's
// bound and reports what it used.
export const WEB_SEARCH_EXTENSION = 'omakase.web-search';
export const SEARCH_MODEL = 'claude-haiku-5-5';
const CLAUDE_CODE_SYSTEM = "You are Claude Code, Anthropic's official CLI for Claude.";
const MAX_SEARCHES = 5;
const SOURCES = 8;
const prompt = query => `Search the web for: ${query}\n\nAnswer concisely from what you find, and cite your sources.`;

class SearchError extends Error {}

// Server-sent events, one parsed `data:` object at a time.
async function* events(response) {
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let end;
    while ((end = buffer.search(/\r?\n\r?\n/)) >= 0) {
      const block = buffer.slice(0, end);
      buffer = buffer.slice(end).replace(/^\r?\n\r?\n/, '');
      const data = block.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
      if (!data || data === '[DONE]') continue;
      try { yield JSON.parse(data); } catch { /* a keep-alive or a partial line */ }
    }
  }
}

const SIGN_IN_AGAIN = 'Web search was refused: the subscription needs to be signed in again.';
async function post(fetch, url, headers, body, signal, refused = SIGN_IN_AGAIN) {
  const response = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal });
  // The provider's error text stays here; the agent is told only what happened.
  if (!response.ok) throw new SearchError(response.status === 401 || response.status === 403 ? refused : `Web search failed (the provider answered ${response.status}).`);
  return response;
}

const usageOf = ({ input = 0, output = 0, cacheRead = 0, cacheWrite = 0 }, model) => {
  const usage = { input, output, cacheRead, cacheWrite, totalTokens: input + output + cacheRead + cacheWrite,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
  return model?.cost ? { ...usage, cost: calculateCost(model, usage) } : usage;
};

export async function searchAnthropic({ query, token, apiKey = false, fetch = globalThis.fetch, signal }) {
  const model = anthropicProvider().getModels().find(candidate => candidate.id === SEARCH_MODEL);
  // A subscription token rides Claude Code's identity, as the chat does; a
  // key is a key, and the pasted key's route is a key whatever it looks like.
  const subscription = !apiKey && token.startsWith('sk-ant-oat');
  const headers = { 'content-type': 'application/json', accept: 'text/event-stream', 'anthropic-version': '2023-06-01',
    ...(subscription ? { authorization: `Bearer ${token}`, 'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20',
      'user-agent': `claude-cli/${CLAUDE_CODE_VERSION}`, 'x-app': 'cli' } : { 'x-api-key': token }) };
  const payload = { model: SEARCH_MODEL, max_tokens: 4096, messages: [{ role: 'user', content: prompt(query) }],
    tools: [{ type: 'web_search_20250305', name: 'web_search', max_uses: MAX_SEARCHES }], stream: true,
    ...(subscription ? { system: [{ type: 'text', text: CLAUDE_CODE_SYSTEM }] } : {}) };
  const response = await post(fetch, `${model?.baseUrl ?? 'https://api.anthropic.com'}/v1/messages`, headers,
    subscription ? shapePayload(payload) : payload, signal,
    subscription ? SIGN_IN_AGAIN : 'Web search was refused: Anthropic did not accept the API key.');
  let text = '';
  const cited = [], found = [], tokens = {};
  for await (const event of events(response)) {
    if (event.type === 'message_start') {
      const usage = event.message?.usage ?? {};
      Object.assign(tokens, { input: usage.input_tokens ?? 0, cacheRead: usage.cache_read_input_tokens ?? 0,
        cacheWrite: usage.cache_creation_input_tokens ?? 0, output: usage.output_tokens ?? 0 });
    } else if (event.type === 'message_delta' && event.usage?.output_tokens !== undefined) {
      tokens.output = event.usage.output_tokens;
    } else if (event.type === 'content_block_start') {
      const block = event.content_block;
      if (block?.type === 'text' && block.text) text += block.text;
      if (block?.type === 'web_search_tool_result' && Array.isArray(block.content)) found.push(...block.content);
    } else if (event.type === 'content_block_delta') {
      if (event.delta?.type === 'text_delta') text += event.delta.text ?? '';
      if (event.delta?.type === 'citations_delta' && event.delta.citation?.type === 'web_search_result_location') cited.push(event.delta.citation);
    } else if (event.type === 'error') {
      throw new SearchError('Web search failed while the provider was answering.');
    }
  }
  return { text, sources: cited.length ? cited : found, usage: usageOf(tokens, model) };
}

export async function searchCodex({ query, token, modelId, fetch = globalThis.fetch, signal }) {
  const model = openaiCodexProvider().getModels().find(candidate => candidate.id === modelId);
  const account = accountId(token);
  if (!account) throw new SearchError('Web search needs the ChatGPT subscription to be signed in again.');
  const headers = { 'content-type': 'application/json', accept: 'text/event-stream', authorization: `Bearer ${token}`,
    'chatgpt-account-id': account, 'OpenAI-Beta': 'responses=experimental', originator: 'codex_cli_rs' };
  const response = await post(fetch, `${model?.baseUrl ?? 'https://chatgpt.com/backend-api'}/codex/responses`, headers, {
    model: modelId, instructions: "Answer the user's request using web search when needed.",
    input: [{ role: 'user', content: [{ type: 'input_text', text: prompt(query) }] }],
    tools: [{ type: 'web_search' }], tool_choice: 'required', parallel_tool_calls: true,
    include: ['web_search_call.action.sources'], text: { verbosity: 'low' }, stream: true, store: false }, signal);
  let text = '', usage = {};
  const cited = [], found = [];
  const collect = item => {
    if (item?.type === 'web_search_call') found.push(...(item.action?.sources ?? []));
    for (const content of item?.type === 'message' ? item.content ?? [] : []) {
      for (const annotation of content.annotations ?? []) if (annotation?.type === 'url_citation') cited.push(annotation);
    }
  };
  for await (const event of events(response)) {
    if (event.type === 'error' || event.type === 'response.failed') throw new SearchError('Web search failed while the provider was answering.');
    if (event.type === 'response.output_text.delta') text += event.delta ?? '';
    else if (event.type === 'response.output_item.done') collect(event.item);
    else if (event.type === 'response.completed' || event.type === 'response.done' || event.type === 'response.incomplete') {
      const raw = event.response?.usage ?? {};
      const cacheRead = raw.input_tokens_details?.cached_tokens ?? 0;
      usage = { input: (raw.input_tokens ?? 0) - cacheRead, output: raw.output_tokens ?? 0, cacheRead };
      if (!cited.length) for (const item of event.response?.output ?? []) collect(item);
      break;
    }
  }
  return { text, sources: cited.length ? cited : found, usage: usageOf(usage, model) };
}

// The answer, then its sources once each, as Markdown links.
export function answerWithSources({ text, sources }) {
  const links = new Map();
  for (const source of sources) {
    if (typeof source?.url !== 'string' || !/^https?:\/\//.test(source.url) || links.has(source.url)) continue;
    links.set(source.url, (source.title || new URL(source.url).hostname).replace(/[[\]]/g, ''));
  }
  const list = [...links].slice(0, SOURCES).map(([url, title]) => `- [${title}](${url})`);
  return [text.trim() || 'The search found nothing to say.', ...(list.length ? ['', 'Sources:', ...list] : [])].join('\n');
}

// `credential(provider)`: the sidecar's own credential for a provider (a key,
// or the subscription custody's current token), never the environment's.
// `reserve(conversationId)`: one request of the run's bound; the time the run has left.
export function webSearchExtension({ credential, reserve, fetch }) {
  const tool = defineTool({
    name: 'web_search',
    description: 'Search the web for current information. Returns an answer with links to its sources.',
    parameters: { type: 'object', additionalProperties: false, required: ['query'],
      properties: { query: { type: 'string', description: 'What to search for, in plain words.' } } },
    execute: async (args, api, ctx) => {
      const fail = text => ({ output: [{ type: 'text', text }], isError: true });
      const route = (await api.agent(ctx)).model;
      const search = route?.provider === 'anthropic' || route?.provider === API_KEY_PROVIDER ? searchAnthropic
        : route?.provider === CHATGPT_PROVIDER ? searchCodex : undefined;
      if (!search) return fail("Web search is not available for this agent's model.");
      const token = (await credential(route.provider))?.key;
      if (!token) return fail(route.provider === 'anthropic' ? 'Web search needs the Claude subscription; it is not signed in.' :
        route.provider === API_KEY_PROVIDER ? 'Web search needs the Claude API key; it is not set.' :
        'Web search needs the ChatGPT subscription; it is not signed in.');
      let remaining;
      try {
        remaining = await reserve(api.conversationId);
      } catch (error) {
        return fail(error.message === 'request_limit' ? 'This run has used all the requests it may make.' : 'Web search is not allowed now.');
      }
      // A stalled stream would otherwise hold the run past its time limit.
      const timeout = AbortSignal.timeout(remaining);
      try {
        const found = await search({ query: args.query, token, apiKey: route.provider === API_KEY_PROVIDER, modelId: route.modelId,
          fetch, signal: ctx.abortSignal ? AbortSignal.any([ctx.abortSignal, timeout]) : timeout });
        return { output: [{ type: 'text', text: answerWithSources(found) }], usage: found.usage };
      } catch (error) {
        if (ctx.abortSignal?.aborted) throw error;
        if (timeout.aborted) return fail('Web search ran out of the time this run may take.');
        return fail(error instanceof SearchError ? error.message : 'Web search could not reach the provider.');
      }
    }
  });
  return defineExtension({ name: WEB_SEARCH_EXTENSION, tools: [tool] });
}
