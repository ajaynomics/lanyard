// Run by bin/check-computer-image inside a running agent computer image, as
// `browser` (it drives the screen's DevTools, which only that user reaches,
// #60), with `const CHECK = {secret, key, cert}` put before it. It stands in
// for the sidecar's bridge, dialling the relay on 127.0.0.1:$PORT with the
// relay's secret (which the check made, so the agent learns nothing here), and
// asks of the image as built:
//
// - users: every process runs as its intended user: the desktop server as
//   `desk`, the relay as `relay`, the supervisor (and its sleeps) as root,
//   Chromium, its DevTools (cdp.mjs) and the screen's scripts' spawner as
//   `browser`; everything else (screen, spawner, daemon, shell, connectors)
//   as `agent`;
// - leaks: a command the relay starts, as the agent's shell would be, reads
//   neither the desktop's bearer nor the relay's secret;
// - document tools: as `agent`, everything an agent checks a document with
//   runs from the image (a Sprite made again keeps nothing added by hand),
//   and unzip opens a ZIP64 archive, which BusyBox's applet cannot;
// - typed text: in no process's arguments while it is typed;
// - the screen: a screenshot through AGENT-DESK; commands run, with their exit
//   code; visit.mjs shows a local https page as a tab in front of the screen's
//   one window, on top with the keyboard, never navigating the person's tab on
//   the same site, and finds its tab again after the browser restarts;
//   fill.mjs fills its sign-in, through the relay's AGENT-BROWSER as
//   `browser`, and the page filled is the one in front;
// - popups: a click on a button calling window.open, at once or six seconds
//   later, opens a tab in front, which ctrl+w closes (the image's Chromium policy);
// - files: a download lands in ~/browser-files (agent, group browser, 2770),
//   and upload.mjs puts a file the agent copied there into a page's file
//   field, refusing a link the agent planted;
// - fillers (#60): code running as `agent` finds the password neither in any
//   process's environment or arguments while it is filled nor, afterwards,
//   through the browser's debugging port; and the screen's spawner runs
//   nothing but its scripts;
// - saved passwords (the image's Chromium policy): chrome://policy shows the
//   password manager, its leak check and Autofill for cards and addresses
//   off and the pages showing saved passwords, cards and addresses blocked,
//   each mandatory and OK (not deprecated); a password or card filled and
//   sent brings no "Save?" bubble or icon; each of those pages, and all of
//   Settings, is blocked, opened or reached through Chromium's own menu; and
//   chrome://policy still opens.
//
// Prints one line per finding, then `ok` or the failures; exits 1 on any.
import { connect } from 'node:net';
import { createServer } from 'node:https';
import { createServer as createPlainServer } from 'node:http';
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, mkdirSync } from 'node:fs';

const PORT = 8080;
// DevTools, under its token (agent/guest/cdp.mjs); this check runs as `browser`.
const CDP = `http://127.0.0.1:9222/${readFileSync('/run/browser/cdp-token', 'utf8').trim()}`;
const failures = [];
const check = (ok, what, detail = '') => { console.log(`${ok ? 'pass' : 'FAIL'}: ${what}${detail ? ` (${detail})` : ''}`); if (!ok) failures.push(what); };
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

// One connection to the relay: the hello and what follows it; everything it
// answers until it closes (or `until` matches, leaving it open).
function dial(hello, { until, timeoutMs = 60000 } = {}) {
  return new Promise(resolve => {
    const socket = connect(PORT, '127.0.0.1', () => socket.write(hello));
    let got = Buffer.alloc(0);
    const done = () => { clearTimeout(timer); resolve({ text: got.toString('utf8'), socket }); };
    const timer = setTimeout(() => { socket.destroy(); done(); }, timeoutMs);
    socket.on('data', chunk => { got = Buffer.concat([got, chunk]); if (until?.test(got.toString('utf8'))) done(); });
    socket.on('close', done);
    socket.on('error', () => {});
  });
}

// A command as a command connector: its stdout and its exit code from the
// relay's closing agent/exit line (null when there was none).
async function run(command, args, env = {}) {
  const { text } = await dial(`AGENT-COMMAND ${CHECK.secret}\n${JSON.stringify({ command, args, env })}\n`);
  const lines = text.trimEnd().split('\n');
  let exit;
  try { exit = JSON.parse(lines.at(-1)); } catch {}
  if (exit?.method !== 'agent/exit') return { stdout: text, code: null };
  return { stdout: lines.slice(0, -1).join('\n'), code: exit.params.code, stderr: exit.params.stderr };
}

// One of the screen's scripts as `browser`, as the sidecar runs it: the relay
// answers AGENT-BROWSER first, then the script's output and its exit line.
async function onScreen(args, env = {}) {
  const { text } = await dial(`AGENT-BROWSER ${CHECK.secret}\n${JSON.stringify({ command: 'node', args, env })}\n`);
  if (!text.startsWith('AGENT-BROWSER\n')) return { stdout: text, code: null };
  const lines = text.slice('AGENT-BROWSER\n'.length).trimEnd().split('\n');
  let exit;
  try { exit = JSON.parse(lines.at(-1)); } catch {}
  if (exit?.method !== 'agent/exit') return { stdout: lines.join('\n'), code: null };
  return { stdout: lines.slice(0, -1).join('\n'), code: exit.params.code, stderr: exit.params.stderr };
}

// The relay and the screen's browser are up.
for (let i = 0; ; i++) {
  const relayUp = await new Promise(resolve => { const s = connect(PORT, '127.0.0.1', () => { s.destroy(); resolve(true); }); s.on('error', () => resolve(false)); });
  const cdpUp = await fetch(`${CDP}/json/version`).then(r => r.ok, () => false);
  if (relayUp && cdpUp) break;
  if (i > 120) { check(false, 'the relay and the browser came up within a minute'); process.exit(1); }
  await pause(500);
}

