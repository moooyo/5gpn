/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      // The palette lives in CSS variables (src/tokens.css) so a single
      // `.light` class can re-theme the whole app. Tailwind color utilities
      // reference those variables via <alpha-value>-aware rgb() is overkill
      // here; we mostly drive color through the token variables directly in
      // component classes, and use these named colors for the few utility
      // spots that want them.
      colors: {
        bg: 'var(--bg)',
        surface: 'var(--surface)',
        'surface-2': 'var(--surface-2)',
        border: 'var(--border)',
        text: 'var(--text)',
        muted: 'var(--muted)',
        accent: 'var(--accent)',
        'v-direct': 'var(--v-direct)',
        'v-proxy': 'var(--v-proxy)',
        'v-block': 'var(--v-block)',
        'v-adblock': 'var(--v-adblock)',
      },
      fontFamily: {
        display: ['"Space Grotesk"', 'system-ui', 'sans-serif'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'monospace'],
        sans: ['Inter', 'system-ui', 'sans-serif'],
      },
      borderRadius: {
        panel: '8px',
      },
    },
  },
  plugins: [],
}
