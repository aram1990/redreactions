// Responsive Images Phase 1 -- ArticleCard pilot.
//
// Generates small, WebP, card-only derivatives for a controlled pilot set of article heroes.
// Run manually with `npm run images:responsive`; NOT part of `npm run build`, so ordinary builds
// stay fast and don't touch image assets. Originals under public/images/articles/ are never
// read-written in place -- this script only ever writes into public/images/responsive/, and the
// canonical hero used for OG/Twitter/ArticleLayout is completely untouched.
//
// Output: public/images/responsive/articles/<slug>/{480,768,1200}.webp
// Manifest: src/data/responsive-images.json -- { [slug]: { widths: number[], sourceWidth, sourceHeight } }
// ArticleCard reads the manifest at build time; articles absent from it render exactly as before.

import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const CANDIDATE_WIDTHS = [480, 768, 1200];
const QUALITY = 78;

// Pilot set only -- Phase 1 is deliberately not sitewide. Extending this list is the entire
// mechanism for growing the pilot later; no other code needs to change.
const PILOT = {
  'eleven-explained-stranger-things': '/images/articles/eleven-explained-stranger-things/eleven-millie-bobby-brown-stranger-things-5.jpg',
  'kingdom-hearts-4-everything-we-know': '/images/articles/kingdom-hearts-4-everything-we-know/kingdom-hearts-iv-d23-2026-showcase-trailer.jpg',
  'peter-petrelli-explained-heroes': '/images/articles/peter-petrelli-explained-heroes/milo-ventimiglia-peter-petrelli-comic-con-2007.jpg',
  'gta6-trailer-2-breakdown': '/images/articles/gta6-trailer-2-breakdown/gta6-trailer2-hero.jpg',
  'gta6-everything-we-know': '/images/articles/gta6-everything-we-know/gta6-hero-jason-lucia.webp',
  'absolute-batman-explained': '/images/articles/absolute-batman-explained/absolute-batman-hero.webp',
  'dc-next-level-explained': '/images/articles/dc-next-level-explained/dc-next-level-promo-corona.jpg',
  'silo-season-4-everything-we-know': '/images/articles/silo-season-4-everything-we-know/silo-season-3-key-art-wide.webp',
  'insidious-out-of-the-further-review': '/images/articles/insidious-out-of-the-further-review/gemma-trapped-attic-vent.jpg',
  'x-men-97-explained': '/images/articles/x-men-97-explained/x-men-97-explained-hero.jpg',
  'witcher-3-remastered-release-date-songs-of-the-past': '/images/articles/witcher-3-remastered-release-date-songs-of-the-past/witcher-3-remastered-hero.webp',
  'marvels-wolverine-d23-trailer': '/images/articles/marvels-wolverine-d23-trailer/marvels-wolverine-d23-hero.jpg',
};

async function run() {
  const start = Date.now();
  const manifest = {};
  const outBase = path.join(ROOT, 'public/images/responsive/articles');

  for (const [slug, heroPublicPath] of Object.entries(PILOT)) {
    const srcPath = path.join(ROOT, 'public', heroPublicPath.replace(/^\//, ''));
    if (!fs.existsSync(srcPath)) { console.error('MISSING SOURCE:', slug, srcPath); continue; }

    const meta = await sharp(srcPath).metadata();
    // Never upscale: only generate widths at or below the source's actual width, and dedupe.
    const widths = [...new Set(CANDIDATE_WIDTHS.filter(w => w <= meta.width))];
    if (widths.length === 0) { console.warn('SKIPPED (source narrower than smallest tier):', slug, meta.width); continue; }

    const outDir = path.join(outBase, slug);
    fs.mkdirSync(outDir, { recursive: true });

    for (const w of widths) {
      const outPath = path.join(outDir, `${w}.webp`);
      await sharp(srcPath).resize({ width: w }).webp({ quality: QUALITY }).toFile(outPath);
    }

    manifest[slug] = { widths, sourceWidth: meta.width, sourceHeight: meta.height };
    console.log('generated', slug, '->', widths.join(','));
  }

  const manifestPath = path.join(ROOT, 'src/data/responsive-images.json');
  fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
  fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
  console.log(`\nManifest written: ${manifestPath}`);
  console.log(`Done in ${((Date.now() - start) / 1000).toFixed(1)}s`);
}

run();
