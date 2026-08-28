export const ROOT = new URL('../../../', import.meta.url);

export const NEWSROOM_DIR = new URL('../../../newsroom/', import.meta.url);
export const STATE_URL = new URL('../../../newsroom/state.json', import.meta.url);
export const RUN_OUTPUT_URL = new URL('../../../newsroom/.run-output.json', import.meta.url);
export const ARTICLES_URL = new URL('../../../src/content/articles/', import.meta.url);
export const IMAGES_URL = new URL('../../../public/images/articles/', import.meta.url);

export const AUTHORS = Object.freeze({
  movies: 'Sara Avegaard',
  tv: 'Sara Avegaard',
  horror: 'Kenza Benouna',
  comics: 'Aram Anwar',
  gaming: 'Bamo Anwar',
  anime: 'Bamo Anwar',
  major: 'Aram Anwar',
});

export const TOPICS = new Set(['movies', 'tv', 'anime', 'comics', 'gaming']);
export const GENRES = new Set(['horror', 'sci-fi', 'fantasy', 'superhero', 'action', 'thriller', 'animation', 'comedy', 'drama']);
export const BANNED_PHRASES = [
  'fans have been eagerly waiting',
  "in today's entertainment landscape",
  'an exciting new chapter',
  'only time will tell',
  'it remains to be seen',
  'fans will undoubtedly',
  'this exciting development',
];

const DEFAULT_IMAGE_HOSTS = [
  'upload.wikimedia.org', 'commons.wikimedia.org', 'youtube.com', 'ytimg.com',
  'disney.com', 'marvel.com', 'dc.com', 'warnerbros.com', 'hbo.com', 'max.com', 'netflix.com',
  'paramount.com', 'paramountplus.com', 'primevideo.com', 'amazon.com', 'apple.com', 'a24films.com',
  'universalpictures.com', 'focusfeatures.com', 'sonypictures.com', 'playstation.com', 'xbox.com',
  'nintendo.com', 'ubisoft.com', 'ea.com', 'capcom.com', 'sega.com', 'square-enix.com',
  'bandainamcoent.com', 'crunchyroll.com', 'funimation.com', 'viz.com', 'kodansha.us', 'image.net',
];

export function imageHosts() {
  const extra = (process.env.NEWSROOM_APPROVED_IMAGE_HOSTS || '')
    .split(',').map(host => host.trim().toLowerCase()).filter(Boolean);
  return new Set([...DEFAULT_IMAGE_HOSTS, ...extra]);
}

export const MAX_ARTICLES_PER_RUN = 2;
export const MAX_STATE_ENTRIES = 50;
