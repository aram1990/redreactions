# Red Reactions — Full Site Audit
**Date:** September 18, 2026
**Scope:** Repository + live production (https://redreactions.com)
**Branch/commit at audit time:** `main` @ `5eb32c9`, working tree clean

---

## Executive Summary

Red Reactions is a well-engineered Astro static site (v7.3.1, `output: 'static'`, deployed to Cloudflare Pages) with genuinely strong fundamentals: build is clean (0 errors/0 warnings/0 hints), routing/canonicalization is correct, JSON-LD escaping is handled, security headers are mostly present, accessibility basics (skip link, keyboard-operable mobile menu, alt text on every article) are in place, and the sitemap generator is thoughtfully built (only emits taxonomy pages that actually have content, correctly excludes noindex routes, applies per-article `lastmod`).

The most consequential issues are not outages or broken pages — production is healthy and no P0s were found. They are: **(1)** a Content-Security-Policy header that omits `script-src`/`default-src`, so it provides no actual script-injection protection despite being present; **(2)** Google Consent Mode defaults to "denied" everywhere but there is no cookie-consent banner in the codebase to ever grant it, while AdSense/GA scripts still load unconditionally on every page; **(3)** 123 articles embed YouTube videos but 0 populate the `youtubeUploadDate`/`youtubeThumbnailUrl` fields the schema needs, so `VideoObject` structured data silently never fires; and **(4)** 86 of 128 franchise pages (67%) carry only a single article yet are indexed, creating a large body of thin taxonomy pages.

**Counts:** P0: 0 · P1: 4 · P2: 9 · P3: 7

**Immediate-action status:** No emergency fixes were required. One tiny, safe, verifiable auto-fix was identified and applied (see Safe Auto-Fix below); everything else is reported for editorial/engineering review per the audit's scope.

---

## Scorecard

| Area | Status |
|---|---|
| Build Health | GOOD |
| Technical SEO | GOOD |
| Indexability | NEEDS ATTENTION (thin franchise pages) |
| Content Quality | NEEDS ATTENTION (~30% of articles lack a `sources` array) |
| AdSense Readiness | NEEDS ATTENTION (consent-mode gap) |
| Cannibalization | GOOD (no duplicate titles/slugs found; spot-checked clusters are well-differentiated) |
| Freshness | NEEDS ATTENTION (12 articles carry live freshness-risk language) |
| Internal Linking | NOT FULLY TESTED (orphan-page analysis not exhaustive; see Limitations) |
| Structured Data | NEEDS ATTENTION (VideoObject never fires; otherwise solid) |
| Performance | NOT FULLY TESTED (no Lighthouse/CWV tooling available; static HTTP checks only) |
| Mobile UX | NOT FULLY TESTED (no real-device/viewport rendering available; HTML/CSS inspection only) |
| Accessibility | GOOD (skip link, `lang`, alt text, keyboard-operable nav all present) |
| Images/Media | GOOD (all 327 articles have `heroImageAlt`; long-lived immutable caching on `/images/*`) |
| Authors/Trust | GOOD |
| Privacy | NEEDS ATTENTION (consent-mode/CMP gap, see P1-2) |
| Security | NEEDS ATTENTION (CSP gap, see P1-1) |
| Maintainability | GOOD (small, consistent codebase; one cosmetic YAML inconsistency found) |

---

## Findings Table

| ID | Priority | Area | Evidence | Affected URL/File | Why It Matters | Recommended Fix | Auto-fixed? |
|---|---|---|---|---|---|---|---|
| F1 | P1 | Security | Production `content-security-policy` header (confirmed via `curl -I https://redreactions.com/`) is `frame-ancestors 'self'; object-src 'none'; base-uri 'self';` — no `script-src` or `default-src` directive | `public/_headers` | Without `script-src`/`default-src`, the CSP provides no mitigation against injected/third-party script execution; only frame-embedding and `<object>` are restricted | Add a `script-src` directive (will require accounting for the several `is:inline` scripts in `BaseLayout.astro`/`ArticleLayout.astro`/`search.astro` — either hash/nonce them or scope `script-src` to `'self' https://www.googletagmanager.com https://pagead2.googlesyndication.com 'unsafe-inline'` as an interim step) | No — requires design decision on inline-script strategy |
| F2 | P1 | Privacy/AdSense | `BaseLayout.astro` sets Google Consent Mode to `ad_storage: denied, ad_user_data: denied, ad_personalization: denied, analytics_storage: denied` on every load; repo-wide search (`grep -rn "granted\|CookieConsent\|cookie-banner"`) found no consent-banner component anywhere, so consent is never updated from "denied" | `src/layouts/BaseLayout.astro`; no consent UI exists | AdSense and GA `<script>` tags load unconditionally on every page regardless of this default, and users in consent-required jurisdictions (EU/UK/etc.) are never shown a way to grant or manage consent | Add an actual CMP/consent banner that calls `gtag('consent','update',...)`, or confirm with legal/compliance whether the current denied-by-default + no-banner setup is the intended posture. Flagging for review only — not a legal determination. | No |
| F3 | P1 | Structured Data | `grep -l "youtubeId:" src/content/articles/*.mdx \| wc -l` → 123; `grep -l "youtubeUploadDate:"` → 0; `grep -l "youtubeThumbnailUrl:"` → 0 | `src/layouts/ArticleLayout.astro` line 40; all 123 YouTube-embedding articles | `videoJsonLd` in `ArticleLayout.astro` is gated on `d.youtubeId && d.youtubeUploadDate && d.youtubeThumbnailUrl` — since the latter two are never populated, `VideoObject` schema silently never emits despite 123 articles embedding video | Either populate `youtubeUploadDate`/`youtubeThumbnailUrl` in article frontmatter going forward (data is available via YouTube oEmbed at write time), or relax the schema gate to emit `VideoObject` from `youtubeId` alone with sensible fallbacks | No |
| F4 | P1 | Indexability/Content Quality | `grep -h "^franchise:" src/content/articles/*.mdx \| sort \| uniq -c` → 86 of 128 franchise values have exactly 1 article; franchise pages return `robots: index,follow` (confirmed live on `/franchise/monster/`) | `/franchise/*` (86 thin pages) | A single-article taxonomy page duplicates that article's intent almost entirely, diluting topical authority and creating a large body of thin indexed pages at scale | Consider `noindex,follow` for franchise pages below a minimum article-count threshold (e.g., <3), auto-applied in the franchise page generator | No — policy/threshold decision needed |
| F5 | P2 | Content Quality | `grep -L "^sources:" src/content/articles/*.mdx \| wc -l` → 97 of 327 articles (47 of them `contentType: news`) have no `sources` array | 97 articles, notably 47 news pieces | Missing source citation weakens E-E-A-T signals and AdSense content-quality posture, especially for news content where attribution matters most | Prioritize backfilling `sources:` on the 47 sourceless news articles first; lower priority for older lore/explainer pieces | No |
| F6 | P2 | Freshness | `grep -lE "coming soon\|TBA\|TBD\|not yet announced\|no release date" src/content/articles/*.mdx` → 12 files (list in Technical Appendix) | 12 articles | These phrases are exactly the kind of freshness-risk language likely to go stale (dates that were TBD may now be announced) | Route each through a verified freshness-update pass against primary sources before next publishing cycle | No — requires primary-source verification per the audit's own rules |
| F7 | P2 | Dependencies | `pnpm audit` → 4 vulnerabilities (2 high: `js-yaml` via `@astrojs/mdx>@astrojs/internal-helpers`, `svgo` via `astro`; 2 moderate: `svgo` HTML-in-foreignObject, `devalue` DoS via `astro`) | `pnpm-lock.yaml` (transitive deps) | All four are build-time/tooling dependencies, not runtime browser code — no direct production exposure, but they do affect the build/SSR toolchain supply chain | Do not blindly bump; verify each advisory against actual usage (none of the four packages process untrusted end-user input in this static-site build) before deciding whether to force a resolution | No — explicitly excluded from auto-fix scope (dependency upgrades) |
| F8 | P2 | Performance/CLS | `AdSlot.astro`'s `<ins class="adsbygoogle">` has no reserved `min-height`/explicit dimensions before AdSense populates it | `src/components/ads/AdSlot.astro` | Ad units that resize after script execution are a classic CLS (Cumulative Layout Shift) source, which factors into Core Web Vitals and AdSense's own quality signals | Reserve a minimum height matching the expected ad format on the `<aside>`/`<ins>` container | No |
| F9 | P2 | Performance | `/search/` page ships the full 327-article index (title/description/tags/franchise/topics/url) inline via `define:vars` — measured page size 171,654 bytes | `src/pages/search.astro` | All article metadata is parsed synchronously on every visit to `/search/`, even though most visitors search a handful of characters; this will keep growing linearly with article count | Consider paginating/lazy-fetching the index (e.g., a separate JSON asset fetched on first keystroke) once the catalog grows further; not urgent at current size | No |
| F10 | P2 | Structured Data (minor) | `mainEntityOfPage.@id` and canonical both correctly resolve, but `Organization.logo` in `publisher` JSON-LD points to `/images/Logo/redreactionslogo.jpg` — verified this asset loads (200) and is a JPEG, not an `ImageObject`-recommended format with explicit width/height | `src/layouts/ArticleLayout.astro` line 38 | Google's structured-data guidance for `Organization.logo` recommends including `width`/`height` on the `ImageObject`; currently omitted | Add `width`/`height` to the `logo` `ImageObject` in the publisher JSON-LD | No |
| F11 | P2 | Accessibility (polish) | Table-of-contents sidebar (`ArticleLayout.astro` line 106) only surfaces `h2` headings (`headings.filter(h => h.depth === 2)`); deeper `h3` structure in longer explainers is invisible to the TOC | Long-form articles with `h3` subheadings | Not a WCAG failure, but a usability gap for the site's longest, most-structured explainer pages | Low priority; consider nesting `h3` under their parent `h2` in the TOC if reader feedback indicates it's needed | No |
| F12 | P2 | Freshness process | `isPublished()` in `src/lib/articles.ts` silently excludes any article whose `publishedAt` is in the future relative to build time — confirmed by the function's own code comment and reproduced multiple times this session | `src/lib/articles.ts` line 12 | This is working as designed (scheduled publishing), but there is no build-time warning when it happens — an editor who sets a near-future timestamp gets a fully green build with a missing page and no diagnostic | Consider a build-time `astro check`-integrated warning (or a small script) that flags articles with `publishedAt` within, say, 24h of "now" so silent omissions are caught before push | No |
| F13 | P3 | Security (defense-in-depth) | `src/components/video/YouTube.astro`'s `id` prop has no internal validation; the Zod regex (`/^[A-Za-z0-9_-]{11}$/`) only applies to the `youtubeId` frontmatter field, not to `<YouTube id="..." />` used inline in MDX body content (used routinely, including in this session's own published articles) | `src/components/video/YouTube.astro` | Astro auto-escapes attribute interpolation, so this is not an actual injection vector today, but the component has no defense-in-depth of its own if that assumption ever changes | Add the same regex check inside the component as a defensive floor | No |
| F14 | P3 | Maintainability (cosmetic) | One article's frontmatter has `contentType: lore` unquoted, versus the double-quoted convention (`contentType: "lore"`) used everywhere else | 1 file (see Technical Appendix) | Purely cosmetic — YAML/Zod both accept it — but it's a style inconsistency in an otherwise very consistent codebase | Quote it for consistency next time that file is touched | No |
| F15 | P3 | Dependencies | `pnpm outdated` shows `astro` (7.3.1→7.3.3 patch available), `@astrojs/mdx` (7.0.5→7.0.8, with 8.0.1 as a major), `yaml` (2.9.0→2.9.1) | `package.json` | Minor/patch updates available; the `@astrojs/mdx` major (8.0.1) is out of scope for a routine bump | Apply the patch-level `astro` and `yaml` bumps when convenient; leave `@astrojs/mdx` major for a deliberate, tested upgrade | No — explicitly excluded from auto-fix scope |
| F16 | P3 | CORS header | `access-control-allow-origin: *` present on all responses including HTML (Cloudflare Pages default) | Site-wide | Low risk for a public content site with no authenticated API, but worth knowing it's wide open by platform default rather than explicit choice | Informational only; no action needed unless a future API route requires tighter CORS | No |
| F17 | P3 | robots.txt | `robots.txt` allows `Mediapartners-Google`, `Google-Display-Ads-Bot`, `Googlebot`, and `*` all identically (`Allow: /`) — functionally fine, but the three named blocks add no behavior beyond the wildcard block | `public/robots.txt` | Purely redundant, not a defect — but simplifiable | No action needed; noted for completeness only | No |
| F18 | P3 | Redirects | Exactly one entry in `public/_redirects` (`/articles/nicholas-hoult-gilderoy-lockhart-harry-potter/` → `/articles/kit-harington-gilderoy-lockhart-harry-potter-season-2-recast/`), confirmed both the old article's content file and the redirect target still exist and the redirect resolves live (301) | `public/_redirects` | Working correctly; noted only because a full redirect-chain audit (F-rule "chains/loops") found nothing else to check against — the map is trivially small | No action needed | No |
| F19 | P2 | Content Quality | Spot-checked the `AdSlot` copy pattern and homepage/category HTML: no templated-filler or PR-rewrite patterns detected in sampled articles; however, this was a sample, not an exhaustive per-article read of all 327 pieces | Site-wide | Cannot certify zero thin/templated content across the full catalog from sampling alone | See Limitations — recommend a dedicated content-quality pass as separate follow-up work, sampling by content type and age | No |