// Commands run, as the agent, and their exit code comes back.
const who = await run('sh', ['-c', 'id -un; exit 7']);
check(who.code === 7 && who.stdout.trim() === 'agent', 'a command runs as agent and its exit code comes back', JSON.stringify(who));

// Leaks, as the agent's processes see them.
const probe = [
  'cat "$HOME/.desk-token" >/dev/null 2>&1 && echo "LEAK: ~/.desk-token"',
  'cat /run/desk/token >/dev/null 2>&1 && echo "LEAK: /run/desk/token"',
  'for f in /proc/[0-9]*/environ; do if tr "\\0" "\\n" < "$f" 2>/dev/null | grep -qE "^(SPRITE_RELAY_SECRET|PI_DESKTOP_TOKEN|SPRITE_CDP_TOKEN)="; then echo "LEAK: $f"; fi; done',
  'env | grep -qE "^(SPRITE_RELAY_SECRET|PI_DESKTOP_TOKEN|SPRITE_CDP_TOKEN)=" && echo "LEAK: own environment"',
  'cat /run/browser/cdp-token >/dev/null 2>&1 && echo "LEAK: /run/browser/cdp-token"',
  'exit 0'
].join('\n');
const leaks = await run('sh', ['-c', probe]);
check(leaks.code === 0 && !leaks.stdout.trim(), 'a command the relay starts reads neither the bearer nor the relay secret', leaks.stdout.trim().replace(/\n/g, '; ').slice(0, 400));

// Document tools, as the agent's shell runs them; output and stderr together.
for (const [what, command, pattern] of [
  ['pdftoppm', 'pdftoppm -v', /pdftoppm version/],
  ['pdftotext', 'pdftotext -v', /pdftotext version/],
  ['tesseract with English', 'tesseract --list-langs', /^eng$/m],
  ['Info-ZIP unzip', 'unzip -v', /Info-ZIP/],
  ['python3', 'python3 --version', /^Python 3\./],
  ['7z', '7z', /7-Zip/],
  ['qpdf', 'qpdf --version', /qpdf version/],
  ['mutool', 'mutool -v', /mutool version/],
  ['GNU diff', 'diff --version', /GNU diffutils/],
  ['LibreOffice Writer, headless', 'soffice -env:UserInstallation=file:///tmp/office-check --headless --version', /LibreOffice \d/],
  ['unzip opens a ZIP64 archive', 'cd "$(mktemp -d)" && python3 -c "import zipfile; z = zipfile.ZipFile(\'big.zip\', \'w\'); f = z.open(\'page.txt\', \'w\', force_zip64=True); f.write(b\'zip64 ok\'); f.close(); z.close()" && unzip -p big.zip page.txt', /^zip64 ok$/]
]) {
  const ran = await run('sh', ['-c', `${command} 2>&1`]);
  check(ran.code === 0 && pattern.test(ran.stdout), `as agent, ${what}`, `exit ${ran.code}: ${ran.stdout.trim().split('\n')[0]?.slice(0, 120)}`);
}

// The screen, through the relay's desk path.
const shot = await dial(`AGENT-DESK ${CHECK.secret}\n${JSON.stringify({ action: 'screenshot' })}\n`);
let screen;
try { screen = JSON.parse(shot.text); } catch {}
check(screen?.ok === true && Buffer.from(screen.image_b64 ?? '', 'base64').subarray(1, 4).toString() === 'PNG',
  'a screenshot through AGENT-DESK', screen ? `${screen.result ?? screen.error}` : `answer: ${JSON.stringify(shot.text.slice(0, 120))}`);

// Typed text (a one-time code, say) stays out of every process's arguments,
// which any user can read: watch them all while it is typed.
const typed = `typedmarker${'q'.repeat(150)}`;
const seenTyped = new Set();
let typing = true;
const watch = (async () => {
  while (typing) {
    for (const pid of readdirSync('/proc').filter(pid => /^\d+$/.test(pid))) {
      try { const args = readFileSync(`/proc/${pid}/cmdline`, 'utf8'); if (args.includes('typedmarker')) seenTyped.add(args.split('\0')[0]); } catch {}
    }
    await pause(5);
  }
})();
const type = await dial(`AGENT-DESK ${CHECK.secret}\n${JSON.stringify({ action: 'type', text: typed })}\n`);
typing = false;
await watch;
let typeReply;
try { typeReply = JSON.parse(type.text); } catch {}
check(typeReply?.ok === true, 'a type action through AGENT-DESK', typeReply ? `${typeReply.result ?? typeReply.error}` : `answer: ${JSON.stringify(type.text.slice(0, 120))}`);
check(seenTyped.size === 0, 'typed text is in no process\'s arguments', [...seenTyped].join(', '));

// The screen a person opens: websockify answers the upgrade through AGENT-SCREEN.
const vnc = await dial(`AGENT-SCREEN ${CHECK.secret}\nGET /websockify HTTP/1.1\r\nHost: sprite\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n` +
  'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n\r\n', { until: /\r\n\r\n/, timeoutMs: 10000 }); // gitleaks:allow (RFC 6455's sample nonce)
vnc.socket.destroy();
check(/^HTTP\/1\.1 101/.test(vnc.text), 'the screen\'s websockify answers through AGENT-SCREEN', vnc.text.split('\r\n')[0]);

