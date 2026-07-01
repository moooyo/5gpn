import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The Go server embeds this project's build output at cmd/5gpn-dns/web/dist
// (see cmd/5gpn-dns/webui.go: //go:embed web/dist) and serves it same-origin
// from the :9443 control plane, falling back to index.html for deep links.
export default defineConfig({
  plugins: [react()],
  base: '/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
})
