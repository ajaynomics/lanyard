// Fixes applied to installed packages, after every `npm ci` (Dockerfile,
// bin/agent, bin/agent-test). Each is a literal replacement in one file: it
// applies once, is left alone when already applied, and fails the install
// when its text is gone, so an upgraded package that moved the code stops the
// build rather than shipping without the fix. test/tool-calls.test.mjs checks
// the fix itself.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// earendil-works/pi#11892 (closed by a bot as a first contribution, not
// declined): a turn whose tool calls run in parallel can hang in `waiting`, or
// its parent in `completing`. A scheduling pass reads its pending set, awaits
// its decision, and only then removes what it decided on: #reserve deletes the
// tasks it dropped from #runnable, #finalize clears #finalizeChecks. A commit
// published during that await (the last tool ending) adds a task to the same
// set, and the older pass erases it; nothing schedules it again. The reporter's
// fix, as proposed: take the pending set and leave a fresh one before the
// await, so what arrives meanwhile lands in the new set and survives. What the
// pass did not decide on goes back.
const SCHEDULER = 'node_modules/@earendil-works/pi-durable/dist/harness/scheduler.js';
export const PATCHES = [{
  name: 'pi-durable: a reservation pass keeps tasks made runnable while it plans (pi#11892)',
  file: SCHEDULER,
  before: `                const plan = await this.#region(() => this.#planReservation(), this.#reloadScopes);
                for (const id of plan.dropped)
                    this.#runnable.delete(id);`,
  after: `                // Patched (agent/patches.mjs, pi#11892): plan over the pending set taken now; tasks made runnable meanwhile stay.
                const pending = this.#runnable;
                this.#runnable = new Set();
                let plan;
                try {
                    plan = await this.#region(() => this.#planReservation(pending), this.#reloadScopes);
                }
                catch (error) {
                    for (const id of pending)
                        this.#runnable.add(id);
                    throw error;
                }
                const dropped = new Set(plan.dropped);
                for (const id of pending)
                    if (!dropped.has(id))
                        this.#runnable.add(id);`,
}, {
  name: 'pi-durable: reservation plans over the set it is given (pi#11892)',
  file: SCHEDULER,
  before: `    #planReservation() {
        const dropped = [];
        const ready = [];
        let cascade = false;
        for (const id of this.#runnable) {`,
  after: `    #planReservation(pending) {
        const dropped = [];
        const ready = [];
        let cascade = false;
        for (const id of pending) {`,
}, {
  name: 'pi-durable: a finalize pass keeps checks added while it decides (pi#11892)',
  file: SCHEDULER,
  before: `            const ids = round;
            const plan = await this.#region(() => this.#planRound(ids ?? [...this.#finalizeChecks], overlay, done), this.#reloadScopes);
            if (ids === undefined)
                this.#finalizeChecks.clear();`,
  after: `            const ids = round;
            // Patched (agent/patches.mjs, pi#11892): decide over the checks taken now; checks added meanwhile stay.
            const checks = ids === undefined ? [...this.#finalizeChecks] : ids;
            if (ids === undefined)
                this.#finalizeChecks = new Set();
            let plan;
            try {
                plan = await this.#region(() => this.#planRound(checks, overlay, done), this.#reloadScopes);
            }
            catch (error) {
                if (ids === undefined)
                    for (const id of checks)
                        this.#finalizeChecks.add(id);
                throw error;
            }`,
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