// A local https page, its certificate accepted for this check alone;
// /paint/<colour> is a page in one colour. /popup and /popup-late have a
// button filling the page that opens /paint/ff00ff with window.open, at once
// or after six seconds (a page that fetches first: the click's activation has
// lapsed by then); /download a link to a file; /upload a file field that
// reads back the file's name and size in its title. /sign-in and /checkout
// are forms whose button posts to /done, a blank page.
const button = (title, onclick) => `<title>${title}</title><button style="position:fixed;inset:0;width:100%;height:100%" onclick="${onclick}">${title}</button>`;
const submit = title => `<button style="position:fixed;left:0;right:0;top:30%;bottom:0">${title}</button>`;
function serve(request, response) {
  response.setHeader('content-type', 'text/html');
  const paint = request.url.match(/^\/paint\/([0-9a-f]{6})$/);
  if (paint) return response.end(`<title>${paint[1]}</title><body style="margin:0;background:#${paint[1]}">`);
  if (request.url === '/popup') return response.end(button('Open the statement', 'window.open(\'/paint/ff00ff\')'));
  if (request.url === '/popup-late') return response.end(button('Open it later', 'setTimeout(() => window.open(\'/paint/ffff00\'), 6000)'));
  if (request.url === '/download') return response.end('<title>Download</title><a href="/files/report.txt" style="position:fixed;inset:0;font-size:80px">The report</a>');
  if (request.url === '/files/report.txt') return response.writeHead(200, { 'content-type': 'text/plain', 'content-disposition': 'attachment; filename="report.txt"' }).end('A made-up report.\n');
  if (request.url === '/upload') return response.end('<title>Upload</title><label for="doc">Statement</label> <input type="file" id="doc">' +
    '<script>doc.onchange = () => { document.title = doc.files[0].name + " " + doc.files[0].size; };</script>');
  if (request.url === '/sign-in') return response.end('<title>Sign in</title><form method="post" action="/done"><input name="user" autocomplete="username">' +
    `<input type="password" name="pass" autocomplete="current-password">${submit('Sign in')}</form>`);
  if (request.url === '/checkout') return response.end('<title>Checkout</title><form method="post" action="/done"><input name="name" autocomplete="cc-name">' +
    `<input name="number" autocomplete="cc-number"><input name="expiry" autocomplete="cc-exp"><input name="cvc" autocomplete="cc-csc">${submit('Pay')}</form>`);
  if (request.url === '/done') return response.end('<title>Done</title><body style="margin:0;background:#fff">');
  response.end('<title>Sign in to the check</title><form><input type="text" name="user"><input type="password" name="pass"></form>');
}
const site = createServer({ key: CHECK.key, cert: CHECK.cert }, serve);
await new Promise(resolve => site.listen(8443, '127.0.0.1', resolve));
// The same pages over plain http on localhost: Chromium never offers to save
// a password on a page whose certificate it refused, and only the browser's
// own trust store, not this check, could accept it.
const plainSite = createPlainServer(serve);
await new Promise(resolve => plainSite.listen(8081, '127.0.0.1', resolve));

// One DevTools call on a page's or the browser's socket; undefined when it
// does not answer in time.
async function devtools(address, method, params = {}, ms = 5000) {
  const socket = new WebSocket(address);
  try {
    await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
    socket.send(JSON.stringify({ id: 1, method, params }));
    return await Promise.race([new Promise(resolve => { socket.onmessage = event => { const message = JSON.parse(event.data); if (message.id === 1) resolve(message.result); }; }), pause(ms)]);
  } catch { return undefined; } finally { socket.close(); }
}
const browserAddress = async () => (await (await fetch(`${CDP}/json/version`)).json()).webSocketDebuggerUrl;
const pages = async () => (await (await fetch(`${CDP}/json/list`)).json()).filter(tab => tab.type === 'page');
// The browser's windows, each with its pages' ids.
async function windows() {
  const address = await browserAddress(), each = new Map();
  for (const tab of await pages()) {
    const window = (await devtools(address, 'Browser.getWindowForTarget', { targetId: tab.id }))?.windowId;
    each.set(window, [...each.get(window) ?? [], tab.id]);
  }
  return [...each.values()];
};
const visitTab = () => readFileSync('/home/browser/.visit-tab', 'utf8').trim();
const xdotool = (...args) => { try { return execFileSync('xdotool', args, { env: { PATH: '/usr/bin:/bin', DISPLAY: ':99' } }).toString().trim(); } catch { return null; } };
// The screen as a person sees it, kept in /tmp/visit-window for a person to look at.
mkdirSync('/tmp/visit-window', { recursive: true });
const shoot = name => { try { execFileSync('scrot', ['-o', `/tmp/visit-window/${name}.png`], { env: { PATH: '/usr/bin:/bin', DISPLAY: ':99' } }); } catch {} };
// A screenshot's colour at its centre, read by the browser in the person's tab.
const colour = async (tab, jpeg) => (await devtools(tab.webSocketDebuggerUrl, 'Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `new Promise(resolve => {
  const image = new Image();
  image.onload = () => { const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
    const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
    resolve([...context.getImageData(image.width >> 1, image.height >> 1, 1, 1).data.slice(0, 3)].join()); };
  image.src = 'data:image/jpeg;base64,${jpeg}'; })` }))?.result?.value;
const near = (seen, hex) => String(seen).split(',').every((value, i) => Math.abs(Number(value) - parseInt(hex.slice(i * 2, i * 2 + 2), 16)) < 40);
async function visit(path) {
  const visited = await onScreen(['/opt/agent/visit.mjs', `https://localhost:8443${path}`]);
  let page;
  try { page = JSON.parse(visited.stdout); } catch {}
  return { code: visited.code, page };
}
// The window on top, by the window manager's stacking order (bottom first).
const onTop = () => {
  let stacking = '';
  try { stacking = execFileSync('xprop', ['-root', '_NET_CLIENT_LIST_STACKING'], { env: { PATH: '/usr/bin:/bin', DISPLAY: ':99' } }).toString(); } catch {}
  const top = stacking.split('#')[1]?.split(',').at(-1)?.trim();
  return top ? xdotool('getwindowname', String(parseInt(top, 16))) : null;
};
// The window holding the keyboard, by its title: Chromium names its window after the tab in front.
const keyboard = () => xdotool('getactivewindow', 'getwindowname') ?? '';
const visibility = async tab => tab && (await devtools(tab.webSocketDebuggerUrl, 'Runtime.evaluate', { expression: 'document.visibilityState', returnByValue: true }))?.result?.value;
// The person's page, on the same site as the visits, never navigated.
const PERSON_PAGE = 'https://localhost:8443/paint/00ff00';
// The visit's tab in front of the screen's one window, on top with the keyboard; the person's tab keeps its page.
async function visitInFront(title, when) {
  const tabs = await pages(), all = await windows(), id = visitTab();
  const seen = await visibility(tabs.find(tab => tab.id === id)), kept = tabs.find(tab => tab.id === person.id)?.url;
  const top = onTop();
  check(all.length === 1 && seen === 'visible' && keyboard().startsWith(title) && top?.startsWith(title) && kept === PERSON_PAGE && id !== person.id,
    `${when}: the visit's tab is in front of the screen's one window, on top with the keyboard, and the person's tab keeps its page`,
    `windows ${JSON.stringify(all)}, ${seen}, on top ${top}, keyboard on ${keyboard()}, the person's tab on ${kept}`);
}
// A click in the middle of the screen, on the page in front.
const click = () => xdotool('mousemove', '640', '450', 'click', '1');

