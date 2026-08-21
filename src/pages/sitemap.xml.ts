import type { APIRoute } from 'astro';
import { getPublishedArticles, articlePath, authorPath, franchisePath, genrePath } from '../lib/articles';
import { isReview } from '../lib/reviews';
import { groupByLoreCategory, groupByMedium } from '../lib/taxonomy';
import { site } from '../config/site';
const staticPaths = ['/', '/explore/', '/movies/', '/tv/', '/anime/', '/comics/', '/gaming/', '/trailers/', '/news/', '/reviews/', '/reactions/', '/lore/', '/about/', '/authors/', '/contact/', '/privacy/', '/cookies/', '/terms/', '/editorial-policy/', '/copyright/', '/search/'];
export const GET: APIRoute = async () => {
  const articles = await getPublishedArticles();
  const authorPaths = [...new Set(articles.map(article => article.data.author))].map(author => authorPath(author));
  const franchisePaths = [...new Set(articles.map(article => article.data.franchise).filter(Boolean) as string[])].map(franchise => franchisePath(franchise));
  const genrePaths = [...new Set(articles.flatMap(article => article.data.genres))].map(genre => genrePath(genre));
  const reviewPaths = groupByMedium(articles.filter(a => isReview(a.data.rating))).map(g => `/reviews/${g.slug}/`);
  const lorePaths = [
    ...groupByLoreCategory(articles.filter(a => a.data.contentType === 'lore')).map(g => g.path),
    ...groupByMedium(articles.filter(a => a.data.contentType === 'lore')).map(g => `/lore/${g.slug}/`),
  ];
  const newsPaths = groupByMedium(articles.filter(a => a.data.contentType === 'news')).map(g => `/news/${g.slug}/`);
  const trailerPaths = groupByMedium(articles.filter(a => a.data.contentType === 'trailer' || Boolean(a.data.youtubeId))).map(g => `/trailers/${g.slug}/`);
  const reactionPaths = groupByMedium(articles.filter(a => a.data.contentType === 'reaction')).map(g => `/reactions/${g.slug}/`);
  const urls: { path: string; lastmod?: string }[] = [
    ...staticPaths.map(path => ({ path })),
    ...authorPaths.map(path => ({ path })),
    ...franchisePaths.map(path => ({ path })),
    ...genrePaths.map(path => ({ path })),
    ...reviewPaths.map(path => ({ path })),
    ...lorePaths.map(path => ({ path })),
    ...newsPaths.map(path => ({ path })),
    ...trailerPaths.map(path => ({ path })),
    ...reactionPaths.map(path => ({ path })),
    ...articles.map(article => ({ path: articlePath(article), lastmod: (article.data.updatedAt || article.data.publishedAt).toISOString() })),
  ];
  const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls.map(({ path, lastmod }) => `<url><loc>${new URL(path, site.url).href}</loc>${lastmod ? `<lastmod>${lastmod}</lastmod>` : ''}</url>`).join('')}</urlset>`;
  return new Response(body, { headers: { 'Content-Type': 'application/xml' } });
};
