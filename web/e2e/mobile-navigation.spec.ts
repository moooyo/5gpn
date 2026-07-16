import { expect, test } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'

test('390px layout uses a drawer without squeezing or overflowing the page', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')

  await expect(page.getByTestId('page-overview')).toBeVisible()
  await expect(page.getByTestId('desktop-sidebar')).toBeHidden()
  await expect(page.getByTestId('mobile-nav-open')).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)

  await page.getByTestId('mobile-nav-open').click()
  const drawer = page.getByTestId('mobile-sidebar-drawer')
  await expect(drawer).toBeVisible()
  await drawer.getByRole('link', { name: /DNS Log|解析日志/ }).click()

  await expect(page).toHaveURL(/\/logs$/)
  await expect(page.getByTestId('page-logs')).toBeVisible()
  await expect(drawer).toBeHidden()
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)
})
