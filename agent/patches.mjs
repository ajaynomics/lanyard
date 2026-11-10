// Fixes applied to installed packages, after every `npm ci` (Dockerfile,
// bin/agent, bin/agent-test). Each is a literal replacement in one file: it
// applies once, is left alone when already applied, and fails the install
// when its text is gone, so an upgraded package that moved the code stops the
// build rather than shipping without the fix. test/tool-calls.test.mjs checks
// the fix itself.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// None today. pi-durable 1.5.1 fixed earendil-works/pi#11892 upstream (a
// scheduling pass now takes its pending set before it plans), which three
// patches here applied until then; test/tool-calls.test.mjs still checks it.
export const PATCHES = [];

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