let browser = new WebSocket(await browserAddress());
await new Promise((resolve, reject) => { browser.onopen = resolve; browser.onerror = reject; });
browser.send(JSON.stringify({ id: 1, method: 'Security.setIgnoreCertificateErrors', params: { ignore: true } }));
await pause(300);

// The person's own tab, in front of their window, on the visits' site: a
// visit never navigates it, and opens its own tab in front of it (agent b10, 16 Nov).
let [person] = await pages();
await devtools(person.webSocketDebuggerUrl, 'Page.navigate', { url: PERSON_PAGE });
await pause(1000);

const first = await visit('/paint/0000ff');
check(first.code === 0 && first.page?.title === '0000ff' && near(await colour(person, first.page.screenshot), '0000ff'), 'visit.mjs shows a local page', `exit ${first.code}, title ${first.page?.title}`);
await visitInFront('0000ff', 'its tab opened');
shoot('1-visit-tab-in-front');

// The person brings their own tab back to the front; the next visit brings the visit's forward again.
await fetch(`${CDP}/json/activate/${person.id}`);
await pause(1000);
shoot('2-person-in-front');
const signInPage = await visit('/');
check(signInPage.code === 0 && signInPage.page?.title === 'Sign in to the check' && signInPage.page.screenshot?.length > 100,
  'visit.mjs shows a local page in its tab, brought forward', `exit ${signInPage.code}, title ${signInPage.page?.title}`);

const signIn = { host: 'localhost', username: 'maya', password: `made-up-check-password-${Date.now()}` }; // gitleaks:allow (made up)
// While it fills, the agent's own code (a command the relay starts, as the
// agent's shell would be) reads every process's environment and arguments
// it can for the password (#60). Its own environment holds it, to know it.
const environScan = `const fs = require('fs'); const mark = process.env.MARK; const end = Date.now() + 12000; const seen = new Set();
while (Date.now() < end) for (const p of fs.readdirSync('/proc')) { if (!/^[0-9]+$/.test(p) || p === String(process.pid)) continue;
  for (const what of ['environ', 'cmdline']) { let c; try { c = fs.readFileSync('/proc/' + p + '/' + what, 'latin1'); } catch { continue; }
    if (c.includes(mark)) { let args = ''; try { args = fs.readFileSync('/proc/' + p + '/cmdline', 'latin1').split('\\0').slice(0, 2).join(' '); } catch {}
      const key = what + ' ' + args; if (!seen.has(key)) { seen.add(key); console.log('the password, in the ' + what + ' of ' + args); } } } }`;
const scanning = run('node', ['-e', environScan], { MARK: signIn.password });
await pause(1500);
const filled = await onScreen(['/opt/agent/fill.mjs'], { AGENT_SIGN_IN: JSON.stringify(signIn) });
let fill;
try { fill = JSON.parse(filled.stdout); } catch {}
check(filled.code === 0 && fill?.ok === true && fill.filled.join() === 'username,password', 'fill.mjs fills the sign-in', `exit ${filled.code}, ${JSON.stringify(fill)}`);
const scanned = await scanning;
check(scanned.code === 0 && !scanned.stdout.trim(), 'as agent, the password is in no environment or arguments it can read while it is filled',
  `exit ${scanned.code}: ${scanned.stdout.trim().replace(/\n/g, '; ').slice(0, 300)}`);

// The agent's own code then asks the screen's browser, over its debugging
// port, for every password field's value in the visit's tab (#60).
const cdpRead = `const tabs = await (await fetch('http://127.0.0.1:9222/json/list', { signal: AbortSignal.timeout(5000) })).json();
for (const tab of tabs.filter(tab => tab.type === 'page')) {
  const socket = new WebSocket(tab.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  socket.send(JSON.stringify({ id: 1, method: 'Runtime.evaluate', params: { returnByValue: true,
    expression: '[...document.querySelectorAll("input[type=password]")].map(field => field.value).join()' } }));
  const value = await new Promise(resolve => { socket.onmessage = event => resolve(JSON.parse(event.data).result?.result?.value); });
  socket.close();
  if (value) console.log(value);
}`;
const read = await run('node', ['--input-type=module', '-e', cdpRead]);
check(!read.stdout.includes(signIn.password), 'as agent, the filled password cannot be read over the browser\'s debugging port',
  read.stdout.includes(signIn.password) ? 'it read the password' : `exit ${read.code}: ${String(read.stderr ?? '').split('\n').find(line => /Error/.test(line))?.slice(0, 160)}`);
