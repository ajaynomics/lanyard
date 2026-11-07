// OpenAI through Ajay's ChatGPT subscription, as Pi does after
// `/login openai-codex`: pi-ai's `openai-codex` provider, unchanged, with the
// grant this application owns.
//
// Custody is the Claude subscription's (subscription-credentials.mjs): the
// owner signs in once from Rails' owner console, the grant is sealed with
// SUBSCRIPTION_VAULT_KEY, each exchange and refresh is recorded before it is
// sent and never replayed. Only the protocol differs (openai-codex-oauth.mjs).
//
// pi-ai does the whole request for the token: the bearer, the
// `chatgpt-account-id` it reads from the token itself, and Codex's headers.
import { createProvider } from '@earendil-works/pi-ai/models';
import { openaiCodexProvider } from '@earendil-works/pi-ai/providers/openai-codex';
import { openAICodexResponsesApi } from '@earendil-works/pi-ai/api/openai-codex-responses.lazy';
import { DEFAULT_APPLICATION, SubscriptionCredentials, fileStorage } from './subscription-credentials.mjs';
import { openaiCodexOAuthProtocol } from './openai-codex-oauth.mjs';

export const CHATGPT_PROVIDER = 'openai-codex';

// The grant's custody: this install (AGENT_APPLICATION), this environment, its
// owner, and the provider, so it never
// meets the Claude grant even in the same file.
export function chatgptCustody({ file, vaultKey, environment, application = DEFAULT_APPLICATION }) {
  return new SubscriptionCredentials({ storage: fileStorage(file), vaultKey, enabled: true, protocol: openaiCodexOAuthProtocol(),
    scope: { application, environment, principal: 'owner', provider: CHATGPT_PROVIDER } });
}

// Pi's Codex models and endpoint, authenticated only by the custody (never
// Pi's own auth file or an environment variable).
export function chatgptProvider() {
  const base = openaiCodexProvider();
  return createProvider({
    id: CHATGPT_PROVIDER, name: 'OpenAI (ChatGPT subscription)', baseUrl: base.baseUrl, models: base.getModels(),
    auth: { apiKey: { name: 'ChatGPT subscription', resolve: async ({ credential }) =>
      credential?.key ? { auth: { apiKey: credential.key }, source: 'ChatGPT subscription' } : undefined } },
    api: openAICodexResponsesApi()
  });
}
