/**
 * check-bundle.mjs — verifies production JS/CSS and lazy-route budgets.
 *
 * Reads dist/.vite/manifest.json, measures the entry graph's static JS/CSS,
 * then measures every directly lazy-loaded route with its static imports.
 *
 * Exits 0 when under cap, 1 when over — prints a detailed breakdown either way.
 *
 * Usage:
 *   node scripts/check-bundle.mjs
 */

import { readFileSync, statSync } from 'fs'
import { createGzip } from 'zlib'
import { pipeline } from 'stream/promises'
import { createReadStream, createWriteStream, unlinkSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'

const ROOT = new URL('..', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1')

function readJson(rel) {
  return JSON.parse(readFileSync(join(ROOT, rel), 'utf8'))
}

/** Gzip a file and return the compressed byte size. */
async function gzipSize(filepath) {
  const tmp = join(tmpdir(), `bundle-check-${Date.now()}.gz`)
  try {
    await pipeline(
      createReadStream(filepath),
      createGzip({ level: 9 }),
      createWriteStream(tmp),
    )
    return statSync(tmp).size
  } finally {
    try { unlinkSync(tmp) } catch (e) {
      if (e.code !== 'ENOENT') throw e
    }
  }
}

async function main() {
  const manifest = readJson('dist/.vite/manifest.json')
  const baseline = readJson('bundle-baseline.json')

  // Find the entry chunk (isEntry: true)
  const entries = Object.values(manifest).filter(chunk => chunk.isEntry)
  if (entries.length === 0) {
    console.error('No entry chunk found in manifest')
    process.exit(1)
  }

  const gzipCache = new Map()
  async function gzipAsset(file) {
    if (!gzipCache.has(file)) gzipCache.set(file, await gzipSize(join(ROOT, 'dist', file)))
    return gzipCache.get(file)
  }

  // Collect all statically imported JS/CSS from the entry. Remember direct
  // dynamic roots, but do not traverse them into the initial graph.
  const visited = new Set()
  const jsFiles = []
  const cssFiles = new Set()
  const dynamicRoots = new Set()

  function collect(chunk) {
    if (!chunk || visited.has(chunk.file)) return
    visited.add(chunk.file)
    if (chunk.file?.endsWith('.js')) jsFiles.push(chunk.file)
    for (const css of chunk.css ?? []) cssFiles.add(css)
    for (const dynamic of chunk.dynamicImports ?? []) dynamicRoots.add(dynamic)
    // Static imports (not dynamicImports) — those ARE part of the initial load
    for (const imp of chunk.imports ?? []) {
      const dep = manifest[imp]
      if (dep) collect(dep)
    }
    // Do NOT traverse dynamicImports — those are code-split route chunks
  }

  for (const entry of entries) collect(entry)

  console.log(`Initial JS chunks (${jsFiles.length}):`)
  let totalGzip = 0
  for (const file of jsFiles) {
    let gz = 0
    try {
      gz = await gzipAsset(file)
    } catch {
      console.warn(`  could not read ${file}`)
      continue
    }
    const kib = gz / 1024
    totalGzip += gz
    console.log(`  ${file.padEnd(60)} ${kib.toFixed(2)} KiB (gz)`)
  }

  const totalKiB = totalGzip / 1024
  const capKiB = baseline.maxInitialJsGzipKiB
  const baselineKiB = baseline.initialJsGzipKiB
  const failures = []

  console.log(`\nTotal initial JS (gzip): ${totalKiB.toFixed(2)} KiB`)
  console.log(`Baseline:                ${baselineKiB.toFixed(2)} KiB`)
  console.log(`Cap:                     ${capKiB.toFixed(2)} KiB`)

  if (totalKiB > capKiB) {
    failures.push(`initial JS ${totalKiB.toFixed(2)} KiB exceeds ${capKiB.toFixed(2)} KiB`)
  } else {
    const pctValue = (totalKiB - baselineKiB) / baselineKiB * 100
    const pctStr = pctValue.toFixed(1)
    console.log(`\nPASS: ${totalKiB.toFixed(2)} KiB (${pctValue > 0 ? '+' : ''}${pctStr}% vs baseline)`)
  }

  let cssGzip = 0
  for (const file of cssFiles) cssGzip += await gzipAsset(file)
  const cssKiB = cssGzip / 1024
  console.log(`\nInitial CSS (gzip):       ${cssKiB.toFixed(2)} KiB`)
  console.log(`CSS baseline / cap:       ${baseline.initialCssGzipKiB.toFixed(2)} / ${baseline.maxInitialCssGzipKiB.toFixed(2)} KiB`)
  if (cssKiB > baseline.maxInitialCssGzipKiB) {
    failures.push(`initial CSS ${cssKiB.toFixed(2)} KiB exceeds ${baseline.maxInitialCssGzipKiB.toFixed(2)} KiB`)
  }

  let largestRoute = { id: '', kib: 0 }
  console.log(`\nLazy route JS (${dynamicRoots.size}):`)
  for (const rootId of dynamicRoots) {
    const routeFiles = new Set()
    const routeChunks = new Set()
    function collectRoute(id) {
      if (routeChunks.has(id)) return
      routeChunks.add(id)
      const chunk = manifest[id]
      if (!chunk) return
      if (chunk.file?.endsWith('.js') && !visited.has(chunk.file)) routeFiles.add(chunk.file)
      for (const imp of chunk.imports ?? []) collectRoute(imp)
    }
    collectRoute(rootId)
    let routeGzip = 0
    for (const file of routeFiles) routeGzip += await gzipAsset(file)
    const kib = routeGzip / 1024
    console.log(`  ${rootId.padEnd(54)} ${kib.toFixed(2)} KiB (gz)`)
    if (kib > largestRoute.kib) largestRoute = { id: rootId, kib }
  }
  console.log(`Largest lazy route:       ${largestRoute.kib.toFixed(2)} KiB (cap ${baseline.maxRouteJsGzipKiB.toFixed(2)} KiB)`)
  if (largestRoute.kib > baseline.maxRouteJsGzipKiB) {
    failures.push(`route ${largestRoute.id} ${largestRoute.kib.toFixed(2)} KiB exceeds ${baseline.maxRouteJsGzipKiB.toFixed(2)} KiB`)
  }

  if (failures.length > 0) {
    console.error(`\nFAIL: ${failures.join('; ')}`)
    console.error('Analyze large chunks with: npx vite-bundle-visualizer')
    process.exit(1)
  }
  console.log('\nBundle budgets: PASS')
}

main().catch(e => { console.error(e); process.exit(1) })
