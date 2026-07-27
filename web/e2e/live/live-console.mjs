/**
 * Live smoke of the DEPLOYED console on test-env.
 *
 * The Playwright suite in e2e/ drives a local mock server; this drives the real
 * gateway over its real HTTPS SNI with a real bearer token, which is the only
 * way to catch things a mock cannot have: a chunk that 404s from the served
 * tree, a CSP the daemon sends that the local harness does not, a route whose
 * data shape differs from the fixture.
 *
 * Run: node e2e/live/live-console.mjs
 */
import { chromium } from '@playwright/test'
import { mkdirSync, writeFileSync } from 'node:fs'

const GATEWAY = process.env.GW ?? '10.0.1.20'
const ORIGIN = process.env.CONSOLE_ORIGIN ?? 'https://console.5gpn.test'
const TOKEN = process.env.CONSOLE_TOKEN
const OUT = 'e2e/live/out'

if (!TOKEN) {
  console.error('CONSOLE_TOKEN is required')
  process.exit(2)
}

const ROUTES = [
  ['overview', '/overview', 'page-overview'],
  ['setup-guide', '/setup-guide', 'page-setup-guide'],
  ['policy-rules', '/policy-rules', 'page-policy-rules'],
  ['logs', '/logs', 'page-logs'],
  ['resolve-test', '/resolve-test', 'page-resolve-test'],
  ['extensions', '/extensions', 'page-extensions'],
  ['marketplace', '/marketplace', 'page-marketplace'],
  ['plugin-logs', '/plugin-logs', 'page-plugin-logs'],
  ['mihomo', '/mihomo', 'page-mihomo'],
  ['mihomo-config', '/mihomo-config', 'page-mihomo-config'],
  ['settings', '/settings', 'page-settings'],
]

mkdirSync(OUT, { recursive: true })

const browser = await chromium.launch({
  args: [`--host-resolver-rules=MAP console.5gpn.test ${GATEWAY}, MAP zash.5gpn.test ${GATEWAY}`],
})
const context = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 940 } })

const problems = []
const seen = new Set()
/**
 * This gateway runs a debug certificate. `ignoreHTTPSErrors` covers page and
 * XHR loads but NOT the service-worker script fetch, which Chromium validates
 * separately and refuses. That failure is a property of the test certificate,
 * not of the console, and it fires on every route because registerSW.js runs
 * on every page — so it is filtered here rather than allowed to bury real
 * findings. Nothing else is filtered.
 */
const DEBUG_CERT_NOISE = /ServiceWorker|SSL certificate error|Failed to read the 'localStorage' property/

const note = (text) => {
  if (DEBUG_CERT_NOISE.test(text)) return
  if (seen.has(text)) return
  seen.add(text)
  problems.push(text)
}

context.on('console', (message) => {
  if (message.type() === 'error') note(`console.error: ${message.text()}`)
})
context.on('weberror', (error) => note(`pageerror: ${error.error().message}`))
context.on('response', (response) => {
  if (response.status() >= 400 && new URL(response.url()).pathname.startsWith('/assets')) {
    note(`asset ${response.status()}: ${response.url()}`)
  }
})

await context.addInitScript(([key, token]) => {
  window.localStorage.setItem(key, token)
}, ['5gpn_token', TOKEN])

const page = await context.newPage()
await page.addInitScript(() => {
  window.__csp = []
  document.addEventListener('securitypolicyviolation', (event) => {
    window.__csp.push(`${event.violatedDirective} <- ${event.blockedURI}`)
  })
})

