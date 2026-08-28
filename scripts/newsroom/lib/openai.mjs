const API_URL = 'https://api.openai.com/v1/responses';

function responseText(payload) {
  if (payload.output_text) return payload.output_text;
  return payload.output?.flatMap(item => item.content || [])
    .filter(item => item.type === 'output_text')
    .map(item => item.text).join('') || '';
}

export async function researchAndDraft({ articleIndex, state }) {
  if (!process.env.OPENAI_API_KEY) throw new Error('OPENAI_API_KEY is required for newsroom discovery.');
  const prompt = `You are the fact-checking editor for Red Reactions (Movies. TV. Anime. Comics. No Filter.). Today is ${new Date().toISOString()}.

Research current entertainment news using web search. Independently compare multiple sources; do not use a single feed. Prefer an official source plus one of Deadline, Variety, The Hollywood Reporter, Reuters, AP, or a reliable specialist outlet. Reject rumors, leaks, recycled stories, negotiations presented as confirmations, stories without an available high-quality official or properly licensed hero image, and stories already covered.

Select zero, one, or two strong stories across movies, TV/streaming, anime, comics and gaming. Zero is correct if no candidate clears every gate. For every selection, verify names, dates, status, project title, platforms/studios and source URLs. The body must be natural, restrained entertainment news: lead with the news, avoid generic introductions, filler, hype, fake reactions, keyword stuffing and unsupported claims. Use 250-1200 words according to the genuine importance of the story. Include 0-6 only genuinely useful Markdown internal links, choosing exclusively from the supplied Red Reactions index.

Use only an official hero image, official artwork/still/screenshot or a clearly licensed Wikimedia asset. Supply a direct downloadable image URL, a source page URL and exact credit. Do not use third-party news-site images, watermarks, fan art, AI art, leaked material or unclear rights.

Existing Red Reactions articles (do not duplicate; only link if useful):
${JSON.stringify(articleIndex.map(({ title, slug, path }) => ({ title, slug, path })))}

Previously published source URLs/slugs:
${JSON.stringify(state.published || [])}

Return JSON only, matching this shape:
{
  "discoveredCount": 0,
  "rejections": [{"label":"string","reason":"string"}],
  "selected": [{
    "title":"string", "slug":"lowercase-hyphenated", "description":"string", "topic":"movies|tv|anime|comics|gaming",
    "contentType":"news", "franchise":"optional string", "genres":["optional allowed genre"], "tags":["string"],
    "author":"Aram Anwar|Kenza Benouna|Sara Avegaard|Bamo Anwar", "primaryIntent":"string",
    "sources":[{"name":"string","url":"https://...","tier":"primary|deadline|variety|hollywood-reporter|reuters|ap|specialist"}],
    "heroImage":{"sourceUrl":"https://...","directUrl":"https://...","alt":"string","credit":"string","fit":"cover|contain","position":"50% 50%"},
    "youtube": null,
    "body":"MDX body only, no frontmatter"
  }]
}
For author selection: Bamo Anwar for gaming/anime; Kenza Benouna for horror and darker movie/TV stories; Sara Avegaard for general movie/TV/streaming/casting news; Aram Anwar for comics, superhero/franchise stories, major entertainment news and major gaming. Do not rotate byline. Keep source claims precise: reported is not confirmed, negotiations are not castings, and do not state a cause of death unless an authoritative source has disclosed it.`;

  const response = await fetch(API_URL, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.OPENAI_API_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      model: process.env.NEWSROOM_MODEL || 'gpt-5-mini',
      tools: [{ type: 'web_search' }],
      tool_choice: 'auto',
      input: prompt,
      text: { format: { type: 'json_object' } },
    }),
  });
  if (!response.ok) throw new Error(`OpenAI Responses API failed: ${response.status}`);
  const text = responseText(await response.json());
  try { return JSON.parse(text); } catch { throw new Error('Newsroom model returned invalid JSON.'); }
}