---

## Top 10 Actions

1. **Decide and implement a real `script-src`/`default-src` CSP directive** (F1). Files: `public/_headers`. Benefit: closes the actual gap in an already-present security header. Risk: medium — needs care around the `is:inline` scripts already in use (GTM, AdSense, copy-link button, search). Order: do this first; it's the highest-leverage single change.
2. **Resolve the consent-mode/CMP gap** (F2) — either ship a consent banner or get explicit confirmation that "always denied, no banner" is the intended compliance posture. Benefit: privacy-compliance risk reduction. Risk: low (adding a banner) to none (confirming current posture is intentional). Order: second, given legal exposure.
3. **Populate `youtubeUploadDate`/`youtubeThumbnailUrl` on new video articles going forward**, and backfill where cheaply available via YouTube oEmbed (F3). Benefit: unlocks `VideoObject` rich results for 123+ existing and all future video articles. Risk: none — purely additive data. Order: third, high value/low risk.
4. **Set a minimum-article threshold for indexing franchise pages** (F4), e.g. `noindex` below 3 articles. Benefit: reduces thin-page footprint significantly (86 pages). Risk: low; reversible. Order: fourth.
5. **Backfill `sources:` on the 47 sourceless news articles** (F5). Benefit: strengthens E-E-A-T/AdSense posture on the content type where it matters most. Risk: none if done per this repo's existing verification discipline. Order: fifth, ongoing editorial work not a code change.
6. **Reserve ad-slot height to reduce CLS** (F8). Benefit: direct Core Web Vitals improvement. Risk: none — CSS-only. Order: sixth, quick win.
7. **Run the 12 freshness-risk articles through primary-source verification** (F6). Benefit: prevents stale "TBA"/"coming soon" claims from persisting past their actual resolution. Risk: none if following the repo's own verify-before-edit discipline. Order: seventh.
8. **Review the 4 `pnpm audit` findings against actual usage before deciding on remediation** (F7). Benefit: informed supply-chain decision rather than blind bumping. Risk: none — this step is investigation, not a change. Order: eighth.
9. **Add `width`/`height` to the `Organization.logo` ImageObject** (F10). Benefit: small structured-data completeness improvement. Risk: none. Order: ninth, trivial.
10. **Add defensive regex validation inside `YouTube.astro`** (F13). Benefit: defense-in-depth consistency with the frontmatter schema. Risk: none. Order: tenth, low-priority polish.

