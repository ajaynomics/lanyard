// Named Claude routes (docs/agent.md, "Claude routes"): several lenders'
// sockets (subscription-lending.mjs), each another account's Claude
// subscription, in the install's order. Calls go to the first that is not at
// its usage limit; an agent may name its own route, which then comes first.
//
// When a call is refused for the account's usage limit (HTTP 429), or the
// lender answers 503 `subscription_unavailable`, it is asked once more on the
// next route, and calls stay there until the first route's reset time (the
// 429's anthropic-ratelimit-unified-* headers, resetOf) or, with none given, until a later call tried on it
// every PROBE_MS succeeds. The same signals a person switching accounts by
// hand goes by; no usage endpoint is read, since the sockets lend no such
// thing.
//
// A route only picks a socket. Nothing here signs in, refreshes or reads a
// lender's sign-in: each lender keeps its own, as ever. The one exception is
// a route that is the install's own lend socket (`own`): that route uses the
// install's own grant directly, the custody it lends, rather than asking
// itself through the socket.
import { AssistantMessageEventStream } from '@earendil-works/pi-ai';
import { isAbsolute, resolve } from 'node:path';
import { borrowedCustody } from './subscription-lending.mjs';

export const PROBE_MS = 15 * 60 * 1000;
const NAME = /^[a-z][a-z0-9-]{0,31}$/;
const EMPTY_USAGE = Object.freeze({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } });

// "main=/srv/lending/main.sock,spare=/srv/lending/spare.sock", in order.
export function claudeRouteList(text) {
  const routes = String(text ?? '').split(',').map(entry => entry.trim()).filter(Boolean).map(entry => {
    const at = entry.indexOf('=');
    return { name: entry.slice(0, at).trim(), socketPath: entry.slice(at + 1).trim() };
  });
  if (!routes.length || routes.some(route => !NAME.test(route.name) || !isAbsolute(route.socketPath)) ||
    new Set(routes.map(route => route.name)).size !== routes.length) throw new Error('claude_routes_invalid');
  return routes;
}

export const validRouteName = name => typeof name === 'string' && NAME.test(name);

// When a 429 says the limit resets, read as the pi claude-account extension
// reads Anthropic's real responses: each window (5h, 7d) that is `rejected`
// resets at its own `-reset`; with none, a `rejected` overall status at
// `anthropic-ratelimit-unified-reset`. Each is epoch seconds, and only a
// time still ahead counts; the latest one wins. None means unknown.
const UNIFIED = 'anthropic-ratelimit-unified-';
export function resetOf(headers, now) {
  const at = name => { const ms = Number(headers.get(`${UNIFIED}${name}`)) * 1000; return ms > now() ? ms : null; };
  const windows = ['5h', '7d'].filter(window => headers.get(`${UNIFIED}${window}-status`) === 'rejected').map(window => at(`${window}-reset`));
  const resets = (windows.length ? windows : headers.get(`${UNIFIED}status`) === 'rejected' ? [at('reset')] : []).filter(Boolean);
  return resets.length ? Math.max(...resets) : null;
}

// The install's own grant as one of its routes, shaped as a borrowed one: its
// sign-in is made and refreshed by its custody alone, never from a route, and
// a token it cannot give is refused as its lend socket would refuse it (503
// subscription_unavailable), so the call moves to the next route.
const UNAVAILABLE = 'Subscription connection unavailable; reconnect required; no fallback';
function ownRoute({ custody, lender }) {
  const refused = async () => ({ status: 409, data: { error: 'subscription_borrowed', lender } });
  return {
    borrowed: true,
    accessToken: () => custody.accessToken().catch(() => { throw Object.assign(Error(UNAVAILABLE), { refusal: 'subscription_unavailable' }); }),
    async status() {
      const connected = (await custody.status().catch(() => null))?.connected === true;
      return { configured: true, connected, borrowed: true, lender, version: 0, expiresAt: null, reconnectRequired: false,
        failure: null, pending: null, credentialSource: 'borrowed', secretsExposed: false, fallback: false };
    },
    start: refused, finish: refused, disconnect: refused
  };
}

