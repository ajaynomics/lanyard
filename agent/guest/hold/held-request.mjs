import { createHash, randomBytes } from 'node:crypto';
import { HOLD_MS } from './wire.mjs';

const utf8 = new TextDecoder('utf-8', { fatal: true });
const hash = value => createHash('sha256').update(value).digest('hex');
const WITHHELD = '[withheld]';
const sensitive = name => /pass(word|code|phrase)?|secret|token|authorization|cookie|card.?num|credit.?card|cvv|cvc|security.?code|api.?key|private.?key|ssn/i.test(name);
const secretValue = value => /(?:^|[^\d])\d(?:[ -]?\d){11,18}(?:$|[^\d])|-----BEGIN .*PRIVATE KEY-----|^(?:Bearer |(?:sk-|gh[pousr]_|xox[baprs]-))|^[A-Za-z0-9_+/=\-.]{32,}$/i.test(value);
const concealed = (name, value) => sensitive(name) || secretValue(value) ? WITHHELD : value;
const form = text => {
  const decode = value => decodeURIComponent(value.replaceAll('+', ' '));
  return text ? text.split('&').map(pair => {
    const at = pair.indexOf('=');
    return at < 0 ? [decode(pair), ''] : [decode(pair.slice(0, at)), decode(pair.slice(at + 1))];
  }) : [];
};

// Walk tokens so duplicate JSON keys cannot disappear and numbers are shown
// as written. JSON.parse below first checks the grammar and supplies type hints.
function jsonFields(text) {
  const tree = JSON.parse(text);
  if (!tree || typeof tree !== 'object' || Array.isArray(tree)) throw new Error('expected JSON fields');
  const tokens = text.match(/"(?:\\.|[^"\\])*"|[{}\[\],:]|[^\s{}\[\],:"]+/gs);
  let at = 0;
  const result = [];
  function walk(value, path, hidden, depth) {
    if (depth > 16) throw new Error('nested fields');
    const token = tokens[at++];
    hidden ||= value != null && typeof value === 'object' && /password|credit.?card|secret|token/i.test(value.type ?? '');
    if (token === '{' || token === '[') {
      const keys = new Set();
      const last = token === '{' ? '}' : ']';
      let index = 0;
      while (tokens[at] !== last) {
        if (index > 0) at++;
        const name = token === '{' ? JSON.parse(tokens[at++]) : String(index);
        if (token === '{') at++;
        if (keys.has(name)) throw new Error('duplicate JSON field');
        keys.add(name);
        walk(value[name], [...path, name], hidden || sensitive(name), depth + 1);
        index++;
      }
      at++;
      if (!keys.size && path.length) result.push([path.join(' › '), hidden ? WITHHELD : token + last]);
    } else {
      const value = token[0] === '"' ? JSON.parse(token) : token;
      result.push([path.join(' › '), hidden ? WITHHELD : concealed('', value)]);
    }
  }
  walk(tree, [], false, 0);
  return result;
}

// A page's write says where it came from in Fetch Metadata, which no page
// can set or remove. The browser's own requests, such as its check every
// minute on its on-device model's component (update.googleapis.com), say
// `none`: no page sent them, so nobody is asked about them.
export const fromPage = headers => ['same-origin', 'same-site', 'cross-site'].includes(headers['sec-fetch-site']);

export class HeldRequest {
  constructor(site, request, { now = Date.now(), wait = HOLD_MS } = {}) {
    this.request = request;
    const body = utf8.decode(request.body);
    const fields = request.type === 'application/json' && body ? jsonFields(body) :
      form(body).map(([name, value]) => [name, concealed(name, value)]);
    const path = request.path.split('?')[0].split('/').map(part => concealed('', decodeURIComponent(part)) === WITHHELD ? WITHHELD : part).join('/');
    const query = request.path.includes('?') ? request.path.slice(request.path.indexOf('?') + 1) : '';
    const summary = [...form(query).map(([name, value]) => ['Query: ' + name, concealed(name, value)]), ...fields];
    // A preview must fit in the bounded wire and remain legible. Never cut
    // fields to make an otherwise unreviewable request approvable.
    if (summary.length > 1024 || Buffer.byteLength(JSON.stringify(summary)) > 100_000 ||
        summary.some(row => row.some(text => /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u202a-\u202e\u2066-\u2069]/u.test(text))))
      throw new Error('unreviewable fields');
    this.ticket = { id: randomBytes(24).toString('hex'), site, method: request.method, path,
      targetDigest: hash(request.path), digest: hash(request.body), expiresAt: now + wait, fields: summary };
  }
}
