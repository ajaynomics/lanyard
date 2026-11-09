import { createHash } from 'node:crypto';
import { defineDoc } from '@earendil-works/pi-durable';

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
export function requiredString(value, name) {
  if (typeof value !== 'string' || !value.trim() || value.length > 1024) throw new ApiError(422, `invalid_${name}`);
  return value;
}
export class ApiError extends Error {
  constructor(status, category) { super(category); this.status = status; this.category = category; }
}
export function scopeMatches(doc, scope) {
  return doc?.actorId === scope.actorId && doc?.workspaceId === scope.workspaceId;
}
