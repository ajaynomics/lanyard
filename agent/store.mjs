// Retained-store snapshot and restore. Loads no model provider, harness or
// extension: only node:sqlite and the same ownership fence the sidecar holds.
//
//   node store.mjs snapshot <store.sqlite> <snapshot.sqlite>
//   node store.mjs restore  <snapshot.sqlite> <fresh-store.sqlite>
//
// Both refuse while another process owns the store. A snapshot is complete
// only when its manifest (<snapshot>.manifest.json) exists; restore verifies
// the manifest digest and SQLite integrity before the store appears.
import { DatabaseSync } from 'node:sqlite';
import { createHash, randomBytes } from 'node:crypto';
import { open, readFile, rename, rm, stat, access } from 'node:fs/promises';
import { dirname, basename, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { ownStore } from './ownership.mjs';

export const MANIFEST_VERSION = 1;
const exists = async path => { try { await access(path); return true; } catch { return false; } };
async function sha256(path) {
  const hash = createHash('sha256');
  const handle = await open(path, 'r');
  try { for await (const chunk of handle.createReadStream()) hash.update(chunk); } finally { await handle.close(); }
  return hash.digest('hex');
}
async function fsyncFile(path) { const handle = await open(path, 'r'); try { await handle.sync(); } finally { await handle.close(); } }
async function fsyncDirectory(path) { const handle = await open(path, 'r'); try { await handle.sync(); } finally { await handle.close(); } }
function integrity(path) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const rows = db.prepare('PRAGMA integrity_check').all();
    if (rows.length !== 1 || Object.values(rows[0])[0] !== 'ok') throw new Error('integrity_check_failed');
    const tables = db.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type = 'table'").get().n;
    if (tables < 1) throw new Error('not_a_store');
  } finally { db.close(); }
}
const temporary = target => join(dirname(target), `.${basename(target)}.${randomBytes(6).toString('hex')}.tmp`);

export async function snapshotStore(storePath, outPath) {
  const out = resolve(outPath);
  const manifestPath = `${out}.manifest.json`;
  if (await exists(out) || await exists(manifestPath)) throw new Error('snapshot_exists');
  const owner = await ownStore(storePath);
  const tmp = temporary(out);
  try {
    if (!await exists(owner.storePath)) throw new Error('store_missing');
    const source = new DatabaseSync(owner.storePath);
    try {
      source.exec('PRAGMA busy_timeout=0');
      // A consistent copy that includes committed WAL frames.
      source.prepare('VACUUM INTO ?').run(tmp);
    } finally { source.close(); }
    integrity(tmp);
    await fsyncFile(tmp);
    const manifest = { version: MANIFEST_VERSION, sha256: await sha256(tmp), bytes: (await stat(tmp)).size,
      integrity: 'ok', createdAt: new Date().toISOString() };
    await rename(tmp, out);
    const manifestTmp = temporary(manifestPath);
    const handle = await open(manifestTmp, 'wx', 0o600);
    try { await handle.writeFile(JSON.stringify(manifest)); await handle.sync(); } finally { await handle.close(); }
    await rename(manifestTmp, manifestPath);
    await fsyncDirectory(dirname(out));
    return { snapshot: out, manifest: manifestPath, ...manifest };
  } catch (error) {
    await rm(tmp, { force: true });
    throw error;
  } finally { owner.release(); }
}

export async function restoreStore(snapshotPath, storePath) {
  const snapshot = resolve(snapshotPath);
  let manifest;
  try { manifest = JSON.parse(await readFile(`${snapshot}.manifest.json`, 'utf8')); } catch { throw new Error('manifest_missing'); }
  if (manifest.version !== MANIFEST_VERSION || typeof manifest.sha256 !== 'string') throw new Error('manifest_invalid');
  const owner = await ownStore(storePath);
  const target = owner.storePath;
  const tmp = temporary(target);
  try {
    // Restore only into a fresh store; never overwrite retained state.
    for (const path of [target, `${target}-wal`, `${target}-shm`]) if (await exists(path)) throw new Error('store_exists');
    const copy = await open(tmp, 'wx', 0o600);
    try { await copy.writeFile(await readFile(snapshot)); await copy.sync(); } finally { await copy.close(); }
    if (await sha256(tmp) !== manifest.sha256) throw new Error('snapshot_digest_mismatch');
    integrity(tmp);
    await rename(tmp, target);
    await fsyncDirectory(dirname(target));
    return { store: target, sha256: manifest.sha256 };
  } catch (error) {
    await rm(tmp, { force: true });
    throw error;
  } finally { owner.release(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [command, from, to] = process.argv.slice(2);
  const known = ['store_already_owned', 'store_missing', 'store_exists', 'snapshot_exists', 'manifest_missing',
    'manifest_invalid', 'snapshot_digest_mismatch', 'integrity_check_failed', 'not_a_store'];
  try {
    if (!from || !to || !['snapshot', 'restore'].includes(command)) throw new Error('usage');
    const result = command === 'snapshot' ? await snapshotStore(from, to) : await restoreStore(from, to);
    process.stdout.write(JSON.stringify({ category: `${command}_complete`, sha256: result.sha256 }) + '\n');
  } catch (error) {
    const category = error.message === 'usage' ? 'usage' : known.includes(error.message) ? error.message : 'store_operation_failed';
    process.stderr.write(JSON.stringify({ category }) + '\n');
    process.exitCode = category === 'usage' ? 64 : 1;
  }
}