// Nor does the port answer it at all without the token, nor the token's file.
const guessed = await run('sh', ['-c', 'cat /run/browser/cdp-token; cat /home/browser/.visit-tab; ls /home/browser/.config/chromium; ' +
  'node -e "fetch(\'http://127.0.0.1:9222/json/version\').then(r => console.log(\'status \' + r.status), e => console.log(e.message))"']);
check(/^status 404$/m.test(guessed.stdout) && !/[0-9a-f]{64}/.test(guessed.stdout) && !/Default/.test(guessed.stdout),
  'as agent, DevTools answers 404 without the token, and the token, the visit\'s tab and the browser\'s profile are unreadable', guessed.stdout.trim().replace(/\n/g, '; ').slice(0, 300));
// The screen's spawner runs only its scripts: anything else is closed unanswered.
const shell = await onScreen(['-e', 'console.log(1)']);
const other = await dial(`AGENT-BROWSER ${CHECK.secret}\n${JSON.stringify({ command: 'sh', args: ['-c', 'id'] })}\n`);
check(shell.code === null && !shell.stdout && other.text === 'AGENT-BROWSER\n', 'AGENT-BROWSER runs nothing but the screen\'s scripts',
  `${JSON.stringify(shell)} ${JSON.stringify(other.text)}`);

// What the person sees after the fill is the page filled.
const filledTab = (await pages()).find(tab => tab.id === visitTab());
const inField = (await devtools(filledTab?.webSocketDebuggerUrl, 'Runtime.evaluate', { expression: 'document.querySelector("[name=pass]").value', returnByValue: true }))?.result?.value;
check(inField === signIn.password, 'the tab in front is the page filled', inField === signIn.password ? '' : inField === undefined ? 'no answer' : 'another value');
await visitInFront('Sign in to the check', 'after the fill');
shoot('3-filled-page-in-front');

// Popups (a lender's document viewer): a click on a button that calls
// window.open opens a tab in front of the screen's window, which ctrl+w closes.
const popupPage = 'https://localhost:8443/paint/ff00ff', latePage = 'https://localhost:8443/paint/ffff00';
await visit('/popup');
click();
await pause(2000);
const popup = (await pages()).find(tab => tab.url === popupPage);
const withPopup = await windows();
check(popup && withPopup.length === 1 && await visibility(popup) === 'visible' && keyboard().startsWith('ff00ff'),
  'a click on a button that calls window.open opens a tab in front of the screen\'s window', `${popup?.url}, windows ${JSON.stringify(withPopup)}, keyboard on ${keyboard()}`);
shoot('4-popup-in-front');
xdotool('key', 'ctrl+w');
await pause(1000);
check(popup && !(await pages()).some(tab => tab.id === popup.id) && keyboard().startsWith('Open the statement'),
  'ctrl+w closes it, and the page that opened it is in front again', `keyboard on ${keyboard()}`);
// One a page opens six seconds after the click, its activation lapsed: Chromium blocks it unless the image's policy allows popups.
await visit('/popup-late');
click();
let late;
for (let i = 0; i < 40 && !late; i++) { await pause(500); late = (await pages()).find(tab => tab.url === latePage); }
await pause(1000);
check(late && (await windows()).length === 1 && await visibility(late) === 'visible',
  'a popup a page opens six seconds after the click is not blocked, and opens as a tab in front', `${late?.url ?? 'none opened'}, keyboard on ${keyboard()}, pages ${JSON.stringify((await pages()).map(tab => tab.url))}, windows ${JSON.stringify(await windows())}`);
shoot('5-late-popup-in-front');
if (late) await fetch(`${CDP}/json/close/${late.id}`);

// Downloads land in the agent's ~/browser-files, made at boot: the agent's, group browser, set-group-ID.
await visit('/download');
click();
let downloaded;
for (let i = 0; i < 30; i++) {
  downloaded = await run('sh', ['-c', 'cat ~/browser-files/report.txt 2>/dev/null; stat -c "%U %G %A %n" ~/browser-files']);
  if (/A made-up report/.test(downloaded.stdout)) break;
  await pause(500);
}
check(/^A made-up report\.$/m.test(downloaded.stdout) && /^agent browser drwxrws--- /m.test(downloaded.stdout),
  'a download lands in ~/browser-files (agent, group browser, 2770), where the agent reads it', downloaded.stdout.trim().replace(/\n/g, '; '));
shoot('6-after-download');

// Uploads, as browser_upload does them: the agent copies its file into the
// shared folder, and upload.mjs, as browser, sets the field in the tab visit_website opened.
await visit('/upload');
const shared = '/home/agent/browser-files/.uploads/check';
const prepared = await run('sh', ['-c', `mkdir -p ~/docs && printf 'A made-up statement.' > ~/docs/statement.txt && umask 027 && mkdir -p ${shared} && ` +
  `cp -L -- ~/docs/statement.txt ${shared}/statement.txt && chmod 0640 ${shared}/statement.txt && ln -s '/home/browser/.config/chromium/Local State' ${shared}/state.txt`]);
const upload = async path => { const ran = await onScreen(['/opt/agent/upload.mjs'], { AGENT_UPLOAD: JSON.stringify({ field: 'Statement', path }) }); try { return JSON.parse(ran.stdout); } catch { return ran; } };
const uploaded = await upload(`${shared}/statement.txt`);
const uploadTab = (await pages()).find(tab => tab.id === visitTab());
const uploadTitle = async () => (await devtools(uploadTab?.webSocketDebuggerUrl, 'Runtime.evaluate', { expression: 'document.title', returnByValue: true }))?.result?.value;
check(prepared.code === 0 && uploaded?.ok === true && await uploadTitle() === 'statement.txt 20',
  'upload.mjs puts the agent\'s file into the field labelled Statement, and the page reads its name and size', `exit ${prepared.code}, ${JSON.stringify(uploaded)}, title ${await uploadTitle()}`);
