// An agent's instructions, changed in Rails, replace its system prompt from
// the next message (Rails' settings page promises it).
//
// pi-durable keeps the first system message as it was, for the prompt cache,
// and writes a change as a later system message; a model that takes system
// messages mid-conversation reads it there as 'Updated system prompt section
// "instructions"', under the old prompt it still sees first. A model may
// trust the first over the update ("You are Durable Assistants" over the new
// name), so a request whose history carries an instructions change is sent
// as pi-ai sends it to a model without mid-conversation system messages: one
// leading prompt with every change applied. The cache is spent once; the
// leading prompt is stable after, until compaction writes a new baseline.
// Other changes (tools a connector loads) keep the mid-conversation path.
export const INSTRUCTIONS = 'instructions';

export function changesInstructions(messages) {
  return messages.some((message, index) => index > 0 && message.role === 'system' &&
    Object.hasOwn(message.sections ?? {}, INSTRUCTIONS));
}

export function currentInstructions(provider) {
  const model = (chosen, context) => changesInstructions(context?.messages ?? [])
    ? { ...chosen, compat: { ...chosen.compat, supportsMidConvoSystemMessages: false } } : chosen;
  return { ...provider,
    stream: (chosen, context, options) => provider.stream(model(chosen, context), context, options),
    streamSimple: (chosen, context, options) => provider.streamSimple(model(chosen, context), context, options) };
}
