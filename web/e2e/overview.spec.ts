import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('overview page renders the live QPS + decision-distribution charts with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  // LIVE-only dashboard (trimmed in B3): QPS + 决策分布, both from
  // /api/stats. The former 当前出口 and 流量趋势/预览 cards were dropped —
  // their backend endpoints (/api/exits, /api/traffic, /api/nodes) were
  // removed in SP-2; exit switching now lives in the egress feature.
  await expect(page.getByText('决策分布', { exact: true })).toBeVisible()
  await expect(page.getByText('拦截')).toBeVisible()
  await expect(page.getByText('QPS 实时', { exact: true })).toBeVisible()

  // echarts (CanvasRenderer, core-only registration from task 5.1) actually
  // renders real <canvas> elements under the strict production CSP — the
  // proof this e2e exists for. Three charts at this commit: the compact QPS
  // metric-card sparkline, the larger "QPS 实时" sparkline, and the 决策分布
  // donut.
  await page.waitForFunction(() => document.querySelectorAll('canvas').length >= 3)
  const canvasCount = await page.locator('canvas').count()
  expect(canvasCount).toBeGreaterThanOrEqual(3)

  expect(await csp.all()).toEqual([])
})

test('overview page: the live/pause toggle switches to the paused state', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  await page.getByRole('button', { name: '暂停' }).click()
  await expect(page.getByText('已暂停')).toBeVisible()
})
