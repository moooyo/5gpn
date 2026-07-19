import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'
import { ALL_NAV_ITEMS } from '../src/app/navigation'

test('every route in the shared navigation manifest renders its own page, CSP-clean', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  for (const item of ALL_NAV_ITEMS) {
    await page.goto(item.path)
    await page.waitForLoadState('networkidle')
    expect(new URL(page.url()).pathname).toBe(item.path)
    await expect(page.getByTestId(`page-${item.id}`)).toBeVisible()
  }
  expect(await csp.all()).toEqual([])
})

test('an unknown route redirects explicitly to the overview page', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/not-a-real-route')
  await expect(page).toHaveURL(/\/overview$/)
  await expect(page.getByTestId('page-overview')).toBeVisible()
})

test('the retired modules route has no compatibility alias', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/modules')
  await expect(page).toHaveURL(/\/overview$/)
  await expect(page.getByTestId('page-overview')).toBeVisible()
})

test('ProfileMenu dropdown + theme + language switch stay CSP-clean', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.waitForLoadState('networkidle')

  // The Base UI profile menu is loaded on demand to keep its focus and
  // positioning runtime out of the initial bundle.
  await page.getByRole('button', { name: /打开控制台菜单|Open console menu/i }).click()

  // Switch language to English via the language SegmentedControl, then
  // theme to dark via the five-theme catalog.
  await page.getByRole('tab', { name: 'English' }).click()
  await page.getByRole('tab', { name: /^(dark|深色)$/i }).click()

  expect(await csp.all()).toEqual([])
})
