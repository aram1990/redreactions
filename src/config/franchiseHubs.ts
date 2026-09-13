// Optional, hand-written hub content for strong franchises with enough coverage to justify a
// real navigation/context layer on their /franchise/ page. Not every franchise needs an entry —
// [franchise].astro only renders this block when a franchise has one, so thin hubs stay untouched.
// Slugs are resolved against that franchise's own published articles in [franchise].astro, so a
// removed or renamed article simply drops out of the hub instead of leaving a dead reference.
export interface FranchiseHubContent {
  intro: string;
  whereToStartSlug: string;
  readingOrderSlugs: string[];
}

export const franchiseHubContent: Record<string, FranchiseHubContent> = {
  Silo: {
    intro: "Silo is Apple TV+'s adaptation of Hugh Howey's Wool, Shift and Dust novels, following the survivors of an underground silo who are forbidden from asking what's really outside. Our coverage tracks the show season by season alongside how it diverges from the books.",
    whereToStartSlug: 'silo-timeline-explained',
    readingOrderSlugs: [
      'silo-timeline-explained',
      'silo-1-algorithm-safeguard-directive-explained',
      'troy-daniel-keene-silo-explained',
      'silo-season-3-ending-explained',
      'silo-season-3-shift-book-differences',
      'silo-season-4-everything-we-know',
    ],
  },
  Insidious: {
    intro: 'Insidious is Blumhouse and Sony/Screen Gems\' long-running horror franchise built around the Further, a supernatural realm astral travelers can enter — and, since Out of the Further, a place spirits can now reach back out of.',
    whereToStartSlug: 'the-further-explained-insidious-rules',
    readingOrderSlugs: [
      'the-further-explained-insidious-rules',
      'insidious-timeline-explained-out-of-the-further',
      'insidious-out-of-the-further-everything-we-know',
      'insidious-out-of-the-further-review',
      'insidious-out-of-the-further-ending-explained',
    ],
  },
};

export function getFranchiseHubContent(franchise: string) { return franchiseHubContent[franchise]; }
