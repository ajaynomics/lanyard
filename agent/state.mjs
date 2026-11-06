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
export const McpGrants = doc('app.mcp-grants', 'session', () => ({ grants: {} }));
export const App = doc('app.scope', 'conversation', () => ({ actorId: null, workspaceId: null, cwd: null,
  admissions: {}, cancellations: {}, requests: {}, grants: {}, permittedCalls: {}, goal: null, goalActions: {}, workflows: {},
  bounds: { requests: 0, startedAt: null, continuations: 0 }, paused: false }));
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
export function validateAnswer(request, answer, now) {
  if (request.status !== 'pending' || request.expiresAt <= now) throw new ApiError(409, 'input_not_pending');
  if (request.kind === 'approval') {
    if (!answer || !['approve', 'deny'].includes(answer.decision) ||
      answer.digest !== request.digest || (answer.decision === 'approve' && !['once', 'session'].includes(answer.scope)) ||
      (answer.scope !== undefined && !['once', 'session'].includes(answer.scope)) ||
      (answer.uses !== undefined && (!Number.isInteger(answer.uses) || answer.uses < 1 || answer.uses > request.maxUses))) {
      throw new ApiError(422, 'invalid_approval');
    }
  } else {
    if (!answer || !Array.isArray(answer.selections) || answer.selections.length !== request.tabs.length ||
      (answer.text !== undefined && typeof answer.text !== 'string')) throw new ApiError(422, 'invalid_answer');
    request.tabs.forEach((tab, i) => {
      const selected = answer.selections[i];
      if (!Array.isArray(selected) || new Set(selected).size !== selected.length ||
        (!tab.multiple && selected.length > 1) || (!tab.optional && selected.length === 0 && !(tab.custom && answer.text)) ||
        selected.some(v => !tab.options.some(option => option.id === v)) ||
        (answer.text && !request.tabs.some(t => t.custom))) throw new ApiError(422, 'invalid_selection');
    });
  }
}
