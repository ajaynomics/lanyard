// Fixes applied to installed packages, after every `npm ci` (Dockerfile,
// bin/agent, bin/agent-test). Each is a literal replacement in one file: it
// applies once, is left alone when already applied, and fails the install
// when its text is gone, so an upgraded package that moved the code stops the
// build rather than shipping without the fix. test/tool-calls.test.mjs checks
// the fix itself.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PATCHES = [{
  // earendil-works/pi#11892, closed upstream without a fix: a turn whose tool
  // calls run in parallel can hang. A reservation pass (#planReservation)
  // drops a waiting generation while a tool it waits on still reads as live,
  // through #waitingOn, which records no key. If that tool's ending commit is
  // in flight, its publication re-adds the generation to the run list and
  // the pass then deletes it again: nothing ever runs it. Recording each
  // task's key makes the pass's decision region wait for that commit and
  // decide again, as it does for every other read.
  name: 'pi-durable: a parallel tool round wakes its generation (pi#11892)',
  file: 'node_modules/@earendil-works/pi-durable/dist/harness/scheduler.js',
  before: `        if (!first)
            return record.state.on.filter((id) => this.#live.has(id));
        const live = record.state.on.find((id) => this.#live.has(id));`,
  after: `        // Keyed, so a region that finds a task of \`on\` live waits for an unpublished commit that ends it, and decides again
        // (patched by agent/patches.mjs, earendil-works/pi#11892).
        const isLive = (id) => {
            this.#record(taskKey(id));
            return this.#live.has(id);
        };
        if (!first)
            return record.state.on.filter(isLive);
        const live = record.state.on.find(isLive);`,
}];

const root = dirname(fileURLToPath(import.meta.url));

// 'applied' (now), 'present' (before) or 'missing' (neither text is there).
export function apply(patch, base = root) {
  const path = join(base, patch.file);
  const text = readFileSync(path, 'utf8');
  if (text.includes(patch.after)) return 'present';
  if (text.split(patch.before).length !== 2) return 'missing';
  writeFileSync(path, text.replace(patch.before, patch.after));
  return 'applied';
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let failed = false;
  for (const patch of PATCHES) {
    const outcome = apply(patch);
    if (outcome === 'missing') { failed = true; console.error(`patches: ${patch.name}: its code has changed in ${patch.file}; review the fix against the new version`); }
    else if (outcome === 'applied') console.log(`patches: ${patch.name}`);
  }
  process.exit(failed ? 1 : 0);
}
