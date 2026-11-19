import { defineExtension, hook, GenerationTask } from '@earendil-works/pi-durable';

// Messages that piled up while the agent worked go in at one boundary (the
// harness takes every waiting steer at a step's end, and every waiting
// message when a turn would end), and the first of them says how many there
// are and from whom, so the model reads them as one batch rather than
// answering each as if it were the only one (#85).
//
// The words are for the model alone, added to each request rather than
// stored: the thread keeps each message as it was sent. A boundary places its
// messages with one timestamp, so consecutive user messages sharing one are a
// batch, and the same history always gets the same words: the cached prefix
// holds from one request to the next.

// Rails marks a channel's message "[<channel> from <sender>." (Conversation.received);
// the person's own words carry no such mark.
export const CHANNEL = /^\[([A-Z][A-Za-z]*(?: [A-Za-z]+){0,2}) from /;
const PERSON = 'from the person you work for';

const textOf = content => typeof content === 'string' ? content : (content.find(block => block.type === 'text')?.text ?? '');

export function batchHeader(messages) {
  const counts = new Map([[PERSON, 0]]);
  for (const { content } of messages) {
    const channel = textOf(content).match(CHANNEL)?.[1] ?? PERSON;
    counts.set(channel, (counts.get(channel) ?? 0) + 1);
  }
  const parts = [...counts].filter(([, count]) => count > 0).map(([from, count]) => `${count} ${from}`);
  return `[${messages.length} new messages, in order: ${parts.join(', ')}.]`;
}

const headed = (message, header) => ({ ...message, content: typeof message.content === 'string'
  ? `${header}\n\n${message.content}` : [{ type: 'text', text: header }, ...message.content] });

export function withBatchHeaders(messages) {
  const result = [...messages];
  for (let start = 0; start < result.length;) {
    let end = start + 1;
    if (result[start].role === 'user')
      while (end < result.length && result[end].role === 'user' && result[end].timestamp === result[start].timestamp) end++;
    if (end - start > 1) result[start] = headed(result[start], batchHeader(result.slice(start, end)));
    start = end;
  }
  return result;
}

export const batchesExtension = () => defineExtension({ name: 'omakase.batches', hooks: [hook(GenerationTask, {
  beforeRequest: request => ({ messages: withBatchHeaders(request.messages) })
})] });
