// The ChatGPT subscription's OAuth protocol, ported from pi-ai 1.5.0
// (dist/auth/oauth/openai-codex.js): the same public client, endpoints, scope
// and authorize parameters Pi uses after `/login openai-codex`. Observed
// public-client protocol, not vendor endorsement. Configuration belongs to
// trusted application code, never an HTTP request.
//
// The redirect is Codex's own localhost callback. A server has nothing
// listening there, so the owner's browser lands on a page that will not load;
// the owner copies that address and pastes it into the console (parse).
import { boundedJson } from './anthropic-oauth.mjs';

export const OPENAI_CODEX_OAUTH = Object.freeze({
  clientId: 'app_EMoamEEZ73f0CkXaXp7hrann',
  authorizeUrl: 'https://auth.openai.com/oauth/authorize',
  tokenUrl: 'https://auth.openai.com/oauth/token',
  redirectUri: 'http://localhost:1455/auth/callback',
  scope: 'openid profile email offline_access',
});
export const MAX_TOKEN_LIFETIME_MS = 31 * 86400 * 1000;
const JWT_CLAIM = 'https://api.openai.com/auth';
const TOKEN = /^[!-~]{10,16384}$/;

// The ChatGPT account the access token is for; pi-ai's codex API reads it the
// same way and sends it as `chatgpt-account-id`. Without one the token is useless.
export function accountId(access) {
  try {
    const parts = access.split('.');
    if (parts.length !== 3) return null;
    const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    const id = payload?.[JWT_CLAIM]?.chatgpt_account_id;
    return typeof id === 'string' && id.length > 0 && id.length <= 256 ? id : null;
  } catch { return null; }
}

const usable = (c, now) => !!c && typeof c.access === 'string' && TOKEN.test(c.access) && accountId(c.access) !== null
  && typeof c.refresh === 'string' && TOKEN.test(c.refresh) && Number.isSafeInteger(c.expires)
  && c.expires <= now + MAX_TOKEN_LIFETIME_MS;

/** Also used at the custody boundary; discard every unrecognised provider field. */
export function validateCodexCredential(value, now = Date.now()) {
  if (!usable(value, now) || value.expires <= now + 60000) throw Error('Invalid subscription credential');
  return { access: value.access, refresh: value.refresh, expires: value.expires };
}

// What the owner pastes: the whole callback address, its query string, or
// `code#state` (pi-ai accepts the same three).
export function parseCompletion(pasted) {
  const value = typeof pasted === 'string' ? pasted.trim() : '';
  if (!value || value.length > 16384) return null;
  let params;
  if (/^https?:\/\//i.test(value)) {
    try { params = new URL(value).searchParams; } catch { return null; }
  } else if (value.includes('#')) {
    const [code, state, ...rest] = value.split('#');
    return rest.length === 0 && code && state ? { code, state } : null;
  } else if (value.includes('code=')) {
    params = new URLSearchParams(value.replace(/^\?/, ''));
  } else return null;
  const code = params.get('code'), state = params.get('state');
  return code && state ? { code, state } : null;
}

/** Lazy: construction never creates a login URL or performs IO. No discovery or endpoint override. */
export function openaiCodexOAuthProtocol({ dispatch = globalThis.fetch, now = Date.now } = {}) {
  async function exchange(form) {
    try {
      const response = await dispatch(OPENAI_CODEX_OAUTH.tokenUrl, {
        method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(30000),
        headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
        body: new URLSearchParams(form).toString(),
      });
      if (!response.ok) { await response.body?.cancel().catch(() => undefined); throw Error(); }
      // Its answer carries an id token beside the two tokens, all JWTs.
      const value = await boundedJson(response, 65536);
      if (!value || !Number.isSafeInteger(value.expires_in) || value.expires_in < 61
        || value.expires_in > MAX_TOKEN_LIFETIME_MS / 1000
        || (value.token_type != null && String(value.token_type).toLowerCase() !== 'bearer')) throw Error();
      return validateCodexCredential({ access: value.access_token, refresh: value.refresh_token,
        expires: now() + value.expires_in * 1000 }, now());
    } catch { throw Error('OAuth outcome unconfirmed; reconnect required; no replay'); }
  }
  return Object.freeze({
    authorize({ state, challenge }) {
      if (!/^[a-f0-9]{64}$/.test(state) || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) throw Error('Invalid OAuth start');
      return OPENAI_CODEX_OAUTH.authorizeUrl + '?' + new URLSearchParams({
        response_type: 'code', client_id: OPENAI_CODEX_OAUTH.clientId, redirect_uri: OPENAI_CODEX_OAUTH.redirectUri,
        scope: OPENAI_CODEX_OAUTH.scope, code_challenge: challenge, code_challenge_method: 'S256', state,
        id_token_add_organizations: 'true', codex_cli_simplified_flow: 'true', originator: 'pi',
      });
    },
    exchange: ({ code, verifier }) => exchange({ grant_type: 'authorization_code', client_id: OPENAI_CODEX_OAUTH.clientId,
      code, code_verifier: verifier, redirect_uri: OPENAI_CODEX_OAUTH.redirectUri }),
    refresh: refresh => exchange({ grant_type: 'refresh_token', refresh_token: refresh, client_id: OPENAI_CODEX_OAUTH.clientId }),
    parse: parseCompletion,
    validate: validateCodexCredential,
    // A stored grant: an expired one may still be loaded for its refresh.
    readable: (c, now) => usable(c, now) && c.expires >= 0,
  });
}