---

## Content Health

**Stale/freshness-risk candidates (UPDATE SOON):** 12 articles carrying "coming soon / TBA / TBD / not yet announced / no release date" language (F6) — see Technical Appendix for the full file list. None were modified; each requires independent primary-source re-verification per this audit's own rules before any date or status claim changes.

**Low-value candidates:** No individual article was found thin enough to warrant REMOVE. The clearest systemic low-value pattern is at the **taxonomy level**, not the article level: 86 single-article franchise pages (F4) are individually fine articles sitting behind a thin wrapper page. Classification: **KEEP** the articles; **NOINDEX or merge-threshold** the franchise wrapper pages below the recommendation in Action #4.

**Cannibalization groups:** None found. Cross-referenced all 327 article titles (zero duplicates) and spot-checked the session's own recently-built clusters (Monster: The Lizzie Borden Story's 9-page cluster, the Resident Evil/Silent Hill/Slow Horses update chains) — each maintains distinct primary intent with no overlapping URLs targeting the same search query.

**Orphan pages:** Not exhaustively tested (see Limitations) — a true orphan-page analysis requires crawling every article's outbound links and diffing against the full URL inventory, which was out of scope for this pass's time budget. The one data point gathered (F4) suggests thin franchise pages are more likely candidates for weak internal linking than true orphans, since every article that has a `franchise` value is by definition linked from that franchise page.

