// A conversation's history as pi's session file (format v3, pi's
// docs/session-format.md), so `pi --session <file>` opens it.
//
// Built from the durable store's entries, which hold everything; Rails'
// messages are a lossy copy. One line per JSON object: the header, the
// session's name, the bot's instructions as a system message, its model and
// then each message as pi-ai's message object, linked in one
// linear parentId chain. A summary becomes pi's compaction entry. A branch's
// entries include its parent's history, so its file stands alone (no
// parentSession). Durable's own system entries (prompt sections and tool
// declarations of the sidecar's extensions) are left out: the leading system
// message stands for them.
//
// Thinking signatures and redacted thinking are left out: they are opaque,
// and only the provider that wrote them can read them. Images stay inline,
// base64, as pi stores them.
export const SESSION_VERSION = 3;
// The header's working directory. Never a host path: "." opens the file in
// the directory pi is started from.
export const SESSION_CWD = '.';
const SUMMARY = /^The conversation history before this point was compacted into the following summary:\n\n<summary>\n([\s\S]*)\n<\/summary>$/;

// Line ids: 8 hex digits per entry, as pi writes them, and a suffix for an
// entry's later messages. Lines of our own start with "s", which no entry id does.
const lineId = (entry, index) => entry.id.toString(16).padStart(8, '0') + (index ? `-${index}` : '');
const iso = ms => new Date(ms).toISOString();

function exportedMessage(message) {
  if (!Array.isArray(message.content)) return message;
  const content = message.content.filter(block => !(block.type === 'thinking' && block.redacted)).map(block => {
    if (block.type !== 'thinking' || !('thinkingSignature' in block)) return block;
    const { thinkingSignature: _signature, ...kept } = block;
    return kept;
  });
  return { ...message, content };
}

// entries: the store's entry records, oldest first. Returns the file's lines as objects.
export function sessionFile(entries, { id, title, instructions, model, now = Date.now() }) {
  const first = entries.flatMap(entry => entry.model ?? []).find(message => Number.isFinite(message.timestamp))?.timestamp ?? now;
  const lines = [{ type: 'session', version: SESSION_VERSION, id, timestamp: iso(first), cwd: SESSION_CWD }];
  let parentId = null;
  const append = (line, ms = first) => { lines.push({ ...line, parentId, timestamp: iso(ms) }); parentId = line.id; };
  if (title) append({ type: 'session_info', id: 's0000001', name: title });
  if (instructions) append({ type: 'message', id: 's0000002', message: { role: 'system', content: instructions, timestamp: first } });
  if (model) append({ type: 'model_change', id: 's0000003', provider: model.provider, modelId: model.modelId });
  // Which line each entry became, to find a summary's first kept entry.
  const placed = [];
  let tokens = 0;
  for (const entry of entries) {
    const messages = entry.model ?? [];
    if (entry.kind === 'pi.compaction') {
      const text = messages[0]?.content?.find?.(block => block.type === 'text')?.text ?? '';
      const kept = placed.find(row => row.entryId >= entry.head)?.lineId ?? lineId(entry, 0);
      // pi drops system messages before a summary from the model's context, so
      // the summary carries the instructions forward as its checkpoint.
      append({ type: 'compaction', id: lineId(entry, 0), summary: SUMMARY.exec(text)?.[1] ?? text, firstKeptEntryId: kept, tokensBefore: tokens,
        ...(instructions ? { systemMessage: { role: 'system', content: instructions, timestamp: first } } : {}) }, messages[0]?.timestamp ?? first);
      placed.push({ entryId: entry.id, lineId: lineId(entry, 0) });
      continue;
    }
    if (!['pi.user', 'pi.assistant', 'pi.tool-result'].includes(entry.kind)) continue;
    messages.forEach((message, index) => {
      append({ type: 'message', id: lineId(entry, index), message: exportedMessage(message) }, message.timestamp ?? first);
      if (index === 0) placed.push({ entryId: entry.id, lineId: lineId(entry, 0) });
      if (message.role === 'assistant' && message.usage?.totalTokens) tokens = message.usage.totalTokens;
    });
  }
  return lines;
}
