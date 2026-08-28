import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ARTICLES_URL } from './config.mjs';

const quote = value => JSON.stringify(value);

export async function writeArticle(candidate, heroImage) {
  const lines = [
    '---',
    `title: ${quote(candidate.title)}`,
    `slug: ${quote(candidate.slug)}`,
    `description: ${quote(candidate.description)}`,
    `publishedAt: ${candidate.publishedAt}`,
    `author: ${quote(candidate.author)}`,
    'topics:', `  - ${candidate.topic}`,
    ...(candidate.franchise ? [`franchise: ${quote(candidate.franchise)}`] : []),
    ...(candidate.genres?.length ? ['genres:', ...candidate.genres.map(genre => `  - ${genre}`)] : []),
    'tags:', ...candidate.tags.map(tag => `  - ${quote(tag)}`),
    'contentType: "news"',
    'spoilers: false',
    `heroImage: ${quote(heroImage)}`,
    `heroImageAlt: ${quote(candidate.heroImage.alt)}`,
    `heroImageCredit: ${quote(candidate.heroImage.credit)}`,
    `heroImageFit: ${quote(candidate.heroImage.fit || 'cover')}`,
    ...(candidate.heroImage.position ? [`heroImagePosition: ${quote(candidate.heroImage.position)}`] : []),
    ...(candidate.youtube?.id ? [
      `youtubeId: ${quote(candidate.youtube.id)}`,
      `youtubeTitle: ${quote(candidate.youtube.title)}`,
      `youtubeUploadDate: ${candidate.youtube.uploadDate}`,
      `youtubeDescription: ${quote(candidate.youtube.description)}`,
      `youtubeThumbnailUrl: ${quote(candidate.youtube.thumbnailUrl)}`,
    ] : []),
    'sources:',
    ...candidate.sources.map(source => `  - name: ${quote(source.name)}\n    url: ${quote(source.url)}`),
    '---',
    '',
    candidate.body.trim(),
    '',
  ];
  const output = path.join(fileURLToPath(ARTICLES_URL), `${candidate.slug}.mdx`);
  await writeFile(output, lines.join('\n'));
  return output;
}
