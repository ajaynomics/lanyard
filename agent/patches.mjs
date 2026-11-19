// Fixes applied to installed packages, after every `npm ci` (Dockerfile,
// bin/agent, bin/agent-test). Each is a literal replacement in one file: it
// applies once, is left alone when already applied, and fails the install
// when its text is gone, so an upgraded package that moved the code stops the
// build rather than shipping without the fix. test/tool-calls.test.mjs checks
// the fix itself.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

// pi-durable 1.5.1 fixed earendil-works/pi#11892 upstream (a scheduling pass
// now takes its pending set before it plans), which three patches here applied
// until then; test/tool-calls.test.mjs still checks it.
//
// Code mode's images. A script gets a schema-less tool's text and nothing of
// its images (codemode.js outcomeOf and textOf), and `image()` needs the
// image block it never got: a screenshot from `desktop` or `visit_website`
// in a script never reached the model. Each image such a call returns is
// kept, by call, and the last SHOWN_TOOL_IMAGES follow the script's output,
// as `image()`'s do (saved to a file, its path beside it); the model is told
// how many earlier ones were left out. What the script sees is unchanged, so
// a script started before the patch replays the same. Kept from each call's
// stored result, so a script resumed after a restart shows the same images.
// test/codemode-results.test.mjs checks it.
const CODEMODE = 'node_modules/@earendil-works/pi-durable/dist/codemode/codemode.js';
export const PATCHES = [{
  name: 'pi-durable codemode: a call keeps the images of each schema-less tool the script called',
  file: CODEMODE,
  before: `    generatedImages = 0;\n`,
  after: `    generatedImages = 0;\n    /** Images schema-less tools returned, by VM call ID (patched by agent/patches.mjs). */\n    toolImages = new Map();\n`
}, {
  name: 'pi-durable codemode: each schema-less call\'s images are kept',
  file: CODEMODE,
  before: `        const outcome = outcomeOf(call.name, structured, result);\n`,
  after: `        const outcome = outcomeOf(call.name, structured, result);\n        if (!structured)\n            this.toolImages.set(call.id, imagesOf(result.structuredOutput));\n`
}, {
  name: 'pi-durable codemode: the last images follow the script\'s output',
  file: CODEMODE,
  before: `        const formatted = await formatResult(result, {`,
  after: `        const formatted = await formatResult(withToolImages(result, this.toolImages), {`
}, {
  name: 'pi-durable codemode: images of a tool\'s output, and the output with them',
  file: CODEMODE,
  before: `function errorResult(message) {`,
  after: `/** Images a script's tool calls returned that the model sees (patched by agent/patches.mjs). */
const SHOWN_TOOL_IMAGES = 3;
/** The image blocks of a schema-less tool's collapsed output: one image, or an array of text and image blocks. */
function imagesOf(value) {
    return (Array.isArray(value) ? value : [value]).filter((item) => typeof item === "object" && item !== null && item.type === "image" && typeof item.data === "string");
}
/** The script's output, then the last images its tool calls returned, in call order, and how many were left out. */
function withToolImages(result, toolImages) {
    const images = [...toolImages.entries()].sort(([a], [b]) => a - b).flatMap(([, list]) => list);
    if (images.length === 0)
        return result;
    const left = images.length - SHOWN_TOOL_IMAGES;
    const note = left <= 0 ? [] : [{
            type: "text",
            text: \`\${left} earlier \${left === 1 ? "image from the script's tool calls is" : "images from the script's tool calls are"} left out; the last \${SHOWN_TOOL_IMAGES} follow.\`,
        }];
    const shown = images.slice(-SHOWN_TOOL_IMAGES).map(({ data, mimeType }) => ({ type: "image", data, mimeType }));
    return { ...result, output: [...result.output, ...note, ...shown] };
}
function errorResult(message) {`
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
