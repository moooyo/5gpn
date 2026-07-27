import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('overview page renders the live QPS + decision-distribution charts with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  // QPS and decision distribution both come from /api/status.
  await expect(page.getByText('决策分布', { exact: true })).toBeVisible()
  await expect(page.getByText('拦截', { exact: true })).toBeVisible()
  await expect(page.getByText('QPS 实时')).toBeVisible()

  // All dashboard charts are build-time SVG or flow HTML, with no canvas
  // runtime or eval. One sparkline and one donut: QPS used to be drawn in both
  // the hero and a full-size card below it, and the CN/foreign ring was the
  // decision ring's fourth and fifth segments magnified — that ring is a
  // segmented bar inside the decision card now.
  await expect(page.locator('[data-chart="sparkline"]')).toHaveCount(1)
  await expect(page.locator('[data-chart="donut"]')).toHaveCount(1)
  await expect(page.getByTestId('overview-arbitration')).toBeVisible()
  await expect(page.locator('[data-chart="gauge"]')).toHaveCount(0)
  await expect(page.locator('[data-chart="hbar"]')).toHaveCount(1)
  await expect(page.locator('canvas')).toHaveCount(0)

  expect(await csp.all()).toEqual([])
})

// The upstream card previously drew grouped vertical bars whose group was
// centred on the bars with a non-zero value. The fixture's china_err=3 against
// china_ok=2800 is exactly the case that broke it: the error bar was non-zero,
// so it claimed a layout slot, but its height rounded to sub-pixel, so nothing
// was drawn there — leaving the one visible bar sitting well left of the label
// underneath it. Each row now carries its own name, bar and value in one row
// box, so the label cannot drift away from the mark it describes.
test('overview page: every upstream bar stays aligned with its own label and value', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  const chart = page.locator('[data-chart="hbar"]')
  await expect(chart).toBeVisible()

  for (const [name, display] of [['china', '8.0 ms'], ['trust', '42.0 ms']] as const) {
    const row = chart.locator('> div').filter({ hasText: name })
    const nameBox = (await row.getByText(name, { exact: true }).boundingBox())!
    const valueBox = (await row.getByText(display, { exact: true }).boundingBox())!
    const trackBox = (await row.locator('[role="img"]').boundingBox())!

    // Name is flush with the left edge of its own bar; value is flush right.
    expect(Math.abs(nameBox.x - trackBox.x)).toBeLessThanOrEqual(1)
    expect(Math.abs((valueBox.x + valueBox.width) - (trackBox.x + trackBox.width))).toBeLessThanOrEqual(1)
    // Both sit directly above the bar they annotate, not beside another row's.
    expect(nameBox.y).toBeLessThan(trackBox.y)
    expect(trackBox.y - (nameBox.y + nameBox.height)).toBeLessThan(24)
  }

  // A handful of errors against thousands of successes is unreadable as a bar
  // on a shared linear scale, so health is stated instead of plotted.
  await expect(page.getByText('3 次失败')).toBeVisible()
  await expect(page.getByText('2 次失败')).toBeVisible()
})

test('overview page: the upstream card says which latency it is reporting', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  await expect(page.getByText('解析器往返', { exact: true })).toBeVisible()
  await expect(page.getByText(/不是到目标站点 IP 的延迟/)).toBeVisible()
})

test('overview page: the live/pause toggle switches to the paused state', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  await page.getByRole('button', { name: '暂停' }).click()
  await expect(page.getByText('已暂停')).toBeVisible()
})
