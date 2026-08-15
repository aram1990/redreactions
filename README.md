# Red Reactions

An Astro, TypeScript and Tailwind entertainment publication designed for static delivery on Cloudflare Workers. It uses MDX Content Collections for editorial content and intentionally avoids a database, external CMS, and unnecessary client frameworks.

## Stack

- Astro + TypeScript + Tailwind CSS
- Astro Content Collections + MDX
- Cloudflare Workers adapter + Wrangler
- Static search index and RSS feed

## Structure

```
src/
  components/   reusable cards, SEO, ads, video, navigation, review UI
  config/       central site and social configuration
  content/      MDX editorial articles
  layouts/      base, article and category layouts
  lib/          published content, URLs, reading time and related-content logic
  pages/        homepage, archives, legal pages, search, RSS and dynamic routes
public/
  images/       licensed editorial images and development placeholders
```

## Local use

```bash
npm install
npm run dev
npm run check
npm run build
```

The build outputs a static site in `dist/`. To deploy after logging into Cloudflare:

```bash
npx wrangler deploy
```

## Editorial workflow

Create an `.mdx` file in `src/content/articles/`. The schema in `src/content.config.ts` validates every frontmatter field. Set `draft: true` to keep a post out of published routes, feeds and search. Use `featured: true` and `trending: true` for homepage placement. Ratings render the Red Score on `contentType: review`. Add an official YouTube ID to `youtubeId` for privacy-conscious embeds. Add sources as `{ name, url, publishedAt? }`.

Use a unique `slug`, meaningful `heroImageAlt`, and a locally stored licensed image under `public/images/articles/`. Do not hotlink third-party editorial images or copy third-party reporting.

## Configuration

Update `src/config/site.ts` for the site URL, social URLs, contact address, logo assets and default SEO image. Set `PUBLIC_ADSENSE_CLIENT` in `.env` only after an AdSense account is approved. `AdSlot` renders nothing when it is absent. Add the exact AdSense-supplied line to `public/ads.txt`; never invent a publisher ID.

Google CMP / AdSense Privacy & Messaging is not configured by this repository. Enable a certified CMP in the AdSense/Google interface and complete `privacy` and `cookies` with the selected vendor's real disclosure, jurisdictional requirements and legal review. These pages deliberately contain TODOs instead of fabricated legal claims.

## Domain, Cloudflare and GitHub

1. Create a Cloudflare account/project and authenticate with `npx wrangler login`.
2. Deploy with `npx wrangler deploy`; do not commit tokens or `.env` files.
3. Add `redreactions.com` in Cloudflare and configure the Worker/custom domain using the Cloudflare dashboard or Wrangler workflow appropriate to your account.
4. Create a GitHub repository, then commit the source, lockfile and configuration—not `node_modules`, `dist`, credentials or API tokens.

## Troubleshooting

- If `npm run build` fails after upgrading Astro, run `npm install` to refresh compatible dependency versions and check adapter release notes.
- A missing article normally means `draft: true`, invalid schema data, or a duplicate slug.
- Search only includes published content because its index is built statically.
- For real pagination, add a paginated archive route when content volume requires it; the current archive limits naturally to the small demo collection.

## Before production

- Configure real email addresses, social links, logo and SEO image.
- Add only licensed/editorially authorized assets.
- Complete and legally review policy templates.
- Configure analytics/trending data only after selecting a privacy-respecting implementation.
- Confirm Google Search Console, AdSense/CMP, `ads.txt`, custom domain and Cloudflare deployment settings.