shoot('7-after-upload');
const planted = await upload(`${shared}/state.txt`);
check(planted?.ok === false && /not a file in the shared folder/.test(planted.error ?? ''), 'upload.mjs refuses a link the agent planted to the browser\'s own file', JSON.stringify(planted));

// Saved passwords and cards (the agent drives this screen): the image's policy
// turns off Chromium's password manager, its leak check and Autofill's saving
// of cards and addresses, so nothing offers to save, or shows, a password or
// card just filled, and blocks the pages that show what a profile saved
// before (agent/guest/chromium-policy.json).
const policyTab = await (await fetch(`${CDP}/json/new?chrome://policy`, { method: 'PUT' })).json();
await pause(3000);
// chrome://policy's words, leaf by leaf through its shadow roots: a row is
// the policy's name, its value, then source, scope and level, then its status.
const policyWords = (await devtools(policyTab.webSocketDebuggerUrl, 'Runtime.evaluate', { returnByValue: true, expression: `(() => { const out = [];
  const walk = node => { if (node.shadowRoot) walk(node.shadowRoot); for (const child of node.children ?? []) walk(child);
    if (!node.children?.length && node.textContent.trim()) out.push(node.textContent.trim()); };
  walk(document.body); return out; })()` }))?.result?.value ?? [];
await fetch(`${CDP}/json/close/${policyTab.id}`);
// chrome://policy stays open to the blocklist: a policy is reloaded there.
check(policyWords.includes('Reload policies'), 'chrome://policy opens, not blocked', `${policyWords.length} words on it`);
// Each at its value, set by the machine's mandatory policy, and "OK": a
// policy this Chromium has replaced shows "Deprecated" there instead. The two
// Autofill switches are those: Chromium 156 replaced them with
// AutofillSettings, yet still offered "Save card?" with AutofillSettings alone
// (blocking "payments" or "all" on "*") and offers none with them, so both
// are set, and they are checked as applied, deprecated or not.
// No "/*": the blocklist matches a path's start, and "/*" is no wildcard there,
// so these two block every page under them. All of Settings: a page inside it
// is reached by a click, which changes its address without opening a page,
// and so passes a blocklist of its pages. The pages of saved passwords, cards
// and addresses are checked one by one below (on Chromium 156 /addresses goes
// on to /contactInfo, beside /identityDocs and /travel).
const URL_BLOCKLIST = ['chrome://password-manager', 'chrome://settings'];
const SAVED_INFO_PAGES = [...URL_BLOCKLIST, 'chrome://settings/passwords', 'chrome://settings/autofill', 'chrome://settings/payments',
  'chrome://settings/addresses', 'chrome://settings/contactInfo', 'chrome://settings/identityDocs', 'chrome://settings/travel'];
const canonical = value => JSON.stringify(value, (key, each) => each && typeof each === 'object' && !Array.isArray(each) ?
  Object.fromEntries(Object.entries(each).sort(([a], [b]) => a.localeCompare(b))) : each);
for (const [name, value] of Object.entries({ PasswordManagerEnabled: false, PasswordLeakDetectionEnabled: false,
  AutofillSettings: [{ url_pattern: '*', blocked_types: ['payments', 'contact_info', 'identity_docs', 'travel'] }], URLBlocklist: URL_BLOCKLIST,
  AutofillCreditCardEnabled: false, AutofillAddressEnabled: false })) {
  const statuses = name.startsWith('AutofillC') || name.startsWith('AutofillA') ? ['OK', 'Deprecated'] : ['OK'];
  const at = policyWords.indexOf(name), row = at < 0 ? [] : policyWords.slice(at + 1, at + 6);
  let shown;
  try { shown = JSON.parse(row[0]); } catch {}
  check(canonical(shown) === canonical(value) && row[1] === 'Platform' && row[2] === 'Machine' && row[3] === 'Mandatory' && statuses.includes(row[4]),
    `chrome://policy shows ${name} at its value, mandatory for the machine, ${statuses.join(' or ')}`, at < 0 ? 'not listed' : row.join(' | ').slice(0, 300));
}

