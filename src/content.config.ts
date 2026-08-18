import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';
import { z } from 'astro/zod';

const articles = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/articles' }),
  schema: z.object({
    title: z.string(), slug: z.string().optional(), description: z.string(), author: z.string().default('Aram Anwar'),
    publishedAt: z.coerce.date(), updatedAt: z.coerce.date().optional(), heroImage: z.string(), heroImageAlt: z.string(), heroImageCaption: z.string().optional(), heroImageCredit: z.string().optional(), heroImagePosition: z.string().optional(), heroImageFit: z.enum(['cover', 'contain']).optional(), heroImageAspect: z.enum(['portrait']).optional(),
    contentType: z.enum(['news', 'review', 'reaction', 'lore', 'trailer', 'feature']),
    topics: z.array(z.enum(['movies', 'tv', 'anime', 'comics', 'gaming'])).min(1), franchise: z.string().optional(), genres: z.array(z.enum(['horror', 'sci-fi', 'fantasy', 'superhero', 'action', 'thriller', 'animation', 'comedy', 'drama'])).default([]), loreCategory: z.enum(['characters', 'origins-history', 'powers-abilities', 'worlds-factions', 'timelines-events', 'concepts-explained']).optional(), tags: z.array(z.string()).default([]),
    featured: z.boolean().default(false), trending: z.boolean().default(false), spoilers: z.boolean().default(false), rating: z.number().min(1).max(10).optional(), spoilerLevel: z.string().optional(), reviewedItem: z.object({ name: z.string(), type: z.enum(['Movie', 'TVSeries', 'TVEpisode', 'VideoGame', 'CreativeWork']), episodeNumber: z.number().int().positive().optional(), partOfSeason: z.string().optional(), partOfSeries: z.string().optional(), developer: z.string().optional(), publisher: z.string().optional(), originalReleaseYear: z.number().int().positive().optional(), editionReleaseYear: z.number().int().positive().optional() }).optional(),
    youtubeId: z.string().optional(), youtubeTitle: z.string().optional(), youtubeUploadDate: z.coerce.date().optional(), youtubeDescription: z.string().optional(), youtubeThumbnailUrl: z.url().optional(), youtubeDuration: z.string().optional(), youtubeInline: z.boolean().default(false), compactHero: z.boolean().default(false), sources: z.array(z.object({ name: z.string(), url: z.url(), publishedAt: z.coerce.date().optional() })).default([]),
    draft: z.boolean().default(false), seoTitle: z.string().optional(), seoDescription: z.string().optional(),
  }),
});
export const collections = { articles };
