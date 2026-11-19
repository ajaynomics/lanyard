// A real-browser test that fails must still let `npm test` end: its Chromium,
// and any browser a guest script started, killed, and the run exiting non-zero
// within a bound. Before, a failure left Chromium running, the test file never
// exited, and CI waited out its whole job. Each case runs a deliberately
// failing test file, written to a temporary folder outside the suite, with the
// flags `npm test` uses, in a child process whose every folder is under one
// temporary folder, so whatever it leaves running is found by that path.
import assert from 'node:assert/strict';
import test from 'node:test';
import { spawn } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { CHROMIUM, pause } from './real-browser.mjs';

const AGENT = join(dirname(fileURLToPath(import.meta.url)), '..');
const HARNESS = pathToFileURL(join(AGENT, 'test', 'real-browser.mjs')).href;
const { scripts } = JSON.parse(readFileSync(join(AGENT, 'package.json'), 'utf8'));

// What `npm test` runs, for one file instead of the suite.
const npmTest = (file, flags = []) => {
  const [node, ...args] = scripts.test.split(' ').filter(arg => arg !== 'test/*.test.mjs');
  assert.equal(node, 'node');
  return [...args, ...flags, file];
};

const running = folder => readdirSync('/proc').filter(pid => /^\d+$/.test(pid)).filter(pid => {
  try { return readFileSync(`/proc/${pid}/cmdline`, 'utf8').includes(folder); } catch { return false; }
});

async function run(t, body, flags) {
  assert.ok(CHROMIUM, 'these tests need Chromium (set CHROME_BIN)');
  // Directly under the temporary folder: Chromium refuses a profile whose path is too long for its socket.
  const folder = await mkdtemp(join(tmpdir(), 'td-'));
  t.after(() => rm(folder, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 }));
  const file = join(folder, 'deliberately-failing.test.mjs');
  await writeFile(file, `import test from 'node:test';\nimport { screen, pause } from '${HARNESS}';\n${body}\n`);
  const started = Date.now();
  const child = spawn(process.execPath, npmTest(file, flags), { cwd: AGENT, stdio: ['ignore', 'pipe', 'pipe'],
    env: { PATH: '/usr/bin:/bin', HOME: folder, TMPDIR: folder, LANG: 'C.UTF-8', ...(CHROMIUM && { CHROME_BIN: CHROMIUM }) } });
  let said = '';
  child.stdout.on('data', chunk => { said += chunk; });
  child.stderr.on('data', chunk => { said += chunk; });
  const bound = setTimeout(() => child.kill('SIGKILL'), 45_000);
  t.after(() => { clearTimeout(bound); for (const pid of running(folder)) try { process.kill(Number(pid), 'SIGKILL'); } catch {} });
  const code = await new Promise(resolve => child.on('close', code => resolve(code)));
  clearTimeout(bound);
  const seconds = (Date.now() - started) / 1000;
  await pause(500);
  return { code, seconds, left: running(folder), said };
}

test('a real-browser test that throws, with a second browser a guest started, leaves no Chromium and fails the run promptly', async t => {
  const { code, seconds, left, said } = await run(t, `test('throws after starting the screen and a guest browser', async t => {
  const browser = await screen(t);
  browser.api.env.exec(['chromium', '--headless=new', '--no-sandbox', '--user-data-dir=' + browser.home + '/guest-profile', 'about:blank'], {});
  await pause(1500);
  throw new Error('deliberately failing');
});`);
  assert.ok(seconds < 30, `the run ended within 30 s, not ${seconds} s:\n${said}`);
  assert.notEqual(code, 0, `the run failed:\n${said}`);
  assert.deepEqual(left, [], 'no process of the run is still running');
  assert.match(said, /deliberately failing/, 'the browser started and the test failed as written');
});

test('a real-browser test that never settles is stopped by the per-test timeout, leaving no Chromium', async t => {
  const { code, seconds, left, said } = await run(t, `test('never settles', async t => {
  await screen(t);
  console.log('screen is up');
  await new Promise(() => setInterval(() => {}, 1000));
});`, ['--test-timeout=3000']);
  assert.ok(seconds < 30, `the run ended within 30 s, not ${seconds} s:\n${said}`);
  assert.notEqual(code, 0, `the run failed:\n${said}`);
  assert.deepEqual(left, [], 'no process of the run is still running');
  assert.match(said, /screen is up/, 'the browser started before the test hung');
});

test('npm test bounds every test and ends its run when the tests end, whatever they left open', () => {
  assert.match(scripts.test, /--test-timeout=\d+ /);
  assert.match(scripts.test, /--test-force-exit /);
});
