// @ts-check
import { defineConfig, fontProviders } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import vercel from '@astrojs/vercel';

// https://astro.build/config
export default defineConfig({
  site: 'https://brewmenu.vercel.app',
  output: 'static',
  adapter: vercel({
    webAnalytics: {
      enabled: true,
    },
    imageService: true,
  }),
  fonts: [
    {
      provider: fontProviders.google(),
      name: 'Inter',
      cssVariable: '--font-inter',
      weights: [300, 400, 600, 700],
      styles: ['normal'],
    },
  ],
  vite: {
    plugins: [tailwindcss()]
  }
});