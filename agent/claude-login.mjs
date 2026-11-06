// Signs the sidecar in to a Claude subscription, once (claude-subscription.mjs).
//
//   CLAUDE_SUBSCRIPTION_FILE=/rails/storage/agent/claude-subscription.json node claude-login.mjs
//
// pi-ai's own "copy code" sign-in, as `/login anthropic` offers it headless:
// this prints a claude.ai address; whoever owns the subscription opens it,
// approves, and pastes the code Anthropic shows back here. The code is single
// use and worthless without the verifier this process holds. The running
// sidecar reads the file on its next request; no restart.
import { createInterface } from 'node:readline';
import { isAbsolute } from 'node:path';
import { subscriptionProvider, fileCredentials } from './claude-subscription.mjs';

const path = process.env.CLAUDE_SUBSCRIPTION_FILE;
if (!path || !isAbsolute(path)) { console.error('Set CLAUDE_SUBSCRIPTION_FILE to an absolute path.'); process.exit(1); }

const lines = createInterface({ input: process.stdin })[Symbol.asyncIterator]();
const interaction = {
  signal: AbortSignal.timeout(15 * 60 * 1000),
  notify(event) {
    if (event.type === 'auth_url') console.log(`Open this address, sign in to Claude and approve:\n\n${event.url}\n`);
    else if (event.message) console.log(event.message);
  },
  async prompt(prompt) {
    if (prompt.type === 'select') return 'copy_code';
    console.log(`${prompt.message}`);
    const { value, done } = await lines.next();
    if (done) throw new Error('No code was pasted.');
    return value.trim();
  }
};

try {
  const credential = await subscriptionProvider().auth.oauth.login(interaction);
  await fileCredentials(path).modify('anthropic', async () => ({ ...credential, type: 'oauth' }));
  console.log(`Signed in. The sidecar uses this subscription from its next request (${path}).`);
  process.exit(0);
} catch (error) {
  // pi-ai's messages can include the token endpoint's reply; show only the start.
  console.error(`Sign-in failed: ${String(error.message).split(';')[0]}`);
  process.exit(1);
}