export function claudeRouter(list, { secret, own, now = Date.now, probeMs = PROBE_MS, log = line => console.error(line) }) {
  const ours = socketPath => own && resolve(socketPath) === resolve(own.socketPath);
  const routes = list.map(({ name, socketPath }) => ({ name,
    custody: ours(socketPath) ? ownRoute(own) : borrowedCustody({ socketPath, secret, now }) }));
  // Routes at their limit, by name: { until (null when unknown), probeAt, reason }.
  const limited = new Map();
  const time = at => new Date(at).toISOString();
  const settle = () => {
    for (const [name, hold] of limited) if (hold.until !== null && now() >= hold.until) {
      limited.delete(name);
      log(`sidecar: Claude route ${name}'s limit reset at ${time(hold.until)}; calls go to it again`);
    }
  };
  const usable = route => !limited.has(route.name) || now() >= limited.get(route.name).probeAt;
  const chain = preferred => [...routes].sort((a, b) => (b.name === preferred) - (a.name === preferred));
  // Where a call goes, and where it goes once more if refused.
  const order = preferred => {
    settle();
    const all = chain(preferred), ready = all.filter(usable);
    return ready.length ? ready : all.slice(0, 1);
  };
  const limit = (route, until, reason) => {
    limited.set(route.name, { until, probeAt: now() + probeMs, reason });
    log(`sidecar: Claude route ${route.name} refused (${reason})${until ? `, resets ${time(until)}` : ''}; calls go to the next route`);
  };
  const answered = route => {
    if (limited.delete(route.name)) log(`sidecar: Claude route ${route.name} answers again; calls go to it again`);
  };

  // One try on one route. False when refused for its limit and another route
  // may take the call; otherwise the call's events, as they come.
  async function attempt(route, models, method, model, context, opts, out, last) {
    // An empty key fails as a missing credential does (credential_missing),
    // never on another route's.
    const token = await route.custody.accessToken().catch(error => {
      if (error?.refusal === 'subscription_unavailable') limit(route, null, 'lender 503 subscription_unavailable');
      return error?.refusal === 'subscription_unavailable' && !last ? false : '';
    });
    if (token === false) return false;
    // Limited only on a 429 this call's own fetch saw, never on "429" in an
    // error's words: a 400 or 500 that mentions it is the route's own failure.
    let refused = false, until = null;
    const fetch = async (input, init) => {
      const response = await (opts.fetch ?? globalThis.fetch)(input, init);
      if (response.status === 429) { refused = true; until = resetOf(response.headers, now); }
      return response;
    };
    const source = models[method](model, context, { ...opts, apiKey: token, fetch });
    let first = true;
    for await (const event of source) {
      if (first && event.type === 'error' && refused) {
        limit(route, until, 'HTTP 429');
        if (!last) return false;
      }
      first = false;
      out.push(event);
    }
    const message = await source.result();
    if (message.stopReason !== 'error') answered(route);
    out.end(message);
    return true;
  }

  // Each route's state for the owner console, in the install's order.
  const view = () => {
    settle();
    const active = routes.find(route => !limited.has(route.name)) ?? routes[0];
    return routes.map(route => {
      const hold = limited.get(route.name);
      return { name: route.name, state: hold ? 'limited' : route === active ? 'active' : 'standby',
        fallback: route === active && route !== routes[0], resetAt: hold?.until ? time(hold.until) : null };
    });
  };
  const lead = routes[0].custody;

  return {
    names: routes.map(route => route.name),
    // As one borrowed custody: the default chain's token, for what asks for
    // the provider's credential without a conversation (web search), and the
    // status the owner console shows, with each route's.
    custody: { ...lead,
      accessToken: () => order()[0].custody.accessToken(),
      status: async () => ({ ...(await order()[0].custody.status()), routes: view() }) },
    // Models whose Claude calls go by route. `routeOf` names a call's
    // conversation's own route (its agent's), if any.
    wrap(models, routeOf) {
      const dispatch = method => (model, context, opts = {}) => {
        if (model.provider !== 'anthropic') return models[method](model, context, opts);
        const out = new AssistantMessageEventStream();
        void (async () => {
          const [first, next] = order(await routeOf(opts.sessionId).catch(() => undefined));
          if (!(await attempt(first, models, method, model, context, opts, out, !next))) {
            await attempt(next, models, method, model, context, opts, out, true);
          }
        })().catch(error => {
          const message = { role: 'assistant', content: [], api: model.api, provider: model.provider, model: model.id, usage: EMPTY_USAGE,
            stopReason: 'error', errorMessage: String(error?.message ?? error), timestamp: Date.now() };
          out.push({ type: 'error', reason: 'error', error: message });
          out.end(message);
        });
        return out;
      };
      const overrides = { stream: dispatch('stream'), streamSimple: dispatch('streamSimple') };
      overrides.complete = async (...args) => overrides.stream(...args).result();
      overrides.completeSimple = async (...args) => overrides.streamSimple(...args).result();
      return new Proxy(models, { get(target, key) { const value = overrides[key] ?? target[key]; return typeof value === 'function' && !overrides[key] ? value.bind(target) : value; } });
    }
  };
}
