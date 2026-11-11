// An approved payment (Rails' Tool::PayByCard): its one-time card comes from
// Rails once (POST /agent/cards), which asks Link for it then, and goes
// straight to agent/guest/pay.mjs on the agent's Sprite, in that one
// command's environment. It is never part of the tool's output, an error or
// a log line: the model reads which fields were filled on which page, and the
// card's brand and last four digits that Rails already gave it.

const PAY = '/opt/agent/pay.mjs';
const MAX_ANSWER = 64 * 1024;
const textResult = text => ({ output: [{ type: 'text', text }] });
const refused = text => ({ ...textResult(text), isError: true });

export async function fillCard(card, call, result, api, context) {
  const env = api.env;
  if (!env?.id?.startsWith('sprites:')) return refused('This agent\'s computer has no screen to pay on.');
  if (typeof card !== 'function') return refused('Payments are not set up here.');
  let secret;
  try {
    secret = await card({ actorId: call.actorId, workspaceId: call.workspaceId, conversationId: call.conversationId,
      taskId: call.taskId, callId: call.callId }, context.abortSignal);
  } catch {
    return refused('The card could not be fetched, or was already typed in once. Ask to pay again; the person approves it again.');
  }
  if (typeof secret?.site !== 'string' || typeof secret.number !== 'string') return refused('Link gave no card for this payment.');
  let answer = '';
  const ran = await env.exec(['node', PAY], { timeout: 45,
    env: { AGENT_CARD: JSON.stringify({ site: secret.site, number: secret.number, cvc: secret.cvc ?? '', expMonth: secret.exp_month,
      expYear: secret.exp_year, name: secret.name ?? '', postalCode: secret.postal_code ?? '' }) },
    onOutput: (text, _ctx, info) => { if (info?.stream !== 'stderr' && answer.length < MAX_ANSWER) answer += text; } }, context);
  secret = undefined;
  let reply;
  try { reply = JSON.parse(answer); } catch { reply = null; }
  const card_ = result?.card ?? 'the card';
  if (!ran.ok || !reply) return refused('The screen\'s browser is not running; open the checkout page with visit_website, then ask to pay again.');
  if (!reply.ok) return refused(`${String(reply.error ?? 'The checkout could not be filled.')} The card was not typed in; ask to pay again once the checkout page is open.`);
  return textResult(`Typed ${card_} (${reply.filled.join(', ')}) into the checkout on ${reply.url}, for ${result?.paying ?? 'the approved amount'}. ` +
    'Check the total, then press the page\'s pay button with the desktop tool. The card works once, for that amount.');
}
