// Files a Rails tool names by path on the agent's computer (Tool.reads_files
// in Rails, as `files` in its declaration): read here, within the tool's
// limits, and handed to Rails (POST /agent/uploads) before the call itself
// goes, so the person approves, and the tool sends, the very bytes read. The
// bytes never reach the model, the ledger or a log line.

const textResult = text => ({ output: [{ type: 'text', text }] });
const refused = text => ({ ...textResult(text), isError: true });
const megabytes = bytes => `${Math.round(bytes / 1024 / 1024 * 10) / 10} MB`;

// A computer of this app's: a Sprite or an SSH host. Never the sidecar's own
// disk, which holds every conversation and its tokens.
const isComputer = env => /^(sprites|ssh):/.test(env?.id ?? '');

// Undefined when every file went; otherwise the call's result, saying why not.
export async function uploadFiles(upload, call, files, api, context) {
  const paths = call.arguments?.[files.argument] ?? [];
  if (!Array.isArray(paths) || paths.length === 0) return undefined;
  const env = api.env;
  if (!isComputer(env)) return refused('This agent has no computer to attach files from, so nothing was sent.');
  if (typeof upload !== 'function') return refused('Attaching files is not set up here, so nothing was sent.');
  const read = [];
  let total = 0;
  for (const path of paths) {
    const opened = await env.openBinaryReader(path, undefined, context);
    if (!opened.ok) return refused(`${path} ${opened.error?.code === 'is_directory' ? 'is a folder, not a file' : 'could not be read'}, so nothing was sent.`);
    const reader = opened.value;
    try {
      const info = await reader.info(context);
      if (!info.ok || info.value.kind !== 'file') return refused(`${path} is not a file, so nothing was sent.`);
      const size = info.value.size;
      if (size > files.maxBytes) return refused(`${path} is ${megabytes(size)}; a file may be at most ${megabytes(files.maxBytes)}, so nothing was sent.`);
      total += size;
      if (total > files.maxTotalBytes) return refused(`The files come to more than ${megabytes(files.maxTotalBytes)} together, the most one message may carry, so nothing was sent.`);
      const bytes = size === 0 ? { ok: true, value: new Uint8Array() } : await reader.read(0, size, context);
      if (!bytes.ok || bytes.value.length !== size) return refused(`${path} could not be read whole, so nothing was sent.`);
      read.push({ path, bytes: bytes.value });
    } finally {
      await reader.close(context);
    }
  }
  for (const { path, bytes } of read) {
    try {
      await upload({ actorId: call.actorId, workspaceId: call.workspaceId, conversationId: call.conversationId,
        taskId: call.taskId, callId: call.callId, tool: call.tool, path, bytes: Buffer.from(bytes).toString('base64') }, context.abortSignal);
    } catch {
      return refused(`${path} could not be handed over, so nothing was sent. Try again.`);
    }
  }
  return undefined;
}
