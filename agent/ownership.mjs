import { DatabaseSync } from 'node:sqlite';
import { realpath, mkdir } from 'node:fs/promises';
import { dirname, basename, join, resolve } from 'node:path';

// This separate DELETE-journal database is a kernel-held lock, not a lease.
// Hold it before the main Durable WAL database is opened for writing.
// The kernel releases it when the owner exits, including SIGKILL; there is no
// expiry, PID check or lock-file deletion. It relies on POSIX advisory locks on
// a local filesystem: a store on a network or shared volume mounted by more
// than one host (NFS, SMB, a multi-attach block volume) is unsupported, because
// those locks are not reliable across hosts. Fence the old process before the
// replacement starts instead of relying on this lock across machines.
export async function ownStore(path) {
  const absolute = resolve(path);
  await mkdir(dirname(absolute), { recursive: true, mode: 0o700 });
  const directory = await realpath(dirname(absolute));
  let storePath = join(directory, basename(absolute));
  try { storePath = await realpath(storePath); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const lock = new DatabaseSync(`${storePath}.owner.sqlite`);
  try {
    lock.exec('PRAGMA busy_timeout=0; PRAGMA journal_mode=DELETE; BEGIN EXCLUSIVE');
    lock.exec('CREATE TABLE IF NOT EXISTS ownership (singleton INTEGER PRIMARY KEY CHECK(singleton=1))');
    lock.exec('INSERT OR IGNORE INTO ownership VALUES (1)');
  } catch {
    lock.close();
    throw new Error('store_already_owned');
  }
  let closed = false;
  return { storePath, release() {
    if (closed) return;
    closed = true;
    try { lock.exec('ROLLBACK'); } finally { lock.close(); }
  } };
}
