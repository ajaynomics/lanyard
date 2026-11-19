// browser_upload: a file from the agent's home folder into a file field of
// the page visit_website last opened (~/.visit-tab), never a tab of the
// person's own (#115). The screen's browser runs as `browser`,
// which cannot reach the agent's files (#60), and the agent never reaches the
// browser's DevTools; so the file goes through the shared folder,
// ~/browser-files (the agent's, group `browser`, made at boot by
// agent/guest/entrypoint.sh): the agent's own command copies it there, then
// agent/guest/upload.mjs, run as `browser` through the relay, takes its own
// copy and sets the field over CDP (DOM.setFileInputFiles). The browser's
// downloads land in the same folder (its Chromium policy). A screen tool, so
// only an agent whose computer is a Sprite has it, and never its helpers
// (desktop.mjs, runtime.mjs).
import { posix } from 'node:path';
import { randomUUID } from 'node:crypto';
import { defineTool } from '@earendil-works/pi-durable';

const UPLOAD = '/opt/agent/upload.mjs';
export const SHARED_FOLDER = 'browser-files';
const MAX_ANSWER = 64 * 1024;
const textResult = text => ({ output: [{ type: 'text', text }] });
const refused = text => ({ ...textResult(text), isError: true });
// Made with the folder's group, readable by it; a copy keeps the folder's
// group (the folder is set-group-ID) and is made readable by it.
const COPY = 'test -d "$4" || exit 4; umask 027 && mkdir -p "$1" && cp -L -- "$2" "$3" && chmod 0640 "$3"';

export const browserUpload = defineTool({
  name: 'browser_upload',
  description: 'Put a file from your home folder into a file field (<input type=file>) of the page you last opened with visit_website, ' +
    'as choosing it in the page\'s file picker would; the page then has it, and you press its upload or send button with the desktop tool. ' +
    `What the browser downloads lands in ~/${SHARED_FOLDER}.`,
  parameters: { type: 'object', additionalProperties: false, required: ['field', 'path'], properties: {
    field: { type: 'string', minLength: 1, maxLength: 500, description: 'The file field: a CSS selector (#statement) or the text of its label (Statement)' },
    path: { type: 'string', minLength: 1, maxLength: 4096, description: 'The file, in your home folder: a path from it (docs/statement.pdf) or a whole one' } } },
  // Choosing a file again is harmless, but the page may have acted on it.
  replay: 'unsafe',
  // One screen: as desktop and visit_website, one call after another.
  executionMode: 'sequential',
  async execute(args, api, context) {
    const env = api.env;
    if (!env?.id?.startsWith('sprites:') || !env.onScreen) return refused('This agent\'s computer has no screen to upload from.');
    const home = env.cwd;
    const source = posix.resolve(home, String(args.path));
    if (!source.startsWith(`${home}/`)) return refused(`Only a file in your home folder (${home}) can be uploaded.`);
    const shared = `${home}/${SHARED_FOLDER}`;
    const folder = `${shared}/.uploads/${randomUUID()}`;
    const copy = `${folder}/${posix.basename(source)}`;
    const copied = await env.exec(['sh', '-c', COPY, 'sh', folder, source, copy, shared], { timeout: 60 }, context);
    if (copied.ok && copied.value.exitCode === 4) return refused(`This computer was made before browser_upload, so it has no ~/${SHARED_FOLDER}; it must be made again.`);
    if (!copied.ok || copied.value.exitCode !== 0) return refused(`${args.path} could not be copied for the browser: is it a file you can read?`);

    let answer = '';
    const ran = await env.onScreen(['node', UPLOAD], { timeout: 45, env: { AGENT_UPLOAD: JSON.stringify({ field: String(args.field), path: copy }) },
      onOutput: (text, _ctx, info) => { if (info?.stream !== 'stderr' && answer.length < MAX_ANSWER) answer += text; } }, context);
    if (ran === null || (ran.ok && ran.value.exitCode === 3)) return refused('The screen\'s browser is not running; try again in a moment.');
    let reply;
    try { reply = JSON.parse(answer); } catch {}
    if (!reply) return refused('The screen\'s browser did not take the file. A computer made before browser_upload must be made again.');
    if (!reply.ok) return refused(String(reply.error ?? 'The file could not be put in the field.'));
    return textResult(`Put ${reply.name} (${reply.size} bytes) into the file field on ${reply.url}. Press the page's button to send it, with the desktop tool.`);
  }
});
