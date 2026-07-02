import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// Build output (web/dist) is packaged as the 5gpn-web release tarball and
// served by the Go control server from DNS_WEB_DIR on disk (cmd/5gpn-dns/webui.go).
export default defineConfig({
  plugins: [react()],
  base: '/',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
})
