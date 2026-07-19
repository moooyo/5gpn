#!/usr/bin/env node
/**
 * e2e/server/csp-server.mjs
 *
 * Minimal static server for the built web/dist SPA that serves the EXACT
 * production Content-Security-Policy header on every response (verbatim
 * match to cmd/5gpn-dns/api.go's securityHeadersMiddleware) plus SPA
 * history-fallback to index.html for extension-less routes. This is the
 * runtime-CSP e2e gate's server: it lets Playwright load the real built
 * assets (JS module, extracted CSS, fonts, manifest) under the same CSP
 * the daemon ships, so a real violation shows up as a real test failure
 * instead of being masked by a dev server that never sets the header.
 *
 * Path traversal protection:
 *   - URL pathname is decoded with decodeURIComponent (400 on malformed).
 *   - The resolved filesystem path is verified to stay inside DIST (403
 *     if it escapes).
 *
 * Usage: node e2e/server/csp-server.mjs [port]
 *        Default port: 4173
 */
import http from 'node:http'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const PORT = parseInt(process.argv[2] ?? '4173', 10)
const HOST = process.argv[3] ?? '127.0.0.1'
const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DIST = path.resolve(__dirname, '../../dist')
const SEP = path.sep

// Verbatim production CSP (cmd/5gpn-dns/api.go securityHeadersMiddleware).
// Do not alter this string.
const CSP =
  "default-src 'self'; img-src 'self' data: https://tile.openstreetmap.org; font-src 'self'; " +
  "style-src 'self' 'unsafe-inline'; style-src-elem 'self'; " +
  "style-src-attr 'unsafe-inline'; worker-src 'self'; connect-src 'self'; object-src 'none'; " +
  "base-uri 'self'; frame-ancestors 'none'"

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript',
  '.css': 'text/css',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.woff2': 'font/woff2',
  '.woff': 'font/woff',
  '.webmanifest': 'application/manifest+json',
  '.ico': 'image/x-icon',
}

/** Decode the URL pathname; return null on malformed percent-encoding. */
function decodePath(raw) {
  try {
    return decodeURIComponent(raw)
  } catch {
    return null
  }
}

/**
 * Resolve a decoded path segment under DIST and verify it does not escape.
 * Returns the resolved absolute path, or null if it escapes DIST.
 */
function safeResolve(decoded) {
  // Prefix with '.' so path.resolve treats it as relative even if it starts with '/'
  const candidate = path.resolve(DIST, '.' + decoded)
  if (candidate === DIST || candidate.startsWith(DIST + SEP)) {
    return candidate
  }
  return null
}

const server = http.createServer((req, res) => {
  res.setHeader('Content-Security-Policy', CSP)

  const url = new URL(req.url ?? '/', `http://127.0.0.1:${PORT}`)

  const decoded = decodePath(url.pathname)
  if (decoded === null) {
    res.writeHead(400, { 'Content-Type': 'text/plain' })
    res.end('Bad Request')
    return
  }

  const fsPath = safeResolve(decoded)
  if (fsPath === null) {
    res.writeHead(403, { 'Content-Type': 'text/plain' })
    res.end('Forbidden')
    return
  }

  let servePath = fsPath
  const stat = fs.statSync(fsPath, { throwIfNoEntry: false })
  const hasExt = path.extname(decoded) !== ''
  if (!stat || stat.isDirectory()) {
    if (hasExt) {
      res.writeHead(404, { 'Content-Type': 'text/plain' })
      res.end('Not Found')
      return
    }
    // SPA history fallback: no extension, no matching file.
    servePath = path.join(DIST, 'index.html')
  }

  const ext = path.extname(servePath)
  const ct = MIME[ext] ?? 'application/octet-stream'
  try {
    const body = fs.readFileSync(servePath)
    res.writeHead(200, { 'Content-Type': ct, 'Cache-Control': 'no-store' })
    res.end(body)
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' })
    res.end('Not Found')
  }
})

server.listen(PORT, HOST, () => {
  process.stdout.write(`listening on http://${HOST}:${PORT}\n`)
})

process.on('SIGTERM', () => { server.close(); process.exit(0) })
process.on('SIGINT', () => { server.close(); process.exit(0) })