// Anything Chromium draws over a blank page (a "Save password?" bubble, with
// its button that shows the password) is pixels that are not white; the key
// or card icon it leaves at the address bar's end, which opens that bubble
// again, is dark pixels left of the star. Counted in the person's tab from a
// screenshot of the whole screen, 1280 by 800.
async function overBlankPage(name) {
  shoot(name);
  let png = '';
  try { png = readFileSync(`/tmp/visit-window/${name}.png`).toString('base64'); } catch {}
  return (await devtools(person.webSocketDebuggerUrl, 'Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `new Promise(resolve => {
    const image = new Image();
    image.onload = () => { const canvas = document.createElement('canvas'); canvas.width = image.width; canvas.height = image.height;
      const context = canvas.getContext('2d'); context.drawImage(image, 0, 0);
      const count = (x, y, width, height, limit) => { const { data } = context.getImageData(x, y, width, height); let drawn = 0;
        for (let i = 0; i < data.length; i += 4) if (data[i] < limit || data[i + 1] < limit || data[i + 2] < limit) drawn++;
        return drawn; };
      resolve({ page: count(10, 100, image.width - 20, image.height - 110, 230), icon: count(1060, 50, 52, 26, 150) }); };
    image.onerror = () => resolve(null);
    image.src = 'data:image/png;base64,${png}'; })` }, 10000))?.result?.value ?? null;
}
// A form filled as fill.mjs and pay.mjs fill (the native setter, then input
// and change), sent by a click on its button as the agent would, and what is
// drawn over the blank page it lands on. Its tab is closed after, taking any
// bubble with it, so the next visit opens a fresh one.
async function sendFilled(address, values, name) {
  const shown = await onScreen(['/opt/agent/visit.mjs', address]);
  const tab = (await pages()).find(each => each.id === visitTab());
  await devtools(tab?.webSocketDebuggerUrl, 'Runtime.evaluate', { expression: `(${values => {
    for (const [field, value] of Object.entries(values)) {
      const input = document.querySelector(`[name=${field}]`);
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, value);
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }
  }})(${JSON.stringify(values)})` });
  xdotool('mousemove', '640', '600', 'click', '1');
  let title;
  for (let i = 0; i < 20 && title !== 'Done'; i++) { await pause(500); title = (await pages()).find(each => each.id === visitTab())?.title; }
  await pause(3000);
  const drawn = await overBlankPage(name);
  if (tab) await fetch(`${CDP}/json/close/${tab.id}`);
  await pause(1000);
  return `visit exit ${shown.code}, ${title === 'Done' ? 'sent' : `not sent (title ${title})`}, ${drawn?.page} pixels drawn over the blank page, ${drawn?.icon} by the address bar`;
}
const login = await sendFilled('http://localhost:8081/sign-in', { user: 'maya', pass: `made-up-check-password-${Date.now()}` }, '9-after-sign-in-sent'); // gitleaks:allow (made up)
check(login === 'visit exit 0, sent, 0 pixels drawn over the blank page, 0 by the address bar',
  'after a filled password is sent, Chromium offers nothing (no "Save password?" bubble or key icon)', login);
// A made-up card, the test number every card network publishes. Chromium
// offers to save a card even on a page whose certificate it refused.
const card = await sendFilled('https://localhost:8443/checkout', { name: 'Maya Example', number: ['4111', '1111', '1111', '1111'].join(''), expiry: '12/30', cvc: '123' }, '10-after-card-sent');
check(card === 'visit exit 0, sent, 0 pixels drawn over the blank page, 0 by the address bar',
  'after a filled card is sent, Chromium offers nothing (no "Save card?" bubble or card icon)', card);
// Chromium's "This page is blocked" error page, and nothing else, is in a tab:
// only that is asked of it.
const isBlocked = async tab => (await devtools(tab?.webSocketDebuggerUrl, 'Runtime.evaluate', { returnByValue: true,
  expression: `!!document.querySelector('#main-frame-error') && /^This page is blocked/.test(document.querySelector('#main-frame-error h1')?.textContent.trim() ?? '')` }))?.result?.value === true;
// What a profile saved before the policy (on Linux the password page shows a
// password with no other sign-in) cannot be opened: each page, in a tab
// behind the person's, is blocked. "/passwords" is under the first: a
// pattern that blocks only an exact path fails here. A page that opens is
// named and closed, never read or shot.
for (const page of [...SAVED_INFO_PAGES, 'chrome://password-manager/passwords', 'chrome://password-manager/settings', 'chrome://password-manager/checkup']) {
  const targetId = (await devtools(await browserAddress(), 'Target.createTarget', { url: page, background: true }))?.targetId;
  await pause(1500);
  const blocked = await isBlocked((await pages()).find(each => each.id === targetId));
  if (targetId) await fetch(`${CDP}/json/close/${targetId}`);
  check(blocked, `${page} is blocked`);
}

// Nor by the person's way in, which the agent can take on the screen:
// Chromium's menu (the three dots at the toolbar's end), its Settings, and
// each page under its "Passwords and autofill". The menu is found by reading
// a screenshot of it, over a blank page of the check's own, with tesseract.
// What a click opens is checked as above, and closed before the next shot.
const blank = () => onScreen(['/opt/agent/visit.mjs', 'http://localhost:8081/done']);
function wordAt(name, phrase) {
  shoot(name);
  let tsv = '';
  try { tsv = execFileSync('tesseract', [`/tmp/visit-window/${name}.png`, '-', 'tsv'], { env: { PATH: '/usr/bin:/bin' }, stdio: ['ignore', 'pipe', 'ignore'] }).toString(); } catch {}
  const seen = tsv.split('\n').slice(1).map(line => line.split('\t')).filter(cells => cells[11]?.trim())
    .map(cells => ({ text: cells[11].trim(), x: Number(cells[6]) + (cells[8] >> 1), y: Number(cells[7]) + (cells[9] >> 1) }));
  const want = phrase.split(' ');
  return seen.find((word, at) => want.every((each, i) => seen[at + i]?.text === each)) ?? null;
}
const browserPages = async () => (await pages()).filter(tab => !/^(chrome:\/\/omnibox-popup|chrome-extension:)/.test(tab.url));
for (const path of [['Settings'], ...['Password Manager', 'Payments', 'Contact info', 'Identity', 'Travel'].map(page => ['Passwords and autofill', page])]) {
  const label = path.join(' > ');
  await blank();
  await pause(800);
  const before = new Set((await browserPages()).map(tab => tab.id));
  xdotool('mousemove', '1252', '63', 'click', '1');
  await pause(1500);
  let item = wordAt('12-menu', path[0]);
  if (item && path[1]) {
    xdotool('mousemove', String(item.x + 30), String(item.y));
    await pause(1500);
    item = wordAt('13-menu-passwords-and-autofill', path[1]);
  }
  if (!item) {
    xdotool('key', 'Escape'); xdotool('key', 'Escape');
    check(false, `the menu's ${label} lands on the blocked page`, 'not found in the menu');
    continue;
  }
  xdotool('mousemove', String(item.x), String(item.y), 'click', '1');
  let opened;
  for (let i = 0; i < 10 && !opened; i++) {
    await pause(500);
    opened = (await browserPages()).find(tab => !before.has(tab.id) || (tab.id === visitTab() && !tab.url.startsWith('http://localhost:8081/')));
  }
  await pause(1000);
  const blocked = opened ? await isBlocked(opened) : false;
  const url = opened && !blocked ? (await pages()).find(tab => tab.id === opened.id)?.url : '';
  if (opened && opened.id !== visitTab()) await fetch(`${CDP}/json/close/${opened.id}`);
  check(blocked, `the menu's ${label} lands on the blocked page`, blocked ? '' : opened ? `it opened ${url}` : 'nothing opened');
}
// The visit's tab again, for the restart below.
await visit('/paint/ffffff');

