import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('resolve-test page runs a domain and renders the verdict + decision path with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  await page.getByPlaceholder('example.com').fill('example.com')
  await page.getByRole('button', { name: '测试', exact: true }).click()

  // The shared mock fixture's /api/resolve-test response has reason
  // 'chnroute-foreign' -> the 境外代理 pill + its decision-path steps.
  await expect(page.getByText('境外代理')).toBeVisible()
  await expect(page.getByText('未命中策略规则，进入 chnroute 仲裁')).toBeVisible()
  await expect(page.getByText('93.184.216.34')).toBeVisible()

  expect(await csp.all()).toEqual([])
})

test('resolve-test page: clicking an example chip runs the test', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  await page.getByRole('button', { name: 'baidu.com', exact: true }).click()

  await expect(page.getByPlaceholder('example.com')).toHaveValue('baidu.com')
  await expect(page.getByText('境外代理')).toBeVisible()
})
