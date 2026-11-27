import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { chromiumArgs, prepareProfile } from '../guest/server.js';

function tempProfile(t) {
  const dir = mkdtempSync(join(tmpdir(), 'chromium-args-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

const desktopArgs = (profileDir) => [
  `--user-data-dir=${profileDir}`,
  '--window-size=1280,800',
  '--window-position=0,0',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-default-apps',
  '--disable-dev-shm-usage',
  '--disable-gpu',
  '--disable-gpu-shader-disk-cache',
  '--disk-cache-size=104857600',
  '--hide-crash-restore-bubble',
  ...(process.env.PI_DESKTOP_NO_SANDBOX === '1' ? ['--no-sandbox'] : []),
];

test('a returning Chromium profile starts without a command-line startup override', (t) => {
  const profileDir = tempProfile(t);
  mkdirSync(join(profileDir, 'Default'));
  writeFileSync(join(profileDir, 'Default', 'Preferences'), JSON.stringify({ session: { restore_on_startup: 1 } }));
  const { restore } = prepareProfile(profileDir);
  assert.deepEqual(chromiumArgs({ profileDir, restore }), desktopArgs(profileDir));
});

test('a new Chromium profile starts on about:blank', (t) => {
  const profileDir = tempProfile(t);
  const { restore } = prepareProfile(profileDir);
  assert.deepEqual(chromiumArgs({ profileDir, restore }), [...desktopArgs(profileDir), 'about:blank']);
});
