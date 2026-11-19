import { createHash } from 'node:crypto';
import { defineDoc, defineEntry } from '@earendil-works/pi-durable';

export const digest = value => createHash('sha256').update(canonical(value)).digest('hex');
export function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  if (value && typeof value === 'object') return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
  return JSON.stringify(value);
}
const doc = (kind, scope, initial) => defineDoc({ kind, version: 1, scope,
  ...(scope === 'conversation' ? { history: 'latest', fork: 'initial' } : {}),
  initial, checkpointWhen: (_value, _ops, info) => info.deltasSinceBase >= 32 });
export const Admission = doc('app.admission', 'session', () => ({ conversations: {}, sessions: {} }));
// `root` is set only on a helper's conversation (subagent.mjs): the
// conversation Rails knows and the call the helper runs under there.
export const App = doc('app.scope', 'conversation', () => ({ actorId: null, workspaceId: null, cwd: null, root: null,
  admissions: {}, cancellations: {}, requests: {}, compactions: {}, bounds: { requests: 0 } }));
// Agent definitions Rails sent, by digest, and which one each conversation runs,
// so a restart reinstalls them without asking Rails (agent/runtime.mjs); and
// the notes file each conversation runs with, by its digest and size.
export const Definitions = doc('app.definitions', 'session', () => ({ byDigest: {}, conversations: {}, notes: {} }));
// The background helper each `subagent` call started, by the call's task, so a
// rerun after a crash finds it rather than starting another (subagent.mjs).
export const Helpers = doc('app.helpers', 'session', () => ({ byCall: {} }));
// A message Rails sent, placed as this entry instead of pi.user (pi-durable's
// input `entry`): the model reads the same user message, and the entry keeps
// its request id and, when known, its author, so who said it survives a
// restart and Rails' rebuilt copy (Conversation#sync!) reads it from here.
export const MessageEntry = defineEntry('app.message');
// A note to the model that a message from someone else waits for its turn to
// end (waiting.mjs). The model reads it; Rails never shows it (entryView).
export const WaitingEntry = defineEntry('app.waiting');
// Who wrote a message: a person, by user id, or a channel's sender, by name.
export function validAuthor(author) {
  if (author === undefined) return undefined;
  const keys = author && typeof author === 'object' && !Array.isArray(author) ? Object.keys(author) : [];
  if (keys.length !== 1 || !['userId', 'sender'].includes(keys[0]) || typeof author[keys[0]] !== 'string' ||
    !author[keys[0]].trim() || author[keys[0]].length > 1024) throw new ApiError(422, 'invalid_author');
  return { [keys[0]]: author[keys[0]] };
}
export function requiredString(value, name) {
  if (typeof value !== 'string' || !value.trim() || value.length > 1024) throw new ApiError(422, `invalid_${name}`);
  return value;
}
// detail: words for a person, sent beside the category (a count, a cap); never a secret.
export class ApiError extends Error {
  constructor(status, category, detail) { super(category); this.status = status; this.category = category; this.detail = detail; }
}
export function scopeMatches(doc, scope) {
  return doc?.actorId === scope.actorId && doc?.workspaceId === scope.workspaceId;
}
