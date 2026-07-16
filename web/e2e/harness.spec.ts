import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('authed app shell renders under the harness with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/overview')
  // '仪表盘' renders twice (sidebar nav label + topbar title) once the shell
  // is authed and mounted — .first() sidesteps the strict-mode ambiguity
  // while still asserting the shell (not the login screen) is showing.
  await expect(page.getByText('仪表盘').first()).toBeVisible()
  expect(await csp.all()).toEqual([])
})
