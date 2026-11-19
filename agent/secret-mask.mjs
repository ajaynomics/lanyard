// Masks what looks like a secret in a tool's result before the model reads
// it: a key a command printed, a token in a page, a password in a config file.
// The shapes are config/secret_shapes.json, which Rails masks the reports it
// sends as messages with (SecretShapes), so both say the same thing.
//
// Masking is a backstop, not a permission: agents still never print secrets.
import { readFileSync } from 'node:fs';
import { defineExtension, hook, ToolTask } from '@earendil-works/pi-durable';

export const SHAPES = JSON.parse(readFileSync(new URL('../config/secret_shapes.json', import.meta.url), 'utf8'))
  .map(shape => ({ ...shape, regexp: new RegExp(shape.pattern, 'g') }));
export const MASKED = '[masked]';
export const MASKED_CODE = 'masked';

// A long run is a secret only when it mixes cases and digits like one: an id
// of words, a timestamp or a hash does not. Base64 over 1 KB is a picture or
// a file, never a key, and a run after `base64,` is a data: URI.
const LONGEST_KEY = 1024;
const MIXED = 3;
const URL_TEXT = /https?:\/\/[^\s"'<>`]+/g;
const ORIGIN = /^(https?):\/\/([^/?#\s:@]+)(?::(\d+))?(?=[/?#]|$)/;

// `appUrl`: this install's own address (APP__URL). A link on exactly its
// origin is the app's, such as the sign-in link the agent must send on;
// a host that only looks like it is masked as any other.
export function maskSecrets(text, { appUrl } = {}) {
  if (typeof text !== 'string' || text === '') return { text, count: 0 };
  const own = origin(appUrl);
  let count = 0, out = '', at = 0;
  const masked = piece => { const result = maskPiece(piece); count += result.count; return result.text; };
  for (const found of own ? text.matchAll(URL_TEXT) : []) {
    if (!sameOrigin(origin(found[0]), own)) continue;
    out += masked(text.slice(at, found.index)) + found[0];
    at = found.index + found[0].length;
  }
  out += masked(text.slice(at));
  return { text: out, count };
}

export function maskedNote(count) {
  return `[masked ${count} secret-shaped ${count === 1 ? 'value' : 'values'}]`;
}

function maskPiece(text) {
  let count = 0;
  for (const shape of SHAPES) {
    text = text.replace(shape.regexp, (match, ...rest) => {
      const offset = rest.at(-2), whole = rest.at(-1);
      if (shape.entropy !== undefined) return entropyMask(match, whole.slice(0, offset), shape.entropy, () => count++);
      count++;
      return `${shape.keep ? rest[0] : ''}${MASKED}`;
    });
  }
  return { text, count };
}

function entropyMask(run, before, threshold, counted) {
  if (run.length > LONGEST_KEY || before.endsWith('base64,')) return run;
  return run.split('/').map(part => {
    if (!secretShaped(part, threshold)) return part;
    counted();
    return MASKED;
  }).join('/');
}

function secretShaped(part, threshold) {
  if (part.length < 32 || /^[0-9A-Fa-f-]+$/.test(part)) return false;
  const upper = part.match(/[A-Z]/g)?.length ?? 0, lower = part.match(/[a-z]/g)?.length ?? 0;
  return upper >= MIXED && lower >= MIXED && /[0-9]/.test(part) && entropy(part) >= threshold;
}

function entropy(text) {
  const counts = new Map();
  for (const character of text) counts.set(character, (counts.get(character) ?? 0) + 1);
  let bits = 0;
  for (const seen of counts.values()) { const share = seen / text.length; bits -= share * Math.log2(share); }
  return bits;
}

function origin(url) {
  const found = typeof url === 'string' ? url.match(ORIGIN) : null;
  if (!found) return null;
  const scheme = found[1].toLowerCase();
  return { scheme, host: found[2].toLowerCase(), port: found[3] ?? (scheme === 'https' ? '443' : '80') };
}

function sameOrigin(one, other) {
  return !!one && one.scheme === other.scheme && one.host === other.host && one.port === other.port;
}

// Every result the model reads, of every tool, the agent's and its helpers'.
// Not a script's own calls: a script uses ids and hashes as data, and what it
// returns or prints is masked as the code mode call's result.
//
// `appUrl` is APP__URL from the sidecar's own environment, not from Rails, so
// a Rails and a sidecar of different releases still agree on a definition.
// Without a usable one every link is masked like any other, and the sidecar
// says so once rather than refusing to start.
export function secretMask({ appUrl, log = line => console.error(line) } = {}) {
  if (!origin(appUrl)) log('sidecar: APP__URL is not set to a web address; links on the app\'s own address are masked like any other');
  return defineExtension({ name: 'omakase.secret-mask', hooks: [hook(ToolTask, {
    afterTool: async (call, result) => {
      if (call.parent || !Array.isArray(result.output)) return undefined;
      let count = 0;
      const output = result.output.map(block => {
        if (block.type !== 'text') return block;
        const masked = maskSecrets(block.text, { appUrl });
        count += masked.count;
        return masked.count ? { ...block, text: masked.text } : block;
      });
      if (!count) return undefined;
      return { ...result, output, diagnostics: [...(result.diagnostics ?? []), { severity: 'info', code: MASKED_CODE, message: maskedNote(count) }] };
    }
  })] });
}
