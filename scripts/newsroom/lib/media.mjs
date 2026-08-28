import { execFileSync } from 'node:child_process';
import { mkdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { IMAGES_URL, imageHosts } from './config.mjs';

function allowedHost(host) {
  return [...imageHosts()].some(allowed => host === allowed || host.endsWith(`.${allowed}`));
}

export async function downloadHero(candidate) {
  const source = new URL(candidate.heroImage.sourceUrl);
  const direct = new URL(candidate.heroImage.directUrl);
  const official = candidate.sources.some(item => item.tier === 'primary' && item.url === candidate.heroImage.sourceUrl);
  const wikimedia = source.hostname === 'commons.wikimedia.org' && direct.hostname === 'upload.wikimedia.org';
  if ((!official && !wikimedia) || !allowedHost(direct.hostname)) throw new Error(`Hero image does not pass source/host policy for ${candidate.slug}.`);

  const response = await fetch(direct, { redirect: 'follow', headers: { 'User-Agent': 'RedReactionsNewsroom/1.0' } });
  const type = response.headers.get('content-type') || '';
  const bytes = Buffer.from(await response.arrayBuffer());
  if (!response.ok || !type.startsWith('image/') || bytes.length < 10_000 || bytes.length > 8_000_000) throw new Error(`Hero image download failed media checks for ${candidate.slug}.`);
  const extension = type.includes('jpeg') ? 'jpg' : type.includes('png') ? 'png' : type.includes('webp') ? 'webp' : type.includes('gif') ? 'gif' : null;
  if (!extension) throw new Error(`Hero image format is not approved for ${candidate.slug}.`);

  const dir = path.join(fileURLToPath(IMAGES_URL), candidate.slug);
  const input = path.join(dir, `.newsroom-input.${extension}`);
  const output = path.join(dir, `${candidate.slug}-hero.webp`);
  await mkdir(dir, { recursive: true });
  await writeFile(input, bytes);
  try {
    const command = process.platform === 'win32' ? 'magick' : 'convert';
    execFileSync(command, [input, '-auto-orient', '-resize', '1600x1200>', '-quality', '82', output], { stdio: 'pipe' });
  } catch (error) {
    await rm(dir, { recursive: true, force: true });
    throw new Error(`Hero image optimization failed for ${candidate.slug}: ${error.message}`);
  }
  await rm(input, { force: true });
  return `/images/articles/${candidate.slug}/${candidate.slug}-hero.webp`;
}
