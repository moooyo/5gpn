import { test, expect } from '@playwright/test'
import { collectCSPViolations } from './helpers/csp'

test('app boots under production CSP with zero violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await page.goto('/')
  await page.waitForLoadState('networkidle')
  expect(await csp.all()).toEqual([])
})
