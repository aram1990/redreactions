import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import mdx from '@astrojs/mdx';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://redreactions.com',
  output: 'static',
  adapter: cloudflare(),
  image: { service: { entrypoint: 'astro/assets/services/sharp' } },
  integrations: [mdx()],
  vite: { plugins: [tailwindcss()] },
});
