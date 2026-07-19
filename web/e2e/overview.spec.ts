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
  await expect(page.getByRole('heading', { name: 'QPS 实时' })).toBeVisible()

  // All dashboard charts are build-time SVG, with no canvas runtime or eval.
  await expect(page.locator('[data-chart="sparkline"]')).toHaveCount(2)
  await expect(page.locator('[data-chart="donut"]')).toHaveCount(2)
  await expect(page.locator('[data-chart="gauge"]')).toHaveCount(0)
  await expect(page.locator('[data-chart="bar"]')).toHaveCount(1)
  await expect(page.locator('canvas')).toHaveCount(0)

  expect(await csp.all()).toEqual([])
})

test('overview page: the live/pause toggle switches to the paused state', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  await page.getByRole('button', { name: '暂停' }).click()
  await expect(page.getByText('已暂停')).toBeVisible()
})
