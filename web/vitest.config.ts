import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

export default defineConfig({
  resolve: {
    alias: {
      // Mirror vite.config.ts's alias here: this is a separate Vite config
      // (vitest does not read vite.config.ts's `resolve`), so without this
      // duplicate entry Radix's Dialog/Select/DropdownMenu would pull the
      // REAL react-remove-scroll under jsdom in tests — which injects an
      // actual runtime <style> tag for the scrollbar-gap CSS var — while the
      // production build correctly uses the no-<style> shim. Keep both in
      // sync; see web/src/lib/scroll-lock-shim.tsx.
      'react-remove-scroll': fileURLToPath(new URL('./src/lib/scroll-lock-shim.tsx', import.meta.url)),
    },
  },
  plugins: [react()],
  test: {
    environment: 'jsdom',
    setupFiles: ['./tests/setup.ts'],
    globals: true,
    include: ['tests/**/*.test.{ts,tsx}', 'src/**/*.test.{ts,tsx}'],
    server: {
      deps: {
        // By default Vitest externalizes node_modules deps — externalized
        // modules load via Node's native resolver, so their OWN nested
        // imports bypass Vite's plugin pipeline (and therefore the
        // `react-remove-scroll` alias above) entirely. @radix-ui/react-dialog
        // and @radix-ui/react-select import react-remove-scroll directly;
        // @radix-ui/react-dropdown-menu pulls it in transitively via
        // @radix-ui/react-menu. Inlining them routes their imports back
        // through Vite's resolver so the alias actually applies. NOTE: these
        // patterns are matched against the fully-resolved module path (e.g.
        // `.../node_modules/@radix-ui/react-dialog/dist/index.mjs`), NOT the
        // bare specifier — a `^`-anchored pattern like `/^@radix-ui\//` never
        // matches and silently no-ops (confirmed empirically: with it, real
        // react-remove-scroll(-bar) still loaded and injected its <style>).
        inline: [/@radix-ui\//, /react-remove-scroll/],
      },
    },
  },
})
