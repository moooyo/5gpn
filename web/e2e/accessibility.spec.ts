import AxeBuilder from '@axe-core/playwright'
import { expect, test, type Page } from '@playwright/test'
import { ALL_NAV_ITEMS } from '../src/app/navigation'
import { setupMockApiWithToken } from './fixtures/mock-api'

async function expectAccessible(page: Page) {
  const result = await new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'])
    .analyze()
  const violations = result.violations.filter((violation) => violation.impact === 'serious' || violation.impact === 'critical')
  expect(violations, JSON.stringify(violations, null, 2)).toEqual([])
}

test('login and every authenticated route have no serious WCAG A/AA violations', async ({ page }) => {
  await page.addInitScript(() => localStorage.removeItem('5gpn_token'))
  await page.goto('/')
  await expect(page.getByTestId('login-page')).toBeVisible()
  await expectAccessible(page)

  await setupMockApiWithToken(page)
  for (const item of ALL_NAV_ITEMS) {
    await page.goto(item.path)
    await expect(page.getByTestId(`page-${item.id}`)).toBeVisible()
    await expectAccessible(page)
  }
})

test('all five M3 themes apply from the profile menu', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  await page.getByRole('button', { name: '打开控制台菜单' }).click()

  for (const [label, theme] of [
    ['浅色', 'light'],
    ['深色', 'dark'],
    ['海洋', 'ocean'],
    ['森林', 'forest'],
    ['紫罗兰', 'violet'],
  ] as const) {
    await page.getByRole('tab', { name: label }).click()
    await expect(page.locator('html')).toHaveAttribute('data-theme', theme)
  }

  await expectAccessible(page)
})
