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

test('390px settings layout stacks upstream lists and keeps the add dialog in view', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')

  const card = page.getByTestId('upstreams-card')
  await expect(card).toBeVisible()
  const china = card.getByRole('region', { name: '境内组（china）' })
  const trust = card.getByRole('region', { name: '境外组（trust）' })
  const [chinaBox, trustBox] = await Promise.all([china.boundingBox(), trust.boundingBox()])
  expect(chinaBox).not.toBeNull()
  expect(trustBox).not.toBeNull()
  expect(trustBox!.y).toBeGreaterThan(chinaBox!.y + chinaBox!.height)
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(390)

  await card.getByTestId('upstreams-add-trust').click()
  const dialog = page.getByRole('dialog', { name: '添加境外 DNS' })
  await expect(dialog).toBeVisible()
  const dialogBox = await dialog.boundingBox()
  expect(dialogBox).not.toBeNull()
  expect(dialogBox!.x).toBeGreaterThanOrEqual(0)
  expect(dialogBox!.x + dialogBox!.width).toBeLessThanOrEqual(390)
})
