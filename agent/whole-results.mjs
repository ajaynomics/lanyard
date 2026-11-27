// One size limit for every tool result, the model's own calls and a code
// mode script's alike, and past it the whole result saved, never a cut copy
// (docs/agent.md, "One size limit for every result"). Durable keeps the
// head of a result over its output limits (50 KiB or 2,000 lines,
// pi-durable's truncate.js DEFAULT_MAX_BYTES and DEFAULT_MAX_LINES) and tells
// the model so beside it, in a diagnostic a script never sees: a script got
// the head as the value, JSON that no longer parsed ("Unterminated string in
// JSON"), and the model a document cut mid-value. Two Gmail threads were
// lost this way, and a 128 KB answer (#192). So a result over
// RESULT_MAX_BYTES, under Durable's cut with room for what is added to it, is
// replaced by valid JSON: where the whole of it was saved, its size and its
// start. Its pictures are kept, as they are not what is cut.
import { defineExtension, hook, ToolTask } from '@earendil-works/pi-durable';
import { saveText } from './files.mjs';

// 48 KiB: 3 KiB under Durable's 51,200 bytes, the smallest limit a result
// passes on its way to the model or a script, for the diagnostics Durable
// appends after this hook. Rails' DurableAssistants::ResultBytes::LIMIT is
// the same number (test/lib/result_bytes_test.rb holds them equal).
export const RESULT_MAX_BYTES = 48 * 1024;
// Durable also cuts at 2,000 lines, whatever the bytes.
export const RESULT_MAX_LINES = 2000;
// Enough of the start to see what the result is, small enough to read whole.
export const PREVIEW_CHARACTERS = 1000;
// The code mode tool bounds its own output by the script's token budget and
// saves the whole of it to a file itself (pi-durable codemode/output.js).
const OWN_BOUNDS = new Set(['codemode']);

const count = number => Number(number ?? 0).toLocaleString('en');
const LIMIT = `the limit of ${count(RESULT_MAX_BYTES)} bytes or ${count(RESULT_MAX_LINES)} lines for one result`;
const textOf = result => (result.output ?? []).filter(block => block.type === 'text').map(block => block.text).join('\n');

// `envOf(api, context, call)`: the computer used by this call. Hooks get
// no tool environment, so resolve it again without changing the target.
export function wholeResults({ envOf }) {
  return defineExtension({ name: 'omakase.whole-results', hooks: [hook(ToolTask, {
    afterTool: async (call, result, api, context) => {
      if (OWN_BOUNDS.has(call.name)) return undefined;
      // The model's own read is a page of a file it reads on with offset and limit.
      if (call.name === 'read') return call.parent ? cutRead(call, result) : undefined;
      // A tool with a schema gives a script its value, not this text.
      if (call.parent && result.structuredOutput !== undefined) return undefined;
      const text = textOf(result);
      const bytes = Buffer.byteLength(text), lines = text.split('\n').length;
      if (bytes <= RESULT_MAX_BYTES && lines <= RESULT_MAX_LINES) return undefined;
      const env = await envOf(api, context, call).catch(() => undefined);
      // A call of a script is a call of its own in the call's folder; either way a replay writes the same file again.
      const callId = call.parent ? `${call.parent.callId}/${call.id}` : call.id;
      const saved = await saveText(env, { taskId: call.parent?.taskId ?? api.taskId, callId },
        `${call.name}-result.${isJson(text) ? 'json' : 'txt'}`, text, context);
      const over = `${call.name} returned ${count(bytes)} bytes in ${count(lines)} lines, over ${LIMIT}.`;
      const note = saved.path
        ? `${over} It is saved whole at path on your computer: take what you need from there with bash (jq, grep) or read with offset and limit.`
        : `${over} ${saved.note} Ask for less: one message, one page, or a narrower search.`;
      return replaced(result, { over_limit: true, tool: call.name, bytes, lines, limit_bytes: RESULT_MAX_BYTES,
        path: saved.path ?? null, preview: preview(text), note });
    }
  })] });
}

// `read` bounds a file itself, to Durable's limit, and says so only in a
// diagnostic. A part the script asked for (offset and limit) is not a cut;
// the file is already whole where it was read.
function cutRead(call, result) {
  const cut = !result.isError && (result.diagnostics ?? []).find(diagnostic => diagnostic.code === 'truncated');
  if (!cut) return undefined;
  const { outputBytes, totalBytes } = result.details?.truncation ?? {};
  const text = textOf(result);
  return replaced(result, { over_limit: true, tool: 'read', bytes: totalBytes ?? null, lines: null, limit_bytes: RESULT_MAX_BYTES,
    path: call.arguments?.path ?? null, preview: preview(text),
    note: `read gave only ${count(outputBytes)} of the file's ${count(totalBytes)} bytes, over ${LIMIT}. ${cut.message}` });
}

// The result as one JSON text, its pictures after it; an error stays one.
// Nothing beside it: the note in the JSON says it all, and a diagnostic
// would reach the model as text after the JSON.
function replaced(result, value) {
  const text = JSON.stringify(value);
  return { ...result, output: [{ type: 'text', text }, ...(result.output ?? []).filter(block => block.type !== 'text')],
    // read's value for a script is its text (its schema: a string).
    ...(typeof result.structuredOutput === 'string' ? { structuredOutput: text } : {}),
    // read's own warning of its cut, which the JSON replaces.
    diagnostics: (result.diagnostics ?? []).filter(diagnostic => diagnostic.code !== 'truncated') };
}

function isJson(text) {
  try { JSON.parse(text); return true; } catch { return false; }
}

function preview(text) {
  const start = text.slice(0, PREVIEW_CHARACTERS);
  return /[\uD800-\uDBFF]$/.test(start) ? start.slice(0, -1) : start;
}
