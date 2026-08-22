export const site = {
  name: 'RED REACTIONS',
  url: 'https://redreactions.com',
  tagline: 'Movies. TV. Anime. Comics. No Filter.',
  description: 'Bold, independent commentary on movies, TV, anime, comics and gaming.',
  defaultAuthor: 'Aram Anwar',
  contactEmail: 'real.redreactions@gmail.com',
  adsenseClient: import.meta.env.PUBLIC_ADSENSE_CLIENT || '',
  adsenseSlots: {
    ARTICLE_TOP: import.meta.env.PUBLIC_ADSENSE_SLOT_ARTICLE_TOP || '',
    ARTICLE_MIDDLE: import.meta.env.PUBLIC_ADSENSE_SLOT_ARTICLE_MIDDLE || '',
    ARTICLE_BOTTOM: import.meta.env.PUBLIC_ADSENSE_SLOT_ARTICLE_BOTTOM || '',
    SIDEBAR: import.meta.env.PUBLIC_ADSENSE_SLOT_SIDEBAR || '',
    HOMEPAGE_FEED: import.meta.env.PUBLIC_ADSENSE_SLOT_HOMEPAGE_FEED || '',
  },
  defaultImage: '/images/articles/spider-man-brand-new-day-box-office.webp',
  social: { x: 'https://x.com/arre90', tiktok: 'https://www.tiktok.com/@red.reactions', youtube: 'https://www.youtube.com/@TheRedXNerd', instagram: 'https://www.instagram.com/red_reactions/', kick: 'https://kick.com/redreactions', twitch: 'https://www.twitch.tv/redreactionsx' },
} as const;

export const navItems = [
  ['Movies', '/movies/'], ['TV & Streaming', '/tv/'], ['Anime', '/anime/'], ['Comics', '/comics/'], ['Gaming', '/gaming/'],
  ['Trailers', '/trailers/'], ['News', '/news/'], ['Reviews', '/reviews/'], ['Lore', '/lore/'], ['Explore', '/explore/'],
] as const;
