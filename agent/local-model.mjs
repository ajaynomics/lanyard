import { createModels, createProvider } from '@earendil-works/pi-ai/models';
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from '@earendil-works/pi-ai/providers/faux';

// local/avery-local: a scripted stand-in model for development, offered only
// with modelMode 'local'. It costs nothing and calls no one. It streams a
// reply, and understands a few plain commands so every Rails tool, approval
// and question can be tried by hand:
//
//   remember <key>: <text>   forget <key>   notes [words]   ask   time
//   run <command>   visit <url>   (only when the bot has a computer)
//
// It is not an AI and says so.
const HELP = 'Try: “remember dentist: Tuesday 3pm”, “notes”, “forget dentist”, “ask”, “time”, or, with a computer, “run ls” or “visit example.com”.';

const textOf = message => typeof message?.content === 'string' ? message.content :
  (message?.content ?? []).filter(block => block.type === 'text').map(block => block.text).join('');

// The tools the request offers: every system message's additions and removals, in order.
function offeredTools(messages) {
  const offered = new Set();
  for (const message of messages) {
    if (message.role !== 'system') continue;
    for (const tool of message.toolsAdded ?? []) offered.add(tool.name);
    for (const tool of message.toolsRemoved ?? []) offered.delete(typeof tool === 'string' ? tool : tool.name);
  }
  return offered;
}

export function reply(messages) {
  const last = messages.filter(message => message.role !== 'system').at(-1);
  if (last?.role === 'toolResult') {
    const text = textOf(last).slice(0, 600);
    return fauxAssistantMessage(last.isError ? `That did not work: ${text}` : `Done. ${last.toolName} returned: ${text}`);
  }
  const said = textOf(last).trim();
  const offered = offeredTools(messages);
  const use = (name, args) => offered.has(name) ? fauxAssistantMessage([fauxText(`Using ${name}.`), fauxToolCall(name, args)], { stopReason: 'toolUse' }) :
    fauxAssistantMessage(['bash', 'visit_website'].includes(name) ? 'This bot has no computer turned on, so it cannot do that.' : `This bot does not have the ${name} tool turned on.`);
  let match;
  if ((match = said.match(/^remember\s+([A-Za-z0-9_.-]{1,64})\s*:\s*([\s\S]+)$/i))) return use('remember_note', { key: match[1], body: match[2].trim() });
  if ((match = said.match(/^forget\s+([A-Za-z0-9_.-]{1,64})$/i))) return use('forget_note', { key: match[1] });
  if ((match = said.match(/^(?:list\s+)?notes(?:\s+(.+))?$/i))) return use('list_notes', match[1] ? { query: match[1] } : {});
  if (/^ask\b/i.test(said)) return use('ask_person', { question: 'Tea or coffee?', options: ['Tea', 'Coffee'] });
  if (/^(?:what(?:'s| is) the )?time\b/i.test(said)) return use('current_time', {});
  if ((match = said.match(/^run\s+([\s\S]{1,2000})$/i))) return use('bash', { command: match[1] });
  if ((match = said.match(/^visit\s+(\S{1,2000})$/i))) return use('visit_website', { url: /^https?:\/\//i.test(match[1]) ? match[1] : `https://${match[1]}` });
  return fauxAssistantMessage(`I am the local stand-in model, not an AI, so I can only echo: “${said.slice(0, 400)}”. ${HELP}`);
}

export function localProvider({ tokensPerSecond = 80 } = {}) {
  const core = createFauxCore({ provider: 'local', models: [{ id: 'avery-local', name: 'Local stand-in (no AI)', reasoning: true,
    contextWindow: 200000, maxTokens: 8192 }], tokensPerSecond });
  // Every request gets a fresh scripted reply computed from its own context.
  const answer = method => (model, context, options) => {
    core.appendResponses([request => reply(request.messages)]);
    return core[method](model, context, options);
  };
  return createProvider({ id: 'local', auth: { apiKey: { name: 'Local', resolve: async () => ({ auth: {} }) } }, models: core.models,
    api: { stream: answer('stream'), streamSimple: answer('streamSimple') } });
}

// A models catalogue with only the local stand-in, for tests and tools.
export function localModels(options) {
  const models = createModels();
  models.setProvider(localProvider(options));
  return models;
}
