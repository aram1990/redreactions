// Responsive Images -- ArticleCard derivative generator.
//
// Discovers the CURRENT live article inventory automatically (no manually-maintained slug list),
// and generates small, WebP, card-only derivatives for every article whose local hero image can
// produce at least one derivative without upscaling. Run manually with `npm run images:responsive`;
// NOT part of `npm run build`, so ordinary builds stay fast and don't touch image assets.
//
// Originals under public/images/articles/ are never read-written in place -- this script only ever
// writes into public/images/responsive/, and the canonical hero used for OG/Twitter/ArticleLayout
// is completely untouched. Frontmatter is parsed with the `yaml` package (already resolved in the
// lockfile via Astro's own toolchain) rather than a hand-rolled regex, so quoted strings, multiline
// blocks, arrays, apostrophes and comments are all handled correctly.
//
// Output: public/images/responsive/articles/<slug>/{480,768,1200}.webp
// Manifest: src/data/responsive-images.json -- { [slug]: { widths: number[], sourceWidth, sourceHeight } }
// ArticleCard reads the manifest at build time; articles absent from it (drafts, missing sources,
// sources too small for even a 480px derivative) render exactly as before -- plain <img>, no srcset.

import sharp from 'sharp';
import { parse as parseYaml } from 'yaml';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const ARTICLES_DIR = path.join(ROOT, 'src/content/articles');
const RESPONSIVE_DIR = path.join(ROOT, 'public/images/responsive/articles');
const MANIFEST_PATH = path.join(ROOT, 'src/data/responsive-images.json');
const CANDIDATE_WIDTHS = [480, 768, 1200];
const QUALITY = 78;

function readFrontmatter(mdxPath) {
  // Normalize CRLF -> LF first: several MDX files in this repo use Windows line endings, and the
  // stray \r left inside the sliced frontmatter block otherwise trips the YAML tokenizer right at
  // the end of quoted scalars (e.g. `heroImagePosition: "50% 50%"\r`).
  const raw = fs.readFileSync(mdxPath, 'utf8').replace(/\r\n/g, '\n');
  if (!raw.startsWith('---')) return null;
  const end = raw.indexOf('\n---', 3);
  if (end === -1) return null;
  const block = raw.slice(3, end);
  return parseYaml(block);
}

function discoverLiveArticles() {
  const files = fs.readdirSync(ARTICLES_DIR).filter(f => f.endsWith('.mdx'));
  const live = [];
  for (const file of files) {
    const mdxPath = path.join(ARTICLES_DIR, file);
    let fm;
    try {
      fm = readFrontmatter(mdxPath);
    } catch (e) {
      console.warn(`SKIP (frontmatter parse failed): ${file} -- ${e.message}`);
      continue;
    }
    if (!fm) { console.warn(`SKIP (no frontmatter found): ${file}`); continue; }
    if (fm.draft === true) continue; // drafts never get derivatives
    if (!fm.heroImage) { console.warn(`SKIP (no heroImage): ${file}`); continue; }
    const slug = (fm.slug || file.replace(/\.mdx$/, '')).toString();
    live.push({ slug, heroImage: fm.heroImage });
  }
  return live;
}

