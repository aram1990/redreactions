import { defineConfig } from 'astro/config';
import mdx from '@astrojs/mdx';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://redreactions.com',
  output: 'static',
  image: { service: { entrypoint: 'astro/assets/services/sharp' } },
  integrations: [mdx()],
  vite: { plugins: [tailwindcss()] },
});