let failures = 0
for (const [name, path, testId] of ROUTES) {
  const before = problems.length
  await page.goto(`${ORIGIN}${path}`, { waitUntil: 'networkidle', timeout: 30000 })
  let ok = false
  try {
    await page.getByTestId(testId).waitFor({ state: 'visible', timeout: 12000 })
    ok = true
  } catch {
    note(`${name}: [data-testid="${testId}"] never appeared`)
  }
  const csp = await page.evaluate(() => window.__csp ?? [])
  if (csp.length > 0) note(`${name}: CSP ${csp.join(' | ')}`)
  await page.screenshot({ path: `${OUT}/${name}.png`, fullPage: false })
  const added = problems.length - before
  if (!ok || added > 0) failures += 1
  console.log(`${ok && added === 0 ? 'ok  ' : 'FAIL'} - ${name}${added ? ` (${added} problem(s))` : ''}`)
}

// Spot-check the changes this deployment is for, on live data.
console.log('\n== changed surfaces, on the real deployment ==')
const checks = []
const check = async (label, fn) => {
  try {
    const value = await fn()
    checks.push([label, value])
    console.log(`${value ? 'ok  ' : 'FAIL'} - ${label}`)
    if (!value) failures += 1
  } catch (error) {
    checks.push([label, false])
    console.log(`FAIL - ${label}: ${error.message}`)
    failures += 1
  }
}

await page.goto(`${ORIGIN}/logs`, { waitUntil: 'networkidle' })
await check('query log: decision pills are the legend, with window counts', async () =>
  (await page.getByRole('group', { name: /决策|Decision/ }).getByRole('button').count()) === 6)
await check('query log: search has an accessible name', async () =>
  (await page.getByRole('textbox', { name: /过滤查询日志|Filter the query log/ }).count()) === 1)

await page.goto(`${ORIGIN}/mihomo`, { waitUntil: 'networkidle' })
await check('mihomo: level filter exists (was hard-coded info)', async () =>
  (await page.getByRole('button', { name: /^debug/ }).count()) === 1)
await check('mihomo: payload search exists', async () =>
  (await page.getByRole('textbox', { name: /搜索日志内容|Search log payloads/ }).count()) === 1)

await page.goto(`${ORIGIN}/settings`, { waitUntil: 'networkidle' })
await check('settings: sticky section index', async () =>
  (await page.getByTestId('settings-nav').count()) === 1)
await check('settings: disabled DoT domain explains itself', async () =>
  (await page.getByText(/由安装器写入|Set by the installer/).count()) >= 1)

await page.goto(`${ORIGIN}/overview`, { waitUntil: 'networkidle' })
await check('overview: one sparkline, one donut (QPS drawn once)', async () =>
  (await page.locator('[data-chart="sparkline"]').count()) === 1
  && (await page.locator('[data-chart="donut"]').count()) === 1)
await check('overview: freshness readout', async () =>
  (await page.getByTestId('overview-freshness').count()) === 1)

// The palette is a lazily-loaded chunk, so the chord has to be given time to
// fetch it — and if that chunk ever fails to load, this is the check that says
// so, because the page itself shows nothing at all.
await page.keyboard.press('Control+k')
await check('global ⌘K palette opens', async () => {
  await page.getByRole('dialog').waitFor({ state: 'visible', timeout: 10000 })
  return (await page.getByRole('combobox').count()) >= 1
})
await page.keyboard.press('Escape')

// ---- mobile ---------------------------------------------------------------
// The handoff's three mobile rules (44px tap targets, filters in a sheet,
// primary actions reachable) only ever ran against the local mock. This drives
// the same deployment at a phone viewport.
console.log('')
console.log('== mobile (390x844), on the real deployment ==')
const phone = await context.newPage()
await phone.setViewportSize({ width: 390, height: 844 })
await phone.addInitScript(() => {
  window.__csp = []
  document.addEventListener('securitypolicyviolation', (event) => {
    window.__csp.push(`${event.violatedDirective} <- ${event.blockedURI}`)
  })
})