async function processArticle({ slug, heroImage }) {
  if (/^https?:\/\//.test(heroImage)) {
    return { slug, status: 'skipped', reason: 'remote heroImage (not supported for derivatives)' };
  }
  const srcPath = path.join(ROOT, 'public', heroImage.replace(/^\//, ''));
  if (!fs.existsSync(srcPath)) {
    return { slug, status: 'skipped', reason: `source file missing: ${heroImage}` };
  }

  let meta;
  try {
    meta = await sharp(srcPath).metadata();
  } catch (e) {
    return { slug, status: 'error', reason: `sharp could not read source: ${e.message}` };
  }
  if (!meta.width || !meta.height) {
    return { slug, status: 'error', reason: 'source has no readable dimensions' };
  }

  // Never upscale: only widths at or below the source's actual width, deduped.
  const widths = [...new Set(CANDIDATE_WIDTHS.filter(w => w <= meta.width))];
  if (widths.length === 0) {
    return { slug, status: 'skipped', reason: `source narrower than smallest tier (${meta.width}px)`, sourceWidth: meta.width };
  }

  const outDir = path.join(RESPONSIVE_DIR, slug);
  fs.mkdirSync(outDir, { recursive: true });
  const srcMtime = fs.statSync(srcPath).mtimeMs;

  const generated = [];
  for (const w of widths) {
    const outPath = path.join(outDir, `${w}.webp`);
    // Incremental: skip regenerating a derivative that already exists and is newer than its source.
    if (fs.existsSync(outPath) && fs.statSync(outPath).mtimeMs >= srcMtime) {
      generated.push(w);
      continue;
    }
    try {
      await sharp(srcPath).resize({ width: w }).webp({ quality: QUALITY }).toFile(outPath);
      generated.push(w);
    } catch (e) {
      console.warn(`WARN: failed to generate ${slug}/${w}.webp -- ${e.message}`);
    }
  }

  if (generated.length === 0) {
    return { slug, status: 'error', reason: 'all derivative writes failed' };
  }

  return { slug, status: 'ok', widths: generated, sourceWidth: meta.width, sourceHeight: meta.height };
}

async function run() {
  const start = Date.now();
  let live;
  try {
    live = discoverLiveArticles();
  } catch (e) {
    // Discovery itself failing is systemic -- fail the whole step rather than write a bogus manifest.
    console.error('FATAL: could not discover live article inventory:', e);
    process.exit(1);
  }

  const manifest = {};
  const results = { ok: [], skipped: [], error: [] };

  for (const article of live) {
    const result = await processArticle(article);
    if (result.status === 'ok') {
      manifest[result.slug] = { widths: result.widths, sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight };
      results.ok.push(result);
    } else if (result.status === 'skipped') {
      results.skipped.push(result);
    } else {
      console.warn(`WARN: ${result.slug} excluded from responsive manifest -- ${result.reason}`);
      results.error.push(result);
    }
  }

  // Prune derivative directories for slugs that are no longer live (renamed/removed articles).
  const liveSlugs = new Set(live.map(a => a.slug));
  let pruned = 0;
  if (fs.existsSync(RESPONSIVE_DIR)) {
    for (const dir of fs.readdirSync(RESPONSIVE_DIR)) {
      if (!liveSlugs.has(dir)) {
        fs.rmSync(path.join(RESPONSIVE_DIR, dir), { recursive: true, force: true });
        pruned++;
      }
    }
  }

  fs.mkdirSync(path.dirname(MANIFEST_PATH), { recursive: true });
  fs.writeFileSync(MANIFEST_PATH, JSON.stringify(manifest, null, 2) + '\n');

  const variantCounts = { 3: 0, 2: 0, 1: 0 };
  for (const r of results.ok) variantCounts[r.widths.length] = (variantCounts[r.widths.length] || 0) + 1;

  console.log(`\nLive articles discovered: ${live.length}`);
  console.log(`Responsive-enabled: ${results.ok.length}`);
  console.log(`  3 variants: ${variantCounts[3] || 0}`);
  console.log(`  2 variants: ${variantCounts[2] || 0}`);
  console.log(`  1 variant:  ${variantCounts[1] || 0}`);
  console.log(`Skipped (0 variants, e.g. source < 480px): ${results.skipped.length}`);
  console.log(`Errors (excluded from manifest): ${results.error.length}`);
  if (pruned > 0) console.log(`Pruned stale derivative directories: ${pruned}`);
  console.log(`\nManifest written: ${MANIFEST_PATH} (${Object.keys(manifest).length} entries)`);
  console.log(`Done in ${((Date.now() - start) / 1000).toFixed(1)}s`);
}

run();
