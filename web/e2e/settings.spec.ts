import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('settings page renders all config cards with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  const main = page.getByRole('main')
  await expect(main.getByText('DoT 服务')).toBeVisible()
  await expect(main.getByText('控制台', { exact: true })).toBeVisible()
  await expect(main.getByText('18443')).toBeVisible()
  await expect(main.getByText('Telegram 机器人')).toBeVisible()
  await expect(main.getByText('上游 DNS')).toBeVisible()
  await expect(main.getByText('国内解析 ECS')).toBeVisible()
  await expect(main.getByText('5GPN 控制台')).toBeVisible()

  // Cert status from the shared mock fixture (days_remaining: 82, not expired/broken) -> 有效.
  await expect(page.getByText('有效')).toBeVisible()

  // Greenfield controls: disabled + tooltip, never functional inputs.
  const domainInput = page.getByLabel('DoT 域名')
  await expect(domainInput).toBeDisabled()
  await expect(domainInput).toHaveAttribute('title', '暂由 CLI/SP-C 管理')
  const changePwBtn = page.getByRole('button', { name: '修改密码' })
  await expect(changePwBtn).toBeDisabled()

  expect(await csp.all()).toEqual([])
})

test('saving the ECS card (mock accepts) shows a success toast', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  await page.getByTestId('ecs-save').click()

  await expect(page.getByText('已应用 —— 国内组查询现携带')).toBeVisible()
})

test('turning the Telegram bot toggle off disables it (mock accepts) and shows a success toast', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  await page.getByRole('switch').click()

  await expect(page.getByText('已应用 Telegram 机器人配置。')).toBeVisible()
})
