// A PDF's words on an agent's Sprite (agent/files.mjs): each page's text
// layer as pdftotext -layout reads it, and for a page that has none, what
// tesseract reads off the page drawn as a picture. Every page is marked
// "--- page N ---". The whole text goes next to the file, as <file>.txt; what
// is printed stops at a number of pages and characters.
//
//   node /opt/agent/pdf-text.mjs <file.pdf> <pages shown> <characters shown>
//
// Prints one JSON line: {ok: true, pages, shown, ocr: [page numbers], text,
// truncated, full} or {ok: false, error}. Runs poppler and tesseract with no
// shell, and nothing here reaches the network.
import { execFile } from 'node:child_process';
import { access, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const TIMEOUT = 120_000; // ms for one command
const OCR_PAGES = 50; // pages read by OCR at most; the rest are named
const DPI = '200';

export function run(command, args) {
  return new Promise((resolve, reject) => execFile(command, args, { timeout: TIMEOUT, maxBuffer: 64 * 1024 * 1024, encoding: 'utf8' },
    (error, stdout) => error ? reject(error) : resolve(stdout)));
}

// pdftotext ends each page with a form feed.
export function pagesOf(text) {
  const pages = text.split('\f');
  if (pages.length > 1 && pages.at(-1).trim() === '') pages.pop();
  return pages;
}

export function marked(pages) {
  return pages.map((page, index) => `--- page ${index + 1} ---\n${page.replace(/\s+$/, '')}`).join('\n\n');
}

export async function extract(file, { pagesShown = 30, charactersShown = 60_000, exec = run, scratch = tmpdir() } = {}) {
  const pages = pagesOf(await exec('pdftotext', ['-layout', '-enc', 'UTF-8', file, '-']));
  const ocr = [];
  let unread = 0;
  const dir = await mkdtemp(join(scratch, 'pdf-'));
  try {
    for (const [index, page] of pages.entries()) {
      if (page.trim()) continue;
      if (ocr.length >= OCR_PAGES) { unread++; continue; }
      const number = String(index + 1);
      const picture = join(dir, `page-${number}`);
      await exec('pdftoppm', ['-r', DPI, '-f', number, '-l', number, '-png', '-singlefile', file, picture]);
      pages[index] = await exec('tesseract', [`${picture}.png`, '-', '-l', 'eng']);
      ocr.push(index + 1);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
  const full = `${file}.txt`;
  await writeFile(full, marked(pages));
  const shown = Math.min(pages.length, pagesShown);
  let text = marked(pages.slice(0, shown));
  const truncated = shown < pages.length || text.length > charactersShown;
  if (text.length > charactersShown) text = text.slice(0, charactersShown);
  return { ok: true, pages: pages.length, shown, ocr, unread: unread || undefined, text, truncated, full };
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  const [file, pagesShown, charactersShown] = process.argv.slice(2);
  try {
    await access(file);
    const reply = await extract(file, { pagesShown: Number(pagesShown) || 30, charactersShown: Number(charactersShown) || 60_000 });
    process.stdout.write(`${JSON.stringify(reply)}\n`);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ ok: false, error: error?.path === file ? 'The file is not there.'
      : error?.code === 'ENOENT' ? 'pdftotext is not on this computer.' : 'The PDF could not be read.' })}\n`);
    process.exitCode = 1;
  }
}
