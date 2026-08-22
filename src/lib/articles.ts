import { getCollection, type CollectionEntry } from 'astro:content';
import { getAuthorProfile } from '../config/authors';
export type Article = CollectionEntry<'articles'>;
// Sorted newest-first by publishedAt. Full ISO timestamps preserve the real order of articles
// published on the same calendar day; date-only values remain valid for older content.
export async function getPublishedArticles() { return (await getCollection('articles', ({ data }) => !data.draft)).sort((a,b) => b.data.publishedAt.valueOf() - a.data.publishedAt.valueOf()); }
export function articleSlug(article: Article) { return (article.data.slug || article.id).replace(/\.mdx$/, ''); }
export function articlePath(article: Article) { return `/articles/${articleSlug(article)}/`; }
export function tagSlug(tag: string) { return tag.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, ''); }
export function authorSlug(author: string) { return getAuthorProfile(author)?.slug || tagSlug(author); }
export function authorDisplayName(author: string) { return getAuthorProfile(author)?.name || author; }
export function authorProfile(author: string) { return getAuthorProfile(author); }
export function authorPath(author: string) { return `/author/${authorSlug(author)}/`; }
export function franchiseSlug(franchise: string) { return franchise.toLowerCase().replaceAll(' ', '-'); }
export function franchisePath(franchise: string) { return `/franchise/${franchiseSlug(franchise)}/`; }
export function genreLabel(genre: string) { return genre === 'sci-fi' ? 'Sci-Fi' : genre.replace(/\b\w/g, letter => letter.toUpperCase()); }
export function genrePath(genre: string) { return `/genre/${genre}/`; }
export function topicPath(topic: string) { return `/${topic === 'tv' ? 'tv' : topic}/`; }
export function readingTime(body: string) { return Math.max(1, Math.ceil(body.split(/\s+/).length / 220)); }
export function relatedTo(current: Article, all: Article[]) { return all.filter(a => a.id !== current.id).map(a => ({ a, score: (a.data.franchise && a.data.franchise === current.data.franchise ? 8 : 0) + a.data.tags.filter(t => current.data.tags.includes(t)).length * 3 + a.data.topics.filter(t => current.data.topics.includes(t)).length + (a.data.contentType === current.data.contentType ? 1 : 0) })).filter(x => x.score > 0).sort((x,y) => y.score - x.score).slice(0,4).map(x=>x.a); }
