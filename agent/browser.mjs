// visit_website: a real browser on the agent's computer, returning the page's
// title, its text and a screenshot the model can see. On a Sprite it shows the
// page in a tab of the screen's Chromium, in front, over CDP
// (agent/guest/visit.mjs), so the logins made there apply and the person sees
// the page; where there is no
// screen (a local computer, or the screen's browser not running) headless
// Chromium loads the page instead. It comes with the computer and never
// without one.
import { obj, str } from '@earendil-works/pi-schema';
import { defineExtension, defineTool } from '@earendil-works/pi-durable';

const TIMEOUT_SECONDS = 45;
// visit.mjs on the screen: up to 10 s to choose its tab, then 40 for the page.
const SCREEN_SECONDS = 55;
const MAX_TEXT = 6000;
const MAX_DOM_BYTES = 4 * 1024 * 1024;
const BROWSERS = ['chromium', 'chromium-browser', 'google-chrome'];
const VISIT = '/opt/agent/visit.mjs';
const MAX_SCREEN_ANSWER = 16 * 1024 * 1024;

// The page in the screen's browser, or null when there is no screen to use.
// Only a screen that is not there falls back to headless Chromium: one that
// failed or ran out of time is an error, never a headless page the screen
// does not show, since the sign-in and card fillers act on the screen's tab.
// It runs as `browser`, the only user that can reach the screen's DevTools
// (env.onScreen, #60); on a Sprite made before that, as the agent. Its error
// says why, from visit.mjs's last line of stderr, which carries no typed value
// (fill.mjs, which does, runs through sign-in.mjs instead).
async function onScreen(env, url, context) {
  let answer = '', bytes = 0, errors = '';
  const options = { timeout: SCREEN_SECONDS,
    onOutput: (text, _ctx, info) => {
      if (info?.stream === 'stderr') errors = (errors + text).slice(-4096);
      else if (bytes <= MAX_SCREEN_ANSWER) { bytes += text.length; answer += text; }
    } };
  const ran = (await env.onScreen?.(['node', VISIT, url], options, context)) ?? await env.exec?.(['node', VISIT, url], options, context);
  if (!ran) return null;
  if (ran.ok ? [3, 127].includes(ran.value.exitCode) : ran.error?.code === 'spawn_error') return null;
  // The screen's own reasons (computers.mjs screenScript) are already worded for the agent.
  if (['screen_not_ready', 'screen_too_old'].includes(ran.error?.code)) throw new Error(ran.error.message);
  if (!ran.ok || ran.value.exitCode !== 0) {
    const why = ran.ok ? `exit ${ran.value.exitCode}` : ran.error?.code === 'timeout' ? `timed out after ${SCREEN_SECONDS} s` : ran.error?.code ?? 'failed';
    // visit.mjs words its own error as this one is, so only its reason is kept.
    const line = errors.trim().split('\n').at(-1).trim();
    const said = line.match(/^The browser could not open \S+ \((.*)\)\.?$/)?.[1] ?? line;
    const reason = said ? `${why}: ${said}` : why;
    throw new Error(`The browser could not open ${url} (${reason.length > 200 ? `${reason.slice(0, 200)}…` : reason})`);
  }
  const { title, text, screenshot } = JSON.parse(answer);
  return { output: [
    { type: 'text', text: `Visited ${url}\nTitle: ${title || '(none)'}\n\n${text || '(no text found on the page)'}` },
    { type: 'image', data: screenshot, mimeType: 'image/jpeg' }
  ] };
}

