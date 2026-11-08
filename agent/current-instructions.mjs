// pi-durable keeps the first system message as it was, for the prompt cache,
// and writes a later change as a system message that Claude takes mid-
// conversation ('Updated system prompt section "instructions"'), tools as
// tool_addition and tool_removal: the cached prefix survives every change.
// That is the default here too: an edit to an agent's instructions, its notes
// or its tools costs only what is appended.
//
// One change is not left to an update: who the agent is. Its first paragraph
// is Rails' (Agent#identity, "Your name is …"), fixed when it is made and
// changed only by "New agent from here", which gives an old thread a new
// agent. A model may trust the old name it reads first over the update, so a
// request whose identity differs from the leading prompt's is sent as pi-ai
// sends it to a model without mid-conversation system messages: one leading
// prompt with every change applied. That costs the whole cache, from then on
// until compaction writes a new baseline, for that thread alone.
export const INSTRUCTIONS = 'instructions';

const identity = instructions => instructions.split('\n\n', 1)[0];

export function changesIdentity(messages) {
  const instructions = messages.filter(message => message.role === 'system' && typeof message.sections?.[INSTRUCTIONS] === 'string')
    .map(message => message.sections[INSTRUCTIONS]);
  return instructions.length > 1 && identity(instructions[0]) !== identity(instructions.at(-1));
}

export function currentInstructions(provider) {
  const model = (chosen, context) => changesIdentity(context?.messages ?? [])
    ? { ...chosen, compat: { ...chosen.compat, supportsMidConvoSystemMessages: false } } : chosen;
  return { ...provider,
    stream: (chosen, context, options) => provider.stream(model(chosen, context), context, options),
    streamSimple: (chosen, context, options) => provider.streamSimple(model(chosen, context), context, options) };
}
