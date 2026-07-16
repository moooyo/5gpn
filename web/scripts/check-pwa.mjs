/**
 * Verify service-worker takeover/cleanup, font runtime caching, and deploy-size
 * budgets from generated output rather than trusting config intent alone.
 */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { extname, join } from 'node:path'

const swURL = new URL('../dist/sw.js', import.meta.url)
const source = readFileSync(swURL, 'utf8')
const distDir = fileURLToPath(new URL('../dist', import.meta.url))
const budgets = JSON.parse(readFileSync(new URL('../bundle-baseline.json', import.meta.url), 'utf8'))
const failures = []

if (!source.includes('self.skipWaiting()')) {
  failures.push('missing immediate self.skipWaiting()')
}
if (source.includes('SKIP_WAITING')) {
  failures.push('skipWaiting is still gated on a client message')
}
if (!/\.clientsClaim\(\)/.test(source)) {
  failures.push('missing clientsClaim()')
}
if (!/\.cleanupOutdatedCaches\(\)/.test(source)) {
  failures.push('missing cleanupOutdatedCaches()')
}
if (/\.woff2?/.test(source)) {
  failures.push('font files are still present in the service-worker precache')
}
if (!source.includes('5gpn-fonts-v1')) {
  failures.push('missing runtime CacheFirst font cache')
}

function filesUnder(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name)
    return entry.isDirectory() ? filesUnder(path) : [path]
  })
}

const files = filesUnder(distDir)
const precacheExts = new Set(['.js', '.css', '.html', '.svg'])
const precacheBytes = files
  .filter((path) => precacheExts.has(extname(path)) && !path.endsWith('/sw.js'))
  .reduce((sum, path) => sum + statSync(path).size, 0)
const fontFiles = files.filter((path) => /\.woff2?$/.test(path))
const fontBytes = fontFiles.reduce((sum, path) => sum + statSync(path).size, 0)

if (precacheBytes > budgets.maxPrecacheKiB * 1024) {
  failures.push(`precache assets ${(precacheBytes / 1024).toFixed(1)} KiB exceed ${budgets.maxPrecacheKiB} KiB`)
}
if (fontFiles.length > budgets.maxFontAssets) {
  failures.push(`font asset count ${fontFiles.length} exceeds ${budgets.maxFontAssets}`)
}
if (fontBytes > budgets.maxFontKiB * 1024) {
  failures.push(`font assets ${(fontBytes / 1024).toFixed(1)} KiB exceed ${budgets.maxFontKiB} KiB`)
}

if (failures.length > 0) {
  console.error(`PWA update policy check failed: ${failures.join('; ')}`)
  process.exit(1)
}

console.log(
  `PWA policy: immediate takeover; ${(precacheBytes / 1024).toFixed(1)} KiB precache; ` +
  `${fontFiles.length} runtime-cached fonts (${(fontBytes / 1024).toFixed(1)} KiB)`,
)
