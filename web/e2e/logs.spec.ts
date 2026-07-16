import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('logs page renders query-log rows with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/logs')
  await page.waitForLoadState('networkidle')

  const table = page.getByTestId('virtual-scroll')
  await expect(table.getByText('example.com.')).toBeVisible()
  await expect(table.getByText('baidu.com.')).toBeVisible()
  await expect(table.getByText('ads.tracking.io.')).toBeVisible()

  // reason-driven decision label (amendment A-H1): baidu.com.'s reason is
  // chnroute-cn, which must render 国内直连 — not 直连/代理 from the coarser
  // 'direct' verdict.
  await expect(table.getByText('国内直连')).toBeVisible()

  expect(await csp.all()).toEqual([])
})
