import { execFileSync } from 'node:child_process';
import { rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { AUTHORS, MAX_ARTICLES_PER_RUN, RUN_OUTPUT_URL } from './lib/config.mjs';
import { downloadHero } from './lib/media.mjs';
import { writeArticle } from './lib/mdx.mjs';
import { researchAndDraft } from './lib/openai.mjs';
import { addPublished, addRun, articleIndex, assertCleanWorktree, readState, validateCandidate, validateInternalLinks, writeState } from './lib/repo.mjs';

const runOutputPath = fileURLToPath(RUN_OUTPUT_URL);
const now = () => new Date().toISOString();
const authorValues = new Set(Object.values(AUTHORS));

function articleAuthorMatches(candidate) {
  if (!authorValues.has(candidate.author)) return false;
  if (['gaming', 'anime'].includes(candidate.topic)) return candidate.author === 'Bamo Anwar';
  return true;
}

async function main() {
  assertCleanWorktree();
  const articles = await articleIndex();
  const state = await readState();
  const result = await researchAndDraft({ articleIndex: articles, state });
  const selected = (result.selected || []).slice(0, MAX_ARTICLES_PER_RUN);
  const rejections = [...(result.rejections || [])];
  const approved = [];

  for (const candidate of selected) {
    candidate.publishedAt = now();
    const errors = validateCandidate(candidate, articles, state);
    if (!articleAuthorMatches(candidate)) errors.push('author assignment does not match topic expertise');
    const brokenLinks = validateInternalLinks(candidate.body || '', articles);
    if (brokenLinks.length) errors.push(`broken internal links: ${brokenLinks.join(', ')}`);
    if (errors.length) {
      rejections.push({ label: candidate.title || candidate.slug || 'unnamed candidate', reason: errors.join('; ') });
      continue;
    }
    try {
      const heroImage = await downloadHero(candidate);
      const file = await writeArticle(candidate, heroImage);
      approved.push({ candidate, file, heroImage });
    } catch (error) {
      rejections.push({ label: candidate.title, reason: error.message });
    }
  }

  if (approved.length) {
    execFileSync('pnpm', ['run', 'build'], { stdio: 'inherit' });
  }

  const summary = {
    at: now(),
    discoveredCount: Number(result.discoveredCount || selected.length + rejections.length),
    rejected: rejections.slice(0, 20),
    selected: approved.map(({ candidate }) => ({ slug: candidate.slug, title: candidate.title, author: candidate.author, primarySources: candidate.sources.filter(source => source.tier === 'primary').map(source => source.url) })),
    build: approved.length ? 'passed' : 'not-run-no-approved-articles',
  };
  for (const { candidate } of approved) addPublished(state, candidate);
  addRun(state, summary);
  await writeState(state);
  await writeFile(runOutputPath, `${JSON.stringify({ ...summary, files: approved.flatMap(item => [item.file, path.join('public/images/articles', item.candidate.slug, `${item.candidate.slug}-hero.webp`)]), stateFile: 'newsroom/state.json' }, null, 2)}\n`);
  console.log(JSON.stringify(summary));
}

main().catch(async error => {
  await rm(runOutputPath, { force: true });
  console.error(`NEWSROOM FAILED CLOSED: ${error.message}`);
  process.exitCode = 1;
});