// Public web pages only. The computer shares networks with this app's own
// services, so loopback, private and link-local addresses, bare (single
// label) host names and IP literals outside the public ranges are refused. A
// public name that resolves to a private address is not caught here.
export function publicUrl(input) {
  let url;
  try { url = new URL(String(input).trim()); } catch { throw new Error('That is not a web address.'); }
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('Only http and https addresses can be visited.');
  if (url.username || url.password) throw new Error('Addresses with a user name or password are not visited.');
  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  if (host.startsWith('[')) throw new Error('IP addresses are not visited; use a public name.');
  const ipv4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) {
    const [a, b] = ipv4.slice(1, 3).map(Number);
    const internal = a === 0 || a === 10 || a === 127 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || a >= 224;
    if (internal) throw new Error('Private and local addresses are not visited.');
  } else if (!host.includes('.') || /(^|\.)(localhost|local|internal|lan|home|arpa)$/.test(host)) {
    throw new Error('Private and local addresses are not visited.');
  }
  return url.href;
}

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', '#39': "'" };
export function pageText(html) {
  const title = (html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1] ?? '').replace(/\s+/g, ' ').trim();
  const body = html.replace(/<(script|style|noscript|svg|template|head|title)\b[\s\S]*?<\/\1>/gi, ' ')
    .replace(/<\/(p|div|li|h[1-6]|tr|br|section|article|header|footer)>/gi, '\n').replace(/<br\s*\/?>/gi, '\n')
    .replace(/<[^>]+>/g, ' ').replace(/&(#?\w+);/g, (match, name) => ENTITIES[name.toLowerCase()] ?? match)
    .replace(/[ \t\f\v\r]+/g, ' ').replace(/\n\s*/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  return { title: decode(title), text: body.length > MAX_TEXT ? `${body.slice(0, MAX_TEXT)}…` : body };
}
const decode = text => text.replace(/&(#?\w+);/g, (match, name) => ENTITIES[name.toLowerCase()] ?? match);

export const visitWebsite = defineTool({
  name: 'visit_website',
  description: 'Open a public web page in a real browser on your computer: your screen\'s browser (a tab of its own for each site, brought to the front), where your logins apply, or headless Chromium when there is no screen. Returns the page title, the text on the page and a screenshot you can look at. Use it to look something up on a site or to check how a page looks.',
  parameters: obj({ url: str({ description: 'The full http or https address to open' }) }),
  // Loading a page again is harmless, so a crash mid-visit simply visits again.
  replay: 'safe',
  // Every visit shares one tab, so a round of visits runs one after another.
  executionMode: 'sequential',
  async execute(args, api, context) {
    const url = publicUrl(args.url);
    const env = api.env;
    if (!env) throw new Error('This agent has no computer turned on.');
    if (env.id?.startsWith('sprites:')) {
      const visited = await onScreen(env, url, context);
      if (visited) return visited;
    }
    const dir = `${env.cwd}/.browser`;
    const made = await env.createDir(`${dir}/profile`, { recursive: true }, context);
    if (!made.ok) throw made.error;
    const shot = `${dir}/screenshot.jpeg`;
    const flags = ['--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--hide-scrollbars',
      '--no-first-run', '--no-default-browser-check', '--mute-audio', `--user-data-dir=${dir}/profile`, '--window-size=1280,800',
      '--virtual-time-budget=4000', '--timeout=30000'];
    // The first browser the computer has: Debian names it chromium, Ubuntu
    // chromium-browser, Google's package google-chrome.
    let pictured, chromium;
    for (const program of BROWSERS) {
      chromium = [program, ...flags];
      pictured = await env.exec([...chromium, `--screenshot=${shot}`, url], { timeout: TIMEOUT_SECONDS }, context);
      if (pictured.ok || pictured.error.code !== 'spawn_error') break;
    }
    if (!pictured.ok) throw new Error(`The browser could not start: ${pictured.error.message}`);
    if (pictured.value.exitCode !== 0) throw new Error(`The browser could not open ${url}.`);
    let html = '', bytes = 0;
    const dumped = await env.exec([...chromium, '--dump-dom', url], { timeout: TIMEOUT_SECONDS,
      onOutput: (text, _ctx, info) => { if (info?.stream === 'stderr' || bytes > MAX_DOM_BYTES) return; bytes += text.length; html += text; } }, context);
    const image = await env.readBinaryFile(shot, context);
    if (!image.ok) throw new Error(`The browser opened ${url} but took no screenshot.`);
    const { title, text } = dumped.ok ? pageText(html) : { title: '', text: '' };
    return { output: [
      { type: 'text', text: `Visited ${url}\nTitle: ${title || '(none)'}\n\n${text || '(no text found on the page)'}` },
      { type: 'image', data: Buffer.from(image.value).toString('base64'), mimeType: 'image/jpeg' }
    ] };
  }
});

export const browserExtension = defineExtension({ name: 'omakase.browser', tools: [visitWebsite] });

// On a retained browser (runtime.mjs), the page opens on the existing Sprite
// its desktop shows, where a fill finds it; never headless, never elsewhere.
export const retainedVisit = screenFor => defineTool({
  ...visitWebsite,
  async execute(args, api, context) {
    const url = publicUrl(args.url);
    const screen = await screenFor(api, context);
    const visited = screen && await onScreen(screen, url, context);
    if (!visited) throw new Error('The retained screen is unavailable.');
    return visited;
  }
});
