import { test, expect } from '@playwright/test'
import { collectCSPViolations } from './helpers/csp'

test('with no token, the login view renders with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await page.goto('/')
  await page.waitForLoadState('networkidle')

  await expect(page.getByRole('button', { name: '登录' })).toBeVisible()
  expect(await csp.all()).toEqual([])
})

test('a seeded token shows the app shell, and a non-401 getStatus failure does not log the user out', async ({
  page,
}) => {
  await page.addInitScript(() => {
    localStorage.setItem('5gpn_token', 't')
  })
  await page.goto('/')
  await page.waitForLoadState('networkidle')

  // getStatus hits the static csp-server (no /api/* route), so it never
  // comes back as a real payload — but it also never 401s, so the app must
  // stay on the shell rather than bouncing back to the login screen.
  await expect(page.getByRole('link', { name: '仪表盘' })).toBeVisible()
  await expect(page.getByRole('button', { name: '登录' })).toHaveCount(0)
})
