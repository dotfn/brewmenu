// @ts-check
import { defineConfig, fontProviders } from 'astro/config';

import tailwindcss from '@tailwindcss/vite';
import vercel from '@astrojs/vercel';
import sitemap from '@astrojs/sitemap';

// https://astro.build/config
export default defineConfig({
  site: 'https://brewmenu.vercel.app',
  output: 'static',
  i18n: {
    locales: ['en', 'es'],
    defaultLocale: 'en',
  },
  integrations: [
    sitemap({
      i18n: {
        defaultLocale: 'en',
        locales: {
          en: 'en-US',
          es: 'es-ES',
        },
      },
    }),
  ],
  adapter: vercel({
    webAnalytics: {
      enabled: true,
    },
    imageService: true,
  }),
  fonts: [
    {
      provider: fontProviders.google(),
      name: 'Urbanist',
      cssVariable: '--font-urbanist',
      weights: [400, 500, 600, 700],
      styles: ['normal'],
    },
    {
      // Fallback for the title face off Apple devices, where -apple-system isn't SF Pro. Never
      // preloaded: on a Mac the browser resolves SF first and never downloads it.
      provider: fontProviders.google(),
      name: 'Inter',
      cssVariable: '--font-inter',
      weights: [500, 600, 700],
      styles: ['normal'],
    },
    {
      provider: fontProviders.google(),
      name: 'Geist Mono',
      cssVariable: '--font-geist-mono',
      weights: [400, 500],
      styles: ['normal'],
    },
  ],
  vite: {
    plugins: [tailwindcss()]
  }
});