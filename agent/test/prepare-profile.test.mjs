import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { hostname, tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { prepareProfile } from '../guest/server.js';

function tempProfile(t) {
  const dir = mkdtempSync(join(tmpdir(), 'prepare-profile-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const prefsDir = join(dir, 'Default');
  return { dir, prefsDir, prefsPath: join(prefsDir, 'Preferences') };
}

function fileSnapshot(path) {
  const { atimeMs, mtimeMs } = statSync(path);
  const sha256 = createHash('sha256').update(readFileSync(path)).digest('hex');
  return { atimeMs, mtimeMs, sha256 };
}

const oldTime = new Date('2000-01-01T00:00:00Z');

test('a returning profile replaces restore-on-startup without disturbing other data', (t) => {
  const { dir, prefsDir, prefsPath } = tempProfile(t);
  const before = {
    profile: { exit_type: 'Crashed', exited_cleanly: false, name: 'Example profile' },
    session: { restore_on_startup: 1, startup_urls: ['https://example.test/'] },
    browser: { show_bookmarks_bar: true },
    extensions: { settings: { sample: { enabled: false, paths: ['abc', 'def'] } } },
  };
  mkdirSync(prefsDir);
  writeFileSync(prefsPath, JSON.stringify(before));

  const files = [join(prefsDir, 'Cookies'), join(prefsDir, 'Login Data')];
  const snapshots = files.map((path, i) => {
    writeFileSync(path, Buffer.from([0, i, 0xff]));
    utimesSync(path, oldTime, oldTime);
    const snapshot = fileSnapshot(path);
    // Rewind atime after hashing so a read by prepareProfile is detectable.
    utimesSync(path, oldTime, oldTime);
    return snapshot;
  });

  assert.deepEqual(prepareProfile(dir), { restore: true });
  assert.deepEqual(files.map(fileSnapshot), snapshots);
  const after = JSON.parse(readFileSync(prefsPath, 'utf8'));
  assert.equal(after.session.restore_on_startup, 5);
  assert.deepEqual(after, {
    ...before,
    profile: { ...before.profile, exit_type: 'Normal', exited_cleanly: true },
    session: { ...before.session, restore_on_startup: 5 },
  });
});

test('a new profile gets the New Tab startup preference', (t) => {
  const { dir, prefsPath } = tempProfile(t);
  assert.equal(existsSync(prefsPath), false);

  assert.deepEqual(prepareProfile(dir), { restore: false });
  const after = JSON.parse(readFileSync(prefsPath, 'utf8'));
  assert.equal(after.session.restore_on_startup, 5);
  assert.deepEqual(after, {
    profile: { exit_type: 'Normal', exited_cleanly: true },
    session: { restore_on_startup: 5 },
  });
});

test('unparseable Preferences are left untouched', (t) => {
  const { dir, prefsDir, prefsPath } = tempProfile(t);
  const bytes = '{"session":';
  mkdirSync(prefsDir);
  writeFileSync(prefsPath, bytes);
  utimesSync(prefsPath, oldTime, oldTime);
  const { mtimeMs } = statSync(prefsPath);

  assert.deepEqual(prepareProfile(dir), { restore: true });
  assert.equal(statSync(prefsPath).mtimeMs, mtimeMs);
  assert.equal(readFileSync(prefsPath, 'utf8'), bytes);
});

test('a live Chromium pid leaves the profile and its lock alone', (t) => {
  const { dir, prefsDir, prefsPath } = tempProfile(t);
  mkdirSync(prefsDir);
  writeFileSync(prefsPath, '{"session":{"restore_on_startup":1}}');
  utimesSync(prefsPath, oldTime, oldTime);
  const before = fileSnapshot(prefsPath);
  utimesSync(prefsPath, oldTime, oldTime);
  const lockPath = join(dir, 'SingletonLock');
  const pid = 424242;
  const lock = `${hostname()}-${pid}`;
  symlinkSync(lock, lockPath);

  const isChromiumPid = (candidate) => candidate === pid;
  assert.deepEqual(prepareProfile(dir, { isChromiumPid }), { restore: true, running: true });
  assert.equal(readlinkSync(lockPath), lock);
  assert.deepEqual(fileSnapshot(prefsPath), before);
});
