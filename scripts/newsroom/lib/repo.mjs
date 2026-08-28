import { execFileSync } from 'node:child_process';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ARTICLES_URL, BANNED_PHRASES, GENRES, MAX_STATE_ENTRIES, STATE_URL, TOPICS } from './config.mjs';

const articlesDir = fileURLToPath(ARTICLES_URL);
const statePath = fileURLToPath(STATE_URL);

export function git(...args) {
  return execFileSync('git', args, { encoding: 'utf8' }).trim();
}

export function assertCleanWorktree() {
  const dirty = git('status', '--porcelain').split('\n').filter(Boolean);
  if (dirty.length) throw new Error(`Refusing newsroom run: worktree is not clean (${dirty.length} unexpected path(s)).`);
}

export async function articleIndex() {
  const names = await readdir(articlesDir);
  const index = [];
  for (const name of names.filter(name => name.endsWith('.mdx'))) {
    const text = await readFile(path.join(articlesDir, name), 'utf8');
    const title = text.match(/^title:\s*["'](.+?)["']\s*$/m)?.[1] || '';
    const slug = text.match(/^slug:\s*["'](.+?)["']\s*$/m)?.[1] || name.replace(/\.mdx$/, '');
    index.push({ title, slug, path: `/articles/${slug}/`, text: text.toLowerCase() });
  }
  return index;
}

export async function readState() {
  return JSON.parse(await readFile(statePath, 'utf8'));
}

export async function writeState(state) {
  await mkdir(path.dirname(statePath), { recursive: true });
  await writeFile(statePath, `${JSON.stringify(state, null, 2)}\n`);
}

export function hasDuplicate(candidate, articles, state) {
  const title = candidate.title.toLowerCase();
  const slug = candidate.slug.toLowerCase();
  const sources = new Set(candidate.sources.map(source => canonicalUrl(source.url)));
  return articles.some(article => article.slug.toLowerCase() === slug || article.title.toLowerCase() === title)
    || state.published.some(item => item.slug === candidate.slug || item.sources.some(url => sources.has(url)));
}

export function canonicalUrl(value) {
  const url = new URL(value);
  url.hash = '';
  for (const key of [...url.searchParams.keys()]) {
    if (key.startsWith('utm_') || key === 'fbclid') url.searchParams.delete(key);
  }
  return url.href;
}

export function validateCandidate(candidate, articles, state) {
  const errors = [];
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(candidate.slug)) errors.push('invalid slug');
  if (!TOPICS.has(candidate.topic)) errors.push('invalid topic');
  if (!candidate.title || !candidate.description) errors.push('missing title or description');
  if (!Array.isArray(candidate.sources) || candidate.sources.length < 2) errors.push('fewer than two sources');
  if (!candidate.sources?.some(source => source.tier === 'primary')) errors.push('no primary source');
  if (candidate.sources?.some(source => !['primary', 'deadline', 'variety', 'hollywood-reporter', 'reuters', 'ap', 'specialist'].includes(source.tier))) errors.push('unapproved source tier');
  if (!candidate.heroImage?.sourceUrl || !candidate.heroImage?.directUrl || !candidate.heroImage?.credit) errors.push('incomplete hero image metadata');
  if (!candidate.body || wordCount(candidate.body) < 250 || wordCount(candidate.body) > 1200) errors.push('article length outside editorial range');
  if ((candidate.body || '').toLowerCase().includes('cause of death') && !candidate.title.toLowerCase().includes('dies')) errors.push('unexpected cause-of-death language');
  const lower = (candidate.body || '').toLowerCase();
  for (const phrase of BANNED_PHRASES) if (lower.includes(phrase)) errors.push(`banned phrase: ${phrase}`);
  if (candidate.genres?.some(genre => !GENRES.has(genre))) errors.push('invalid genre');
  if (hasDuplicate(candidate, articles, state)) errors.push('duplicate coverage');
  return errors;
}

export function validateInternalLinks(body, articles) {
  const slugs = new Set(articles.map(article => article.slug));
  const links = [...body.matchAll(/\]\(\/articles\/([a-z0-9-]+)\/?\)/g)].map(match => match[1]);
  return links.filter(slug => !slugs.has(slug));
}

export function wordCount(value) { return value.trim().split(/\s+/).filter(Boolean).length; }

export function addRun(state, run) {
  state.runs = [run, ...(state.runs || [])].slice(0, MAX_STATE_ENTRIES);
  return state;
}

export function addPublished(state, candidate) {
  state.published = [{
    slug: candidate.slug,
    title: candidate.title,
    sources: candidate.sources.map(source => canonicalUrl(source.url)),
    publishedAt: candidate.publishedAt,
  }, ...(state.published || [])].slice(0, MAX_STATE_ENTRIES);
  return state;
}
