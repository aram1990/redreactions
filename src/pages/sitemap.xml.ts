import type { APIRoute } from 'astro';
import { getPublishedArticles, articlePath, authorPath, franchisePath, genrePath } from '../lib/articles';
import { isReview } from '../lib/reviews';
import { groupByFranchise, groupByGenre, groupByLoreCategory, groupByMedium } from '../lib/taxonomy';
import { site } from '../config/site';
const staticPaths = ['/', '/explore/', '/movies/', '/tv/', '/anime/', '/comics/', '/gaming/', '/news/', '/reviews/', '/lore/', '/about/', '/authors/', '/contact/', '/privacy/', '/cookies/', '/terms/', '/editorial-policy/', '/copyright/'];
export const GET: APIRoute = async () => {
  const articles = await getPublishedArticles();
  const authorPaths = [...new Set(articles.map(article => authorPath(article.data.author)))];
  const franchisePaths = groupByFranchise(articles).map(group => franchisePath(group.franchise));
  const genrePaths = groupByGenre(articles).map(group => genrePath(group.genre));
  const reviewPaths = groupByMedium(articles.filter(a => isReview(a.data.rating))).map(g => `/reviews/${g.slug}/`);
  const lorePaths = [
    ...groupByLoreCategory(articles.filter(a => a.data.contentType === 'lore')).map(g => g.path),
    ...groupByMedium(articles.filter(a => a.data.contentType === 'lore')).map(g => `/lore/${g.slug}/`),
  ];
  const newsPaths = groupByMedium(articles.filter(a => a.data.contentType === 'news')).map(g => `/news/${g.slug}/`);
  const trailerPaths = groupByMedium(articles.filter(a => a.data.contentType === 'trailer')).map(g => `/trailers/${g.slug}/`);
  const urls: { path: string; lastmod?: string }[] = [
    ...staticPaths.map(path => ({ path })),
    ...(articles.filter(article => article.data.contentType === 'trailer').length >= 3 ? [{ path: '/trailers/' }] : []),
    ...(articles.some(article => article.data.contentType === 'reaction') ? [{ path: '/reactions/' }] : []),
    ...authorPaths.map(path => ({ path })),
    ...franchisePaths.map(path => ({ path })),
    ...genrePaths.map(path => ({ path })),
    ...reviewPaths.map(path => ({ path })),
    ...lorePaths.map(path => ({ path })),
    ...newsPaths.map(path => ({ path })),
    ...trailerPaths.map(path => ({ path })),
    ...articles.map(article => ({ path: articlePath(article), lastmod: (article.data.updatedAt || article.data.publishedAt).toISOString() })),
  ];
  const body = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${urls.map(({ path, lastmod }) => `<url><loc>${new URL(path, site.url).href}</loc>${lastmod ? `<lastmod>${lastmod}</lastmod>` : ''}</url>`).join('')}</urlset>`;
  return new Response(body, { headers: { 'Content-Type': 'application/xml' } });
};
