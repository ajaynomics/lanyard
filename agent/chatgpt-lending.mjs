// OpenAI through a ChatGPT sign-in borrowed from a lender (docs/agent.md,
// "Lending a subscription"): Pi's "Sign in with ChatGPT", the `openai`
// provider's own subscription sign-in, whose access token goes straight to
// api.openai.com's Responses API. This install never signs in to it: it
// borrows the lender's current access token for a few minutes at a time
// (subscription-lending.mjs) and never holds the refresh token.
//
// A provider of its own, beside `openai` (an API key, billed per token), so an
// agent's model says which one pays. pi-ai knows a ChatGPT sign-in by the
// `openai` provider and its token (openai-responses.js, isChatGPTSignIn): it
// then leaves out what that sign-in refuses. So each request reaches pi-ai's
// Responses API as `openai`'s, and its reply comes back as this provider's.
import { createProvider } from '@earendil-works/pi-ai/models';
import { openaiProvider } from '@earendil-works/pi-ai/providers/openai';
import { openAIResponsesApi } from '@earendil-works/pi-ai/api/openai-responses.lazy';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';
import { borrowedCustody } from './subscription-lending.mjs';

export const BORROWED_CHATGPT_PROVIDER = 'openai-chatgpt';
const OPENAI = 'openai';

// An OpenAI API key starts with sk-, and is never lent as a ChatGPT sign-in:
// it would bill per token where the owner expects the subscription.
export const chatgptSignInToken = access => typeof access === 'string' && !access.startsWith('sk-');

export function borrowedChatgptCustody({ socketPath, secret, now }) {
  return borrowedCustody({ socketPath, secret, now, provider: BORROWED_CHATGPT_PROVIDER, accepts: chatgptSignInToken });
}

const asOpenAI = message => message?.provider === BORROWED_CHATGPT_PROVIDER ? { ...message, provider: OPENAI } : message;
const asOurs = message => message?.provider === OPENAI ? Object.assign(message, { provider: BORROWED_CHATGPT_PROVIDER }) : message;

// pi-ai's stream, its messages relabelled as this provider's as they pass.
// pi-ai reports a failure as an error event, never by throwing; should it
// throw all the same, the turn ends as an error rather than waiting forever.
function relabelled(inner, model) {
  const outer = new AssistantMessageEventStream();
  (async () => {
    let result;
    for await (const event of inner) {
      for (const message of [event.partial, event.message, event.error]) asOurs(message);
      if (event.type === 'done') result = event.message; else if (event.type === 'error') result = event.error;
      outer.push(event);
    }
    outer.end(asOurs(result ?? await inner.result()));
  })().catch(error => outer.push({ type: 'error', reason: 'error', error: { role: 'assistant', content: [], api: model.api,
    provider: BORROWED_CHATGPT_PROVIDER, model: model.id, usage: EMPTY_USAGE, stopReason: 'error', errorMessage: String(error?.message ?? error), timestamp: Date.now() } }));
  return outer;
}

const EMPTY_USAGE = Object.freeze({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });

export function borrowedChatgptProvider() {
  const base = openaiProvider();
  const api = openAIResponsesApi();
  const through = call => (model, context, options) => relabelled(api[call]({ ...model, provider: OPENAI },
    { ...context, messages: (context?.messages ?? []).map(asOpenAI) }, options), model);
  return createProvider({
    id: BORROWED_CHATGPT_PROVIDER, name: 'OpenAI (ChatGPT sign-in, borrowed)', baseUrl: base.baseUrl,
    models: base.getModels().map(model => ({ ...model, provider: BORROWED_CHATGPT_PROVIDER })),
    auth: { apiKey: { name: 'ChatGPT sign-in', resolve: async ({ credential }) =>
      chatgptSignInToken(credential?.key) ? { auth: { apiKey: credential.key }, source: 'ChatGPT sign-in' } : undefined } },
    api: { stream: through('stream'), streamSimple: through('streamSimple') }
  });
}
