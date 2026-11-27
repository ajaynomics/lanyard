// The desktop tool: the agent sees and uses its screen, the same Chromium
// window the person sees with "Open screen", with the logins made there. Each
// action goes from here through the Sprite's relay (AGENT-DESK) to the desktop
// control server's POST /action (agent/guest/server.js), which checks it and
// answers with a fresh screenshot. The server's bearer stays with the relay
// and the server: nothing the agent runs can read it. Only an agent whose
// computer is a Sprite has it, and never its helpers (runtime.mjs,
// subagent.mjs), so only the agent drives its own screen.
import { defineExtension, defineTool } from '@earendil-works/pi-durable';
import { deskAction } from './computers.mjs';
import { browserUpload } from './browser-upload.mjs';

export const DESKTOP_EXTENSION = 'omakase.desktop';
// A Sprite made before AGENT-DESK keeps its old relay, which closes that
// connection unanswered or reset, and its old /opt/agent/desk.mjs, which reads the
// bearer from the home folder; there the action goes the old way.
const OLD_DESK = '/opt/agent/desk.mjs';
const MAX_ANSWER = 16 * 1024 * 1024;
const integer = description => ({ type: 'integer', description });

export const desktop = defineTool({
  name: 'desktop',
  description: 'See and use your computer\'s screen: a 1280x800 desktop with your browser, which the person can watch and use too. ' +
    'Every action answers with a screenshot. Coordinates are pixels from the top left. Take a screenshot before acting, ' +
    'and after an action whose outcome is unknown, rather than repeating it.',
  parameters: { type: 'object', additionalProperties: false, required: ['action'], properties: {
    action: { type: 'string', enum: ['screenshot', 'click', 'type', 'key', 'scroll', 'drag', 'wait'] },
    x: integer('click, scroll or drag from: 0-1279'), y: integer('click, scroll or drag from: 0-799'),
    x2: integer('drag to: 0-1279'), y2: integer('drag to: 0-799'),
    text: { type: 'string', description: 'type: the text, up to 1024 characters' },
    key: { type: 'string', description: 'key: an xdotool key name; + joins modifiers, e.g. ctrl+l, Return' },
    dx: integer('scroll: clicks right (negative: left), -10 to 10'), dy: integer('scroll: clicks down (negative: up), -10 to 10'),
    ms: integer('wait: milliseconds, up to 20000') } },
  // A click or keystroke repeated after a crash could act twice.
  replay: 'unsafe',
  // One screen: a round with a desktop action runs its calls one after another
  // (as visit_website's does), so a sign-in fill or a page visit never lands
  // between two clicks.
  executionMode: 'sequential',
  async execute(args, api, context) {
    const env = api.env;
    if (!env?.id?.startsWith('sprites:')) throw new Error('This agent\'s computer has no screen.');
    let answer = await deskAction(env.id.slice('sprites:'.length), args, { maxBytes: MAX_ANSWER });
    // No answer, or a failed bridge: an old relay resets the connection about
    // half the time, so both mean "try the old way".
    if (!answer) answer = await oldDesk(env, args, context);
    if (!answer) throw new Error('The screen is not running; try again in a moment.');
    return picture(answer);
  }
});

function picture(answer) {
  const reply = JSON.parse(answer);
  if (!reply.ok) throw new Error(reply.error || 'The screen refused the action.');
  return { output: [
    { type: 'text', text: `${reply.result} (${reply.width}x${reply.height})` },
    { type: 'image', data: reply.image_b64, mimeType: 'image/png' }
  ] };
}

async function oldDesk(env, args, context) {
  let answer = '', bytes = 0;
  const ran = await env.exec(['node', OLD_DESK, JSON.stringify(args)], { timeout: 60,
    onOutput: (text, _ctx, info) => { if (info?.stream === 'stderr' || bytes > MAX_ANSWER) return; bytes += text.length; answer += text; } }, context);
  return ran.ok && ran.value.exitCode === 0 ? answer : null;
}

// browser_upload acts on the same screen, so it goes where desktop goes.
export const desktopExtension = defineExtension({ name: DESKTOP_EXTENSION, tools: [desktop, browserUpload] });

export const RETAINED_DESKTOP_EXTENSION = 'omakase.retained-desktop';
// With the other tools that act on that screen (browser.mjs retainedVisit).
export const retainedDesktop = (targetFor, others = []) => defineExtension({ name: RETAINED_DESKTOP_EXTENSION, tools: [defineTool({
  ...desktop,
  async execute(args, api, context) {
    const name = await targetFor(api, context);
    const answer = await deskAction(name, args, { maxBytes: MAX_ANSWER, existing: true });
    if (!answer) throw new Error('The retained screen is unavailable.');
    return picture(answer);
  }
}), ...others] });
