import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'
import svgr from 'vite-plugin-svgr'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    react(),
    svgr({ svgrOptions: { svgProps: { fill: 'currentColor' } } }),
    tailwindcss(),
    VitePWA({
      registerType: 'autoUpdate',
      // 'script' emits an EXTERNAL registerSW.js that index.html loads via a
      // plain <script src>, instead of an inline bootstrap <script> — the
      // production CSP is `script-src 'self'` with no nonce/hash mechanism,
      // so an inline register script would be a silent no-op (blocked, PWA
      // never registers) rather than a build error. Keep this external.
      injectRegister: 'script',
      manifest: {
        name: '5gpn-dns console',
        short_name: '5gpn-dns',
        theme_color: '#2563eb',
        background_color: '#eef4fc',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: 'pwa.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'any' },
          { src: 'pwa.svg', sizes: 'any', type: 'image/svg+xml', purpose: 'maskable' },
        ],
      },
      workbox: {
        // injectRegister: 'script' keeps registration CSP-safe, but it also
        // bypasses vite-plugin-pwa's autoUpdate shortcut that would otherwise
        // set these lifecycle flags. Make the generated worker take over as
        // soon as a deployment is discovered instead of waiting behind the
        // currently open console tab.
        skipWaiting: true,
        clientsClaim: true,
        cleanupOutdatedCaches: true,
        navigateFallback: 'index.html',
        navigateFallbackDenylist: [/^\/ios\//],
        // Fonts are unicode-ranged and immutable-hashed. Precaching all 96
        // MiSans chunks made first install download megabytes the current UI
        // may never use; cache only glyph chunks the browser actually asks
        // for, while keeping the app shell offline-first.
        globPatterns: ['**/*.{js,css,html,svg}'],
        runtimeCaching: [
          {
            urlPattern: ({ request }) => request.destination === 'font',
            handler: 'CacheFirst',
            options: {
              cacheName: '5gpn-fonts-v1',
              cacheableResponse: { statuses: [0, 200] },
              expiration: { maxEntries: 128, maxAgeSeconds: 60 * 60 * 24 * 365 },
            },
          },
        ],
      },
    }),
  ],
  base: '/',
  build: {
    manifest: true,
    outDir: 'dist',
    emptyOutDir: true,
    // Never inline fonts as data: URIs. The production CSP is
    // `font-src 'self'` (no `data:`) — Vite's default 4096-byte inline
    // threshold would otherwise embed the small MiSans/JetBrains Mono/Plus
    // Jakarta Sans subset chunks as base64 data: URIs in the CSS, which the
    // browser then refuses to load at runtime (caught by the e2e CSP gate,
    // web/e2e/csp.spec.ts). All other small assets keep the default
    // size-based inlining.
    assetsInlineLimit: (filePath) => (/\.(woff2?|ttf|otf|eot)$/i.test(filePath) ? false : undefined),
  },
})
