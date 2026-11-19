import { CHANNEL } from './batches.mjs';

// The out-of-band inbox (#85): a message from someone else that waits for the
// agent's turn to end is announced at the agent's next step, between tool
// calls, so a long turn does not go on blind to it (#96): who sent it, how it
// starts and how many wait, and how to take them in sooner (Rails'
// waiting_messages tool). Its words are untrusted, so only their first line,
// cut short and quoted, is repeated.
const START = 80;

const textOf = content => typeof content === 'string' ? content : content.filter(block => block.type === 'text').map(block => block.text).join('');

function start(text) {
  // Rails' note about a received message ends at its first blank line (Conversation.received).
  const body = CHANNEL.test(text) && text.includes('\n\n') ? text.slice(text.indexOf('\n\n') + 2) : text;
  const line = body.split('\n').map(each => each.trim()).find(Boolean) ?? '';
  return line.length > START ? `${line.slice(0, START - 1)}…` : line;
}

export function waitingNote(content, author, count) {
  const text = textOf(content);
  const channel = text.match(CHANNEL)?.[1] ?? 'A message';
  const from = author?.sender ? ` from ${author.sender}` : '';
  const opening = start(text);
  const one = count === 1;
  return `[Waiting in your inbox: ${channel}${from}${opening ? `, starting "${opening}"` : ''}. ` +
    `${count} ${one ? 'message' : 'messages'} from others ${one ? 'waits' : 'wait'}. ` +
    `${one ? 'It comes' : 'They come'} in when you finish; to read ${one ? 'it' : 'them'} sooner, take ${one ? 'it' : 'them'} in with waiting_messages.]`;
}