for (const [name, path, testId] of ROUTES) {
  const before = problems.length
  await phone.goto(`${ORIGIN}${path}`, { waitUntil: 'networkidle', timeout: 30000 })
  let ok = false
  try {
    await phone.getByTestId(testId).waitFor({ state: 'visible', timeout: 12000 })
    ok = true
  } catch {
    note(`mobile ${name}: [data-testid="${testId}"] never appeared`)
  }
  // Nothing may scroll sideways on a phone.
  const overflow = await phone.evaluate(() =>
    document.documentElement.scrollWidth - document.documentElement.clientWidth)
  if (overflow > 1) note(`mobile ${name}: ${overflow}px of horizontal overflow`)
  const csp = await phone.evaluate(() => window.__csp ?? [])
  if (csp.length > 0) note(`mobile ${name}: CSP ${csp.join(' | ')}`)
  await phone.screenshot({ path: `${OUT}/m-${name}.png` })
  const added = problems.length - before
  if (!ok || added > 0) failures += 1
  console.log(`${ok && added === 0 ? 'ok  ' : 'FAIL'} - mobile ${name}${added ? ` (${added} problem(s))` : ''}`)
}

// Every tap target on a phone is 44px. The console was full of 32-36px ones.
// Swept over every route, not one: the last audit found fifteen violations
// across nine files while the single-route check here reported clean, because
// none of the fifteen happened to be on the route it looked at.
const scanTapTargets = () => {
  const out = []
  // Hit-test rather than measure the layout box. A control may pad its target
  // with a ::before that reaches outside its own border box — the switch does
  // exactly that to keep a 32px track with a 44px target — and
  // getBoundingClientRect cannot see a pseudo-element, so measuring the box
  // reported two hundred false violations on one page. What matters is whether
  // a finger landing there actually hits the control, which is what
  // elementFromPoint answers.
  const reaches = (el, x, y) => {
    const hit = document.elementFromPoint(x, y)
    return hit !== null && (hit === el || el.contains(hit) || hit.contains(el))
  }
  for (const el of document.querySelectorAll('button, a[href], [role="button"], [role="switch"], input, select')) {
    if (el.closest('[role="listbox"], [hidden]')) continue
    const r = el.getBoundingClientRect()
    if (r.width === 0 || r.height === 0) continue
    // A visually-hidden input is not the tap target; the control wrapping it is.
    const style = getComputedStyle(el)
    if (style.opacity === '0' || style.visibility === 'hidden' || r.height <= 2 || r.width <= 2) continue
    const x = Math.round(r.left + r.width / 2)
    if (x < 0 || x > window.innerWidth) continue
    // Walk outward from each edge while the point still hits this control.
    let top = r.top
    let bottom = r.bottom
    for (let step = 1; step <= 12 && reaches(el, x, Math.round(top) - 1); step += 1) top -= 1
    for (let step = 1; step <= 12 && reaches(el, x, Math.round(bottom) + 1); step += 1) bottom += 1
    const effective = bottom - top
    if (effective < 40) {
      out.push(`${el.tagName.toLowerCase()}"${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 24)}" ${Math.round(effective)}px`)
    }
  }
  return out
}

let smallTotal = 0
for (const [name, path] of ROUTES) {
  await phone.goto(`${ORIGIN}${path}`, { waitUntil: 'networkidle' })
  const small = await phone.evaluate(scanTapTargets)
  if (small.length > 0) {
    smallTotal += small.length
    note(`mobile ${name}: ${small.length} tap target(s) under 40px: ${small.slice(0, 6).join(', ')}`)
    console.log(`FAIL - mobile tap targets on ${name} (${small.length} under 40px)`)
  }
}
if (smallTotal > 0) {
  failures += 1
} else {
  console.log(`ok   - mobile tap targets are all >= 40px across ${ROUTES.length} routes`)
}

writeFileSync(`${OUT}/report.json`, JSON.stringify({ problems, checks }, null, 2))
await browser.close()

console.log(`\n${problems.length} problem(s):`)
for (const problem of problems) console.log(`  - ${problem}`)
process.exit(failures > 0 ? 1 : 0)
