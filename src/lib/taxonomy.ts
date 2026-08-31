import type { Article } from './articles';
import { franchiseLabel, franchisePath, genreLabel, genrePath } from './articles';
import { isReview } from './reviews';

// Centralized "latest vs archive" counts so these aren't scattered as magic numbers across pages.
export const HUB_COUNTS = { reviews: 6, lore: 6, news: 10, trailers: 6, reactions: 6 } as const;

// A taxonomy archive needs three distinct published articles before it can be indexed or included
// in the sitemap. Routes below this threshold remain available to visitors and internal links, but
// use noindex,follow until their coverage is substantive enough.
export const MIN_INDEXABLE = 3;
export const MIN_ROUTE_ARTICLES = MIN_INDEXABLE;

export const MEDIUMS = [
  { slug: 'movies', label: 'Movies' },
  { slug: 'tv', label: 'TV & Streaming' },
  { slug: 'anime', label: 'Anime' },
  { slug: 'comics', label: 'Comics' },
  { slug: 'gaming', label: 'Gaming' },
] as const;
export type MediumSlug = (typeof MEDIUMS)[number]['slug'];
export function mediumLabel(slug: string) { return MEDIUMS.find(m => m.slug === slug)?.label ?? slug; }
export function isMediumSlug(slug: string): slug is MediumSlug { return MEDIUMS.some(m => m.slug === slug); }

export const LORE_CATEGORIES = [
  { slug: 'characters', label: 'Characters' },
  { slug: 'origins-history', label: 'Origins & History' },
  { slug: 'powers-abilities', label: 'Powers & Abilities' },
  { slug: 'worlds-factions', label: 'Worlds & Factions' },
  { slug: 'timelines-events', label: 'Timelines & Events' },
  { slug: 'concepts-explained', label: 'Concepts Explained' },
] as const;
export type LoreCategorySlug = (typeof LORE_CATEGORIES)[number]['slug'];
export function loreCategoryLabel(slug: string) { return LORE_CATEGORIES.find(c => c.slug === slug)?.label ?? slug; }
export function loreCategoryPath(slug: string) { return `/lore/${slug}/`; }
export function isLoreCategorySlug(slug: string): slug is LoreCategorySlug { return LORE_CATEGORIES.some(c => c.slug === slug); }

// Coverage types = the site's contentType-driven hubs. Each has a canonical index and matcher.
export const COVERAGE_TYPES = [
  { slug: 'news', label: 'News', basePath: '/news/', match: (a: Article) => a.data.contentType === 'news' },
  { slug: 'reviews', label: 'Reviews', basePath: '/reviews/', match: (a: Article) => isReview(a.data.rating) },
  { slug: 'lore', label: 'Lore & Explained', basePath: '/lore/', match: (a: Article) => a.data.contentType === 'lore' },
  { slug: 'trailers', label: 'Trailers', basePath: '/trailers/', match: (a: Article) => a.data.contentType === 'trailer' },
  { slug: 'reactions', label: 'Reactions', basePath: '/reactions/', match: (a: Article) => a.data.contentType === 'reaction' },
] as const;

export function splitLatestArchive<T>(items: T[], count: number) { return { latest: items.slice(0, count), archive: items.slice(count) }; }

export function groupByMedium(articles: Article[]) {
  return MEDIUMS
    .map(m => ({ ...m, path: `/${m.slug}/`, articles: articles.filter(a => a.data.topics.includes(m.slug)) }))
    .filter(g => g.articles.length >= MIN_ROUTE_ARTICLES);
}

export function groupByLoreCategory(articles: Article[]) {
  return LORE_CATEGORIES
    .map(c => ({ ...c, path: loreCategoryPath(c.slug), articles: articles.filter(a => a.data.loreCategory === c.slug) }))
    .filter(g => g.articles.length >= MIN_ROUTE_ARTICLES);
}

export function groupByFranchise(articles: Article[]) {
  const names = [...new Set(articles.map(a => a.data.franchise).filter(Boolean) as string[])];
  return names
    .map(franchise => ({ franchise, label: franchiseLabel(franchise), path: franchisePath(franchise), articles: articles.filter(a => a.data.franchise === franchise) }))
    .filter(g => g.articles.length >= MIN_INDEXABLE)
    .sort((a, b) => b.articles.length - a.articles.length || a.franchise.localeCompare(b.franchise));
}

export function groupByGenre(articles: Article[]) {
  const genres = [...new Set(articles.flatMap(a => a.data.genres))];
  return genres
    .map(genre => ({ genre, label: genreLabel(genre), path: genrePath(genre), articles: articles.filter(a => a.data.genres.includes(genre)) }))
    .filter(g => g.articles.length >= MIN_ROUTE_ARTICLES)
    .sort((a, b) => b.articles.length - a.articles.length || a.genre.localeCompare(b.genre));
}

/** Breaks a set of articles (e.g. one franchise's, one genre's) down into populated coverage-type groups. */
export function groupByCoverageType(articles: Article[]) {
  return COVERAGE_TYPES
    .map(c => ({ ...c, articles: articles.filter(c.match) }))
    .filter(g => g.articles.length >= MIN_INDEXABLE);
}

/** For a medium hub (e.g. /movies/): which coverage types have content for that medium, linking to the canonical filtered index. */
export function mediumCoverageLinks(mediumArticles: Article[], mediumSlug: string) {
  return COVERAGE_TYPES
    .map(c => ({ ...c, href: `${c.basePath}${mediumSlug}/`, articles: mediumArticles.filter(c.match) }))
    .filter(g => g.articles.length >= MIN_ROUTE_ARTICLES);
}
