import { LiveDoc } from '@earendil-works/pi-durable';
import { MessageEntry } from './state.mjs';

const READS = new Set(['current_time', 'calendar_find', 'calendar_lists', 'list_notes', 'list_documents', 'read_document']);
export const phoneRead = name => READS.has(name);
export const phoneInput = entry => entry?.kind === MessageEntry.kind && entry.data?.phone === true;

// Follow-ups only enter at a new run; ordinary steers never lift the limit.
// Raw entries include the whole live run, even if its model context compacted.
export async function phoneInRun(live, entries) {
  if (!live || (!live.run && (live.generation || live.tools?.length))) throw new Error('phone_scope_unavailable');
  if (!live.run) return false; // Standalone tool tasks are not generation runs.
  const first = live.run.first;
  if (!Number.isSafeInteger(first)) throw new Error('phone_scope_unavailable');
  let cursor, foundFirst = false;
  do {
    const page = await entries({ minEntryId: first, order: 'ascending' }, 64, cursor);
    if (page.items.some(phoneInput)) return true;
    foundFirst ||= page.items.some(entry => entry.id === first);
    cursor = page.next;
  } while (cursor !== undefined);
  if (!foundFirst) throw new Error('phone_scope_unavailable');
  return false;
}

export async function phoneScope(api, ctx) {
  return phoneInRun(await api.snapshot(LiveDoc, api.conversationId, ctx), (...args) => api.entries(...args, ctx));
}

// Pi AI replays tool deltas from system messages. Filter every delta, not
// just the last one: otherwise a declaration from an earlier turn survives.
export function phoneMessages(messages) {
  const first = messages.findIndex(message => message.role === 'system');
  return messages.map((message, index) => message.role === 'system' ? { ...message,
    ...(index === first && { sections: { ...message.sections, 'omakase.phone':
      'This phone request is read-only. Use only the tools offered here; helpers and computer tools are unavailable.' } }),
    ...(message.toolsAdded && { toolsAdded: message.toolsAdded.filter(tool => phoneRead(tool.name)) }),
    ...(message.toolsRemoved && { toolsRemoved: message.toolsRemoved.filter(tool => phoneRead(tool.name)) }) } : message);
}