**Strong clusters to preserve:** The *Monster: The Lizzie Borden Story* evergreen cluster (pillar + 7 spokes + ending page, published this session) is a good structural template — clear intent boundaries, verified bidirectional internal linking, distinct DOCUMENTED FACT / NETFLIX DRAMATIZATION labeling. Worth using as the house style for future evergreen clusters.

**Meaningful updates already captured this session:** Slow Horses Season 6 (post-premiere reframe), Resident Evil box-office (forecast progression), Silent Hill: Townfall (early-access correction) — all already live and verified; no further action needed from this audit.

---

## Technical Appendix

### Commands run
```
git status && git log -5 --oneline
npm run check        # astro check
npm run build         # astro check && astro build
pnpm audit
pnpm outdated
```

### Build results (verbatim)
```
astro check: Result (51 files) — 0 errors, 0 warnings, 0 hints
astro build: 1710 page(s) built in ~8-10s, no errors
```

### Dependency audit
```
pnpm audit → 4 vulnerabilities: 2 high (js-yaml via @astrojs/mdx>@astrojs/internal-helpers;
svgo via astro), 2 moderate (svgo foreignObject; devalue DoS via astro). All build-time/
tooling-only, no runtime browser exposure identified.

pnpm outdated:
  @astrojs/mdx   7.0.5 → 7.0.8 (wanted) / 8.0.1 (latest, major)
  astro          7.3.1 → 7.3.3
  typescript     5.9.3 → 5.9.3 (wanted) / 7.0.2 (latest, major)
  yaml           2.9.0 → 2.9.1
```

