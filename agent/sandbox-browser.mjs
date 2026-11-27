// A sandboxed agent's own browser on the host, with no desktop. Its SSH
// computer asks the host's act helper, /run/agent-browser/<name>/act.sock, for
// one of a fixed set of actions: never a DevTools call or a script, and
// nothing read back while a password box has focus. The sidecar alone fills a
// saved sign-in, through fill.sock (fill-socket.mjs).
import { join } from 'node:path';
import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { obj, opt, str } from '@earendil-works/pi-schema';
import { publicUrl } from './browser.mjs';
import { BROWSERS, NAME } from './fill-socket.mjs';

// One request over the socket, with Node's built-ins on the SSH computer.
const ACT = `import { request } from 'node:http';
const [socketPath, method, path, body] = JSON.parse(process.argv[1]);
const asked = request({ socketPath, method, path, headers: { Host: 'localhost', 'Content-Type': 'application/json' }, timeout: 40000 }, answer => {
  let text = '';
  answer.setEncoding('utf8').on('data', part => { text += part; })
    .on('end', () => process.stdout.write(JSON.stringify({ status: answer.statusCode, text })));
});
asked.on('timeout', () => asked.destroy()).on('error', () => process.exit(3)).end(body && JSON.stringify(body));
`;
const MAX_ANSWER = 64 * 1024;

async function act(env, socket, method, path, body, context) {
  let out = '', long = false;
  const ran = await env.exec(['node', '--input-type=module', '-e', ACT, JSON.stringify([socket, method, path, body])], {
    timeout: 45, onOutput: (text, _ctx, info) => {
      if (info?.stream === 'stderr' || long) return;
      if (out.length + text.length > MAX_ANSWER) { long = true; out = ''; return; }
      out += text;
    }
  }, context);
  if (!ran.ok || ran.value.exitCode !== 0 || long) return null;
  try {
    const { status, text } = JSON.parse(out);
    return { status, value: JSON.parse(text) };
  } catch { return null; }
}

// A page's address can carry a session or a one-time code; the model never sees one.
const shown = address => {
  try {
    const url = new URL(address);
    return ['http:', 'https:'].includes(url.protocol) ? `${url.origin}${url.pathname}` : url.protocol;
  } catch { return 'an address that could not be read'; }
};

const text = (words, isError = false) => ({ output: [{ type: 'text', text: words }], ...(isError ? { isError } : {}) });
const UNREACHABLE = 'Your sandbox browser could not be reached. Nothing else was tried, and no other browser was used.';

function refusal(reply) {
  if (!reply) return text(UNREACHABLE, true);
  if (reply.status === 403) return text('Your browser refused: you can\'t read or type in a password box. ' +
    'sign_in_with_saved_password is the only way to fill one.', true);
  if (reply.status === 404) return text('Your browser does not offer that action. Nothing was done.', true);
  const why = typeof reply.value?.error === 'string' ? ` (${reply.value.error.slice(0, 200)})` : '';
  return text(`Your browser refused that${why}. Nothing was done.`, true);
}

// The tool is given only when Rails grants this conversation the browser (targetFor).
export function sandboxBrowser(targetFor, { root = BROWSERS } = {}) {
  const visit = defineTool({
    name: 'visit_website',
    description: 'Open an HTTPS page in your sandbox browser. Returns its address, without any query, and its title; not its text or a picture. ' +
      'After sign_in_with_saved_password fills a sign-in, call with action "submit" and no url to send that form.',
    parameters: obj({ url: opt(str({ description: 'The full HTTPS address to open' })), action: opt(str({ description: '"open" (default) or "submit"' })) }),
    executionMode: 'sequential', replay: 'unsafe',
    async execute(args, api, context) {
      const submit = args.action === 'submit';
      if (Object.keys(args).some(key => !['action', 'url'].includes(key)) ||
          !(submit ? args.url === undefined : (args.action ?? 'open') === 'open' && typeof args.url === 'string'))
        throw new Error('Pass an HTTPS address to open, or action "submit" without a url.');
      const url = submit ? null : new URL(publicUrl(args.url));
      if (url && url.protocol !== 'https:') throw new Error('Open an HTTPS address in the sandbox browser.');
      const target = await targetFor(api, context).catch(() => null);
      if (!NAME.test(target?.name ?? '') || !target.env?.id?.startsWith('ssh:')) return text(UNREACHABLE, true);
      const socket = join(root, target.name, 'act.sock');
      const reply = submit ? await act(target.env, socket, 'POST', '/submit', {}, context) :
        await act(target.env, socket, 'POST', '/open', { url: url.href }, context);
      if (reply?.status !== 200) return refusal(reply);
      if (submit) return text(reply.value?.submitted === 'form' ? 'Sent the form that has focus. Open a page to see where it went.' :
        'No form had focus, so Enter was pressed instead. Open a page to see what happened.');
      const title = typeof reply.value?.title === 'string' ? reply.value.title.slice(0, 200) : '';
      return text(`Opened ${shown(reply.value?.url)}${title ? ` ("${title}")` : ''} in your sandbox browser.`);
    }
  });
  return { visit, extension: defineExtension({ name: 'omakase.sandbox-browser', tools: [visit] }) };
}
