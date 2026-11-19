// A thread another install's sidecar ran, moved in with its workspace
// (docs/import.md). Rails names a copy of that install's store, put in this
// install's storage folder, and the thread's id there; the thread here starts
// with what its model saw there, as one entry, so the next answer follows on
// rather than starting over. Its system messages stay behind: this sidecar
// declares its own prompt and tools at the next run.
//
// The copy is read from a private copy of it, never opened in place: opening
// a store writes to it. One read per store per process, whatever the number
// of threads.
import { copyFile, mkdtemp, realpath, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, sep } from 'node:path';
import { Harness, createRegistry } from '@earendil-works/pi-durable';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { ApiError } from './state.mjs';

export const CARRIED = 'app.carried';

export function carrier({ storePath, models, context }) {
  // The storage folder the sidecar's store lives in (storage/agent/durable.sqlite).
  const root = dirname(dirname(storePath));
  const opened = new Map();

  async function open(store) {
    let path;
    try { path = await realpath(store); } catch { throw new ApiError(422, 'invalid_carry'); }
    const within = await realpath(root);
    if (!path.startsWith(within + sep) || !(await stat(path)).isFile()) throw new ApiError(422, 'invalid_carry');
    if (!opened.has(path)) opened.set(path, (async () => {
      const folder = await mkdtemp(join(tmpdir(), 'carry-'));
      await copyFile(path, join(folder, 'store.sqlite'));
      const harness = await Harness.open(await openNodeSqliteStorage(join(folder, 'store.sqlite')), { models, registry: createRegistry() },
        context, { readOnly: true });
      return { harness, folder };
    })());
    return (await opened.get(path)).harness;
  }

  return {
    valid(carry) {
      if (carry === undefined) return undefined;
      if (!carry || typeof carry !== 'object' || typeof carry.store !== 'string' || !Number.isSafeInteger(carry.conversationId))
        throw new ApiError(422, 'invalid_carry');
      return { store: carry.store, conversationId: carry.conversationId };
    },
    // The model messages of the thread there, as its next request would send them.
    async messages(carry) {
      const harness = await open(carry.store);
      let view;
      try { view = await (await harness.conversation(carry.conversationId, context)).context(context); } catch { throw new ApiError(422, 'invalid_carry'); }
      if (view.entries.length === 0) throw new ApiError(422, 'invalid_carry');
      return view.messages.filter(message => message.role !== 'system');
    },
    async close() {
      for (const pending of opened.values()) {
        const { harness, folder } = await pending.catch(() => ({}));
        await harness?.close(context).catch(() => {});
        if (folder) await rm(folder, { recursive: true, force: true });
      }
      opened.clear();
    }
  };
}