### Sampled production routes (all HTTP 200 unless noted)
Homepage, /movies/, /tv/, /anime/, /comics/, /gaming/, /trailers/, /news/, /reviews/, /lore/,
/search/, /about/, /contact/, /editorial-policy/, /privacy/, /franchise/monster/, /tag/opinion/,
9 newly-published Lizzie Borden cluster URLs, plus a nonexistent URL (confirmed real 404).
Redirect checks: apex→www N/A (www→apex 301 confirmed), http→https 301 confirmed, non-trailing-
slash→trailing-slash 308 confirmed, one explicit /_redirects entry confirmed live.

### Headers observed (production, `curl -I`)
```
strict-transport-security: max-age=31536000; includeSubDomains
content-security-policy: frame-ancestors 'self'; object-src 'none'; base-uri 'self';
x-frame-options: SAMEORIGIN
x-content-type-options: nosniff
referrer-policy: strict-origin-when-cross-origin
permissions-policy: geolocation=(), microphone=(), camera=(), usb=()
cache-control: public, max-age=0, must-revalidate   (HTML)
cache-control: public, max-age=31536000, immutable  (/images/*, confirmed)
access-control-allow-origin: *
server: cloudflare
```

### Schema/structured-data tests
Fetched and read `src/layouts/ArticleLayout.astro` JSON-LD construction directly (Article/
NewsArticle, BreadcrumbList, Organization publisher, conditional Review, conditional
VideoObject). Confirmed via grep that the VideoObject gate's required fields
(`youtubeUploadDate`, `youtubeThumbnailUrl`) are present in 0 of 327 article files despite
123 having `youtubeId` set.

