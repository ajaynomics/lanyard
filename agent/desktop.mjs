// The desktop tool: the agent sees and uses its screen, the same Chromium
// window the person sees with "Open screen", with the logins made there. Each
// action goes to the desktop control server on the agent's Sprite
// (agent/guest/desk.mjs, then server.js's POST /action), which checks it and
// answers with a fresh screenshot. Only an agent whose computer is a Sprite
// has it, and never its helpers (runtime.mjs, subagent.mjs), so only the
// agent drives its own screen.
import { defineExtension, defineTool } from '@earendil-works/pi-durable';

export const DESKTOP_EXTENSION = 'omakase.desktop';
const DESK = '/opt/avery/desk.mjs';
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
  async execute(args, api, context) {
    const env = api.env;
    if (!env?.id?.startsWith('sprites:')) throw new Error('This agent\'s computer has no screen.');
    let answer = '', bytes = 0;
    const ran = await env.exec(['node', DESK, JSON.stringify(args)], { timeout: 60,
      onOutput: (text, _ctx, info) => { if (info?.stream === 'stderr' || bytes > MAX_ANSWER) return; bytes += text.length; answer += text; } }, context);
    if (!ran.ok || ran.value.exitCode !== 0) throw new Error('The screen is not running; try again in a moment.');
    const reply = JSON.parse(answer);
    if (!reply.ok) throw new Error(reply.error || 'The screen refused the action.');
    return { output: [
      { type: 'text', text: `${reply.result} (${reply.width}x${reply.height})` },
      { type: 'image', data: reply.image_b64, mimeType: 'image/png' }
    ] };
  }
});

export const desktopExtension = defineExtension({ name: DESKTOP_EXTENSION, tools: [desktop] });
