// The Claude subscription's OAuth protocol, ported from an earlier app
// src/providers/anthropic-oauth.mjs (6bc2819), itself from an earlier app f9b801c3,
// app/src/anthropic-oauth.js. Observed public-client protocol, not vendor
// endorsement. Configuration belongs to code, never to an HTTP request.
// Configuration belongs to trusted application code, never an HTTP request.
export const ANTHROPIC_OAUTH = Object.freeze({
  clientId: '9d1c250a-e61b-44d9-88ed-5944d1962f5e',
  authorizeUrl: 'https://claude.ai/oauth/authorize',
  tokenUrl: 'https://platform.claude.com/v1/oauth/token',
  redirectUri: 'https://platform.claude.com/oauth/code/callback',
  scopes: 'org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload',
});
export const MAX_TOKEN_LIFETIME_MS = 31 * 86400 * 1000;
export const isSubscriptionAccessToken = value => typeof value === 'string' && /^sk-ant-oat[!-~]{10,4096}$/.test(value);
const isRefreshToken = value => typeof value === 'string' && /^sk-ant-ort[!-~]{10,4096}$/.test(value);

/** Also used at the custody boundary; discard every unrecognised provider field. */
export function validateSubscriptionCredential(value, now = Date.now()) {
  if (!value || !isSubscriptionAccessToken(value.access) || !isRefreshToken(value.refresh)
    || !Number.isSafeInteger(value.expires) || value.expires <= now + 60000
    || value.expires > now + MAX_TOKEN_LIFETIME_MS) throw Error('Invalid subscription credential');
  return { access: value.access, refresh: value.refresh, expires: value.expires };
}

/** Bounded reader: do not trust Content-Length or include raw replies in errors. */
export async function boundedJson(response, maxBytes = 16384) {
  const reader = response.body?.getReader();
  if (!reader) throw Error('Invalid provider reply');
  const chunks = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) throw Error();
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
  } catch {
    await reader.cancel().catch(() => undefined);
    throw Error('Invalid provider reply');
  } finally { reader.releaseLock(); }
}

/** Lazy: construction never creates a login URL or performs IO. No discovery or endpoint override. */
export function anthropicOAuthProtocol({ dispatch = globalThis.fetch, now = Date.now } = {}) {
  async function exchange(body) {
    try {
      const response = await dispatch(ANTHROPIC_OAUTH.tokenUrl, {
        method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(30000),
        headers: { 'content-type': 'application/json', accept: 'application/json' },
        body: JSON.stringify({ ...body, client_id: ANTHROPIC_OAUTH.clientId }),
      });
      if (!response.ok) { await response.body?.cancel().catch(() => undefined); throw Error(); }
      const value = await boundedJson(response);
      if (!value || !Number.isSafeInteger(value.expires_in) || value.expires_in < 61
        || value.expires_in > MAX_TOKEN_LIFETIME_MS / 1000
        || (value.token_type != null && String(value.token_type).toLowerCase() !== 'bearer')) throw Error();
      return validateSubscriptionCredential({ access: value.access_token, refresh: value.refresh_token,
        expires: now() + value.expires_in * 1000 }, now());
    } catch { throw Error('OAuth outcome unconfirmed; reconnect required; no replay'); }
  }
  return Object.freeze({
    authorize({ state, challenge }) {
      if (!/^[a-f0-9]{64}$/.test(state) || !/^[A-Za-z0-9_-]{43}$/.test(challenge)) throw Error('Invalid OAuth start');
      return ANTHROPIC_OAUTH.authorizeUrl + '?' + new URLSearchParams({
        code: 'true', client_id: ANTHROPIC_OAUTH.clientId, response_type: 'code',
        redirect_uri: ANTHROPIC_OAUTH.redirectUri, scope: ANTHROPIC_OAUTH.scopes,
        code_challenge: challenge, code_challenge_method: 'S256', state,
      });
    },
    exchange: ({ code, state, verifier }) => exchange({ grant_type: 'authorization_code', code, state,
      redirect_uri: ANTHROPIC_OAUTH.redirectUri, code_verifier: verifier }),
    refresh: refresh => exchange({ grant_type: 'refresh_token', refresh_token: refresh }),
    // Anthropic's callback page shows `code#state` for the owner to copy.
    parse(pasted) {
      const parts = typeof pasted === 'string' ? pasted.trim().split('#') : [];
      return parts.length === 2 && parts[0] && parts[0].length <= 4096 && parts[1] ? { code: parts[0], state: parts[1] } : null;
    },
    validate: validateSubscriptionCredential,
    // A stored grant: an expired one may still be loaded for its refresh.
    readable: (c, now) => !!c && Number.isSafeInteger(c.expires) && c.expires >= 0 && c.expires <= now + MAX_TOKEN_LIFETIME_MS
      && isSubscriptionAccessToken(c.access) && isRefreshToken(c.refresh),
  });
}
