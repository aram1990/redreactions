export const authorProfiles = [
  {
    name: 'Aram Anwar',
    slug: 'aram-anwar',
    role: 'Founder & Editor',
    bio: 'Aram Anwar is the founder of Red Reactions, created from a long-standing passion for movies, television, gaming and entertainment culture. He covers major releases, franchise news, comics, gaming and in-depth Lore / Explained features.',
    coverage: ['Lore / Explained', 'Comics', 'Big Features', 'Movies', 'TV', 'Gaming'],
    aliases: [],
  },
  {
    name: 'Sara Avegaard',
    slug: 'sara-a',
    role: 'Movies & TV Writer',
    bio: 'Sara Avegaard is a movie and television enthusiast with a strong interest in entertainment news, upcoming releases and the latest developments across film and streaming. At Red Reactions, she focuses on movies, TV, streaming and breaking entertainment stories.',
    coverage: ['Movies', 'TV', 'Streaming', 'Entertainment News'],
    aliases: ['Sara A'],
  },
  {
    name: 'Kenza Benouna',
    slug: 'k-benouna',
    role: 'Movies, TV & Horror Writer',
    bio: 'Kenza Benouna loves movies and television, with a particular passion for horror. She covers new releases, DC, television, movies and the darker side of entertainment for Red Reactions.',
    coverage: ['DC', 'Movies', 'TV', 'Horror'],
    aliases: ['K Benouna'],
  },
  {
    name: 'Bamo Anwar',
    slug: 'bamo-a',
    role: 'Anime & Gaming Writer',
    bio: 'Bamo Anwar is passionate about anime and gaming, from major franchises and new releases to the characters and worlds behind them. At Red Reactions, he primarily covers anime and gaming, alongside selected movie and horror stories.',
    coverage: ['Anime', 'Gaming', 'Movies', 'Horror'],
    aliases: ['Bamo A'],
  },
] as const;

export type AuthorProfile = (typeof authorProfiles)[number];

export function getAuthorProfile(author: string) {
  return authorProfiles.find(profile => profile.name === author || profile.aliases.includes(author as never));
}
