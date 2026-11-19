// A saved sign-in, after the person approved it (Rails'
// Tool::SignInWithSavedPassword): the password comes from Rails once
// (POST /agent/sign_ins) and goes straight to agent/guest/fill.mjs on the
// agent's Sprite, in that one command's environment, with the entry's account
// number when it has one. Neither is ever part of the tool's output, an error
// or a log line: the model reads which fields were filled on which page, and
// nothing else. A security question's step works the same way with the
// answers saved with the sign-in (agent/guest/answer.mjs): the model reads
// whether it was answered, or the page's question when no saved one is the
// same. Given password boxes the agent named (Rails' passwordFields), only
// those get the password: a new password and the box that confirms it.

import { readFileSync } from 'node:fs';

const FILL = '/opt/agent/fill.mjs';
// In the image since #60; sent with the call to a computer made before it.
const ANSWER_SCRIPT = '/opt/agent/answer.mjs';
const ANSWER = readFileSync(new URL('./guest/answer.mjs', import.meta.url), 'utf8');
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
  if (typeof secret?.host !== 'string' || !secret.host) return refused('The saved sign-in has no site: its web address in the password manager is missing or unreadable.');
  const name = result?.signIn ?? 'the saved sign-in';
  if (result?.step === 'security_question') return answerQuestion(env, secret, context);
  if (typeof secret.password !== 'string' || !secret.password) return refused('The saved sign-in has no password in the password manager.');
  if (Array.isArray(result?.passwordFields)) return fillBoxes(env, secret, result.passwordFields, name, context);
  // A site's separate account box (an account or customer number) is filled
  // from the entry too, when it has one, and goes the same way as the password.
  const account = typeof secret.account === 'string' && secret.account ? { account: secret.account } : {};
  const reply = await run(env, ['node', FILL], { host: secret.host, username: secret.username ?? '', password: secret.password, ...account }, context);
  secret = undefined;
  if (!reply) return refused('The screen\'s browser is not running; open the sign-in page with visit_website, then ask again.');
  if (!reply.ok) return refused(String(reply.error ?? 'The page could not be filled.'));
  // A fill.mjs from an image before the account says neither that it filled
  // one nor that none was needed: the computer must be made again for it.
  const older = account.account && !reply.filled?.includes('account') && !reply.accountUnused;
  const unused = reply.accountUnused ? ' The page has no box for the saved account number, so it was not needed.' :
    older ? ' This computer was made before saved account numbers could be filled, so any account box on the page is still empty: ' +
      'type it with the desktop tool, or have the computer made again.' : '';
  return textResult(`Filled the ${listed(reply.filled)} for ${name} on ${reply.url}.${unused} ` +
    'Press the page\'s sign-in button with the desktop tool. If the page asks for the password on a next step, ask to use the sign-in again there.');
}

async function fillBoxes(env, secret, selectors, name, context) {
  const reply = await run(env, ['node', FILL], { host: secret.host, boxes: { selectors, password: secret.password } }, context);
  secret = undefined;
  if (!reply) return refused('The screen\'s browser is not running; open the page with visit_website, then ask again.');
  // A fill.mjs from before named boxes reads no password from them and stops.
  if (!reply.ok && reply.error === 'No sign-in was given.') return refused('This computer was made before password boxes could be named, ' +
    'so nothing was filled: have the computer made again.');
  if (!reply.ok) return refused(String(reply.error ?? 'The page could not be filled.'));
  return textResult(`Filled the ${listed(reply.filled)} for ${name} on ${reply.url}. Press the page's own button with the desktop tool.`);
}

const listed = names => names.length > 1 ? `${names.slice(0, -1).join(', ')} and ${names.at(-1)}` : names.join('');

async function answerQuestion(env, secret, context) {
  const answers = Array.isArray(secret.answers) ? secret.answers : [];
  const reply = await run(env, ['node', ANSWER_SCRIPT], { host: secret.host, answers }, context, ['node', '--input-type=module', '-e', ANSWER]);
  secret = undefined;
  if (!reply) return refused('The screen\'s browser is not running; open the page with visit_website, then ask again.');
  if (reply.ok) return textResult(reply.sent ? 'Answered, and sent.' : 'Answered. Press the page\'s button with the desktop tool.');
  if ('question' in reply) {
    const asked = typeof reply.question === 'string' ? reply.question.trim().slice(0, 300) : '';
    return refused(`No stored answer for: ${asked || '(no question was found on the page)'}. Nothing was filled; ask the person for the answer.`);
  }
  return refused(String(reply.error ?? 'The page could not be filled.'));
}

// One command on the Sprite with the sign-in in its environment alone; its
// one line of JSON, or null when it did not run. It runs as `browser`
// (env.onScreen, #60), so the sign-in passes through no process of the
// agent's; on a Sprite made before that, through the agent's exec, as `oldArgv`.
async function run(env, argv, signIn, context, oldArgv = argv) {
  let answer = '';
  const options = { timeout: 45, env: { AGENT_SIGN_IN: JSON.stringify(signIn) },
    onOutput: (text, _ctx, info) => { if (info?.stream !== 'stderr' && answer.length < MAX_ANSWER) answer += text; } };
  const ran = (await env.onScreen?.(argv, options, context)) ?? await env.exec(oldArgv, options, context);
  try { return ran.ok ? JSON.parse(answer) : null; } catch { return null; }
}
