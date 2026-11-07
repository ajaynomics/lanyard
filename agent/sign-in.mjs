// A saved sign-in, after the person approved it (Rails'
// Tool::SignInWithSavedPassword): the password comes from Rails once
// (POST /agent/sign_ins) and goes straight to agent/guest/fill.mjs on the
// agent's Sprite, in that one command's environment. It is never part of the
// tool's output, an error or a log line: the model reads which fields were
// filled on which page, and nothing else.

const FILL = '/opt/agent/fill.mjs';
const MAX_ANSWER = 64 * 1024;
const textResult = text => ({ output: [{ type: 'text', text }] });
const refused = text => ({ ...textResult(text), isError: true });

export async function fillSignIn(signIn, call, result, api, context) {
  const env = api.env;
  if (!env?.id?.startsWith('sprites:')) return refused('This agent\'s computer has no screen to sign in on.');
  if (typeof signIn !== 'function') return refused('Saved sign-ins are not set up here.');
  let secret;
  try {
    secret = await signIn({ actorId: call.actorId, workspaceId: call.workspaceId, conversationId: call.conversationId,
      taskId: call.taskId, callId: call.callId }, context.abortSignal);
  } catch {
    return refused('The saved sign-in could not be fetched, or was already used. Ask to use it again.');
  }
  if (typeof secret?.host !== 'string' || typeof secret.password !== 'string') return refused('The saved sign-in has no site or password.');
  let answer = '';
  const ran = await env.exec(['node', FILL], { timeout: 45,
    env: { AGENT_SIGN_IN: JSON.stringify({ host: secret.host, username: secret.username ?? '', password: secret.password }) },
    onOutput: (text, _ctx, info) => { if (info?.stream !== 'stderr' && answer.length < MAX_ANSWER) answer += text; } }, context);
  secret = undefined;
  let reply;
  try { reply = JSON.parse(answer); } catch { reply = null; }
  if (!ran.ok || !reply) return refused('The screen\'s browser is not running; open the sign-in page with visit_website, then ask again.');
  if (!reply.ok) return refused(String(reply.error ?? 'The page could not be filled.'));
  const name = result?.signIn ?? 'the saved sign-in';
  return textResult(`Filled the ${reply.filled.join(' and ')} for ${name} on ${reply.url}. ` +
    'Press the page\'s sign-in button with the desktop tool. If the page asks for the password on a next step, ask to use the sign-in again there.');
}