// The browser restarts (the entrypoint starts it again, reopening its tabs): the visit's tab is found again, not doubled.
const tabsBefore = (await pages()).length;
await pause(3000);
browser.send(JSON.stringify({ id: 2, method: 'Browser.close' }));
browser.close();
await pause(3000);
for (let i = 0; !(await fetch(`${CDP}/json/version`).then(r => r.ok, () => false)) && i < 60; i++) await pause(500);
await pause(3000);
browser = new WebSocket(await browserAddress());
await new Promise((resolve, reject) => { browser.onopen = resolve; browser.onerror = reject; });
browser.send(JSON.stringify({ id: 1, method: 'Security.setIgnoreCertificateErrors', params: { ignore: true } }));
await pause(300);
const reopened = await windows();
const restarted = await visit('/paint/00ffff');
person = (await pages()).find(tab => tab.url === PERSON_PAGE);
const tabsAfter = (await pages()).length;
check(restarted.code === 0 && person && near(await colour(person, restarted.page?.screenshot), '00ffff') && tabsAfter === tabsBefore,
  'after a browser restart visit.mjs reuses its reopened tab', `exit ${restarted.code}, ${tabsBefore} tabs before, reopened ${JSON.stringify(reopened)}, then ${tabsAfter}`);
if (person) await visitInFront('00ffff', 'after a browser restart');
shoot('8-after-restart');
browser.close();
site.close();
plainSite.close();

// Users: hold a daemon and a connector open, then look at every process.
const daemon = await dial(`AGENT-RELAY ${CHECK.secret} ${'ab'.repeat(16)}\n`, { until: /PI-ENV /, timeoutMs: 20000 });
check(/PI-ENV /.test(daemon.text), 'the relay starts the pi-env daemon', JSON.stringify(daemon.text.slice(0, 80)));
const connector = connect(PORT, '127.0.0.1', () => connector.write(`AGENT-COMMAND ${CHECK.secret}\n${JSON.stringify({ command: 'sleep', args: ['37'] })}\n`));
connector.on('error', () => {});
await pause(1500);

const users = Object.fromEntries(readFileSync('/etc/passwd', 'utf8').split('\n').filter(Boolean).map(line => line.split(':')).map(([name, , uid]) => [uid, name]));
const processes = readdirSync('/proc').filter(pid => /^\d+$/.test(pid)).flatMap(pid => {
  try {
    const status = readFileSync(`/proc/${pid}/status`, 'utf8');
    const args = readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').filter(Boolean).join(' ');
    return [{ pid, ppid: /PPid:\s+(\d+)/.exec(status)[1], user: users[/Uid:\s+(\d+)/.exec(status)[1]], args }];
  } catch { return []; }
}).filter(proc => proc.args);
const supervisor = processes.filter(proc => proc.args === '/bin/sh /opt/agent/entrypoint.sh').map(proc => proc.pid);
// Two spawners have the same arguments: one runs as agent, one as browser.
const intended = proc => {
  if (proc.pid === String(process.pid)) return 'browser';
  if (proc.args === 'node /opt/agent/spawner.mjs') return proc.user === 'browser' ? 'browser' : 'agent';
  if (proc.args === 'node /opt/agent/cdp.mjs' || /chromium/.test(proc.args)) return 'browser';
  if (proc.args === 'node /opt/agent/server.js') return 'desk';
  if (proc.args === 'node /opt/agent/sprite-relay.mjs') return 'relay';
  if (proc.args === '/bin/sh /opt/agent/entrypoint.sh') return 'root';
  if (supervisor.includes(proc.ppid) && /^sleep [\d.]+$/.test(proc.args)) return 'root';
  return 'agent';
};
for (const proc of processes) {
  const want = intended(proc);
  if (proc.user !== want) check(false, `${proc.args.slice(0, 80)} runs as ${want}`, `it runs as ${proc.user}`);
}
const running = (pattern, user) => processes.some(proc => pattern.test(proc.args) && proc.user === user);
for (const [pattern, user] of [[/^node \/opt\/agent\/server\.js$/, 'desk'], [/^node \/opt\/agent\/sprite-relay\.mjs$/, 'relay'],
  [/^\/bin\/sh \/opt\/agent\/entrypoint\.sh$/, 'root'], [/^Xvfb /, 'agent'], [/^openbox/, 'agent'], [/chromium --/, 'browser'], [/^node \/opt\/agent\/cdp\.mjs$/, 'browser'],
  [/^x11vnc /, 'agent'], [/websockify /, 'agent'], [/^node \/opt\/agent\/spawner\.mjs$/, 'agent'], [/^node \/opt\/agent\/spawner\.mjs$/, 'browser'],
  [/pi-env serve --token/, 'agent'], [/^sleep 37$/, 'agent']])
  check(running(pattern, user), `${pattern.source} runs as ${user}`);
const roots = processes.filter(proc => proc.user === 'root').map(proc => proc.args);
console.log(`root runs: ${JSON.stringify(roots)}`);
daemon.socket.destroy();
connector.destroy();

console.log(failures.length ? `${failures.length} failed` : 'ok');
process.exit(failures.length ? 1 : 0);