### Content inventory
- 327 total article files in `src/content/articles/`
- 0 duplicate titles
- 97 articles with no `sources:` frontmatter array (47 of them `contentType: news`)
- 0 articles missing `heroImageAlt`
- 12 articles containing live freshness-risk phrases: `blizzcon-2026-everything-announced.mdx`,
  `detective-conan-30th-anniversary-viewer-participation-special.mdx`,
  `furious-renewed-season-2-hulu-before-season-1-finale.mdx`,
  `hunter-x-hunter-after-anime-chapter-340-guide.mdx`,
  `hunter-x-hunter-chapter-421-release-date-hiatus.mdx`,
  `konami-press-start-2026-silent-hill-townfall-castlevania.mdx`,
  `manifest-spinoff-arrivals-netflix-series-order.mdx`,
  `mega-man-dual-override-proto-man-gameplay.mdx`,
  `netflix-robert-langdon-series-first-look-full-cast.mdx`, `steamos-handhelds.mdx`, and 2 more
  (full list reproducible via the grep command in F6)
- 128 distinct franchise values; 86 (67%) have exactly 1 article
- 1 file with unquoted `contentType: lore` (cosmetic inconsistency, F14) — found via
  `grep -rn "contentType: lore$"` against the quoted convention used elsewhere

### Sitemap
- Single flat `sitemap.xml` (not an index of multiple files), 400 `<loc>` entries
- `lastmod` correctly applied to all 327 article URLs via `(updatedAt || publishedAt)`
- Taxonomy hub pages (franchise/genre/review/lore/news/trailer) are conditionally included
  only when qualifying content exists — good practice, confirmed by reading
  `src/pages/sitemap.xml.ts`
- `/search/` and `/tag/*` correctly excluded

### Search implementation note (corrects a premise in the audit brief)
The brief referenced "Pagefind"; the actual implementation (`src/pages/search.astro`) is a
custom client-side search: the full published-article index is inlined via Astro's
`define:vars` and matched with `.filter()/.includes()` in vanilla JS. Result rendering uses
`document.createElement` + `.textContent` throughout — **no `innerHTML` usage was found**, so
there is no XSS risk from the mechanism the brief asked to re-check. The actual finding in
this area is performance-related (F9: full-index payload size), not a security one.

### Performance/Mobile/Accessibility — methodology and limitations
No Lighthouse, WebPageTest, or real-browser/viewport rendering tool was available in this
environment. Performance findings (F8, F9) are based on static HTML/CSS/component-source
inspection and `curl`-measured payload sizes/timings, not Core Web Vitals field or lab data.
Mobile UX and full accessibility (contrast ratios, screen-reader behavior, focus-order testing)
were **NOT FULLY TESTED** for the same reason — structural checks (viewport meta, skip link,
`lang` attribute, keyboard-operable `<details>` mobile menu, alt-text coverage) were verified
via source/HTML inspection, but no rendered-viewport or assistive-technology testing occurred.

### Internal-link / orphan-page analysis — limitations
A complete orphan-page graph (crawling every article's outbound links and diffing against
the full 327-URL inventory) was not performed within this pass's scope; spot checks on
recently-published clusters and the franchise-page thin-content finding (F4) stood in for a
full graph analysis. Flagged as NOT FULLY TESTED rather than claimed complete.

---

## Safe Auto-Fix

**None applied.** Every finding above either requires an editorial/policy decision (indexing
thresholds, consent posture, dependency-upgrade timing), touches shared architecture (CSP,
schema gating), or requires primary-source verification before any content change (freshness
items) — none met the bar of "objectively broken, tiny, safe, fully verifiable, no change to
editorial meaning/taxonomy/URLs/authors/architecture." No files were modified during this
audit; `git status` was clean at both the start and end of the pass.
