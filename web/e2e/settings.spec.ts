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
  await expect(main.getByText('127.0.0.1:443')).toBeVisible()
  await expect(main.getByText('入口端口')).toBeVisible()
  await expect(main.getByText(':5060', { exact: true })).toBeVisible()
  await expect(main.getByText('TCP · Host/SNI')).toBeVisible()
  await expect(main.getByText('UDP · 仅 QUIC')).toBeVisible()
  await expect(main.getByText('Telegram 机器人')).toBeVisible()
  await expect(main.getByText('上游 DNS')).toBeVisible()
  await expect(main.getByText('国内解析 ECS')).toBeVisible()
  await expect(main.getByText('5GPN 控制台')).toBeVisible()

  // Cert status from the shared mock fixture (days_remaining: 82, not expired/broken) -> 有效.
  await expect(page.getByText('有效')).toBeVisible()

  // Installer-owned controls stay read-only in the web console.
  const domainInput = page.getByLabel('DoT 域名')
  await expect(domainInput).toBeDisabled()
  await expect(domainInput).toHaveAttribute('title', '请通过安装/管理 TUI 配置')
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

test('upstream DNS uses list controls and validates protocol-specific additions', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  const card = page.getByTestId('upstreams-card')
  await expect(card).toBeVisible()
  await expect(card.locator('textarea')).toHaveCount(0)
  await expect(card.getByText('223.5.5.5', { exact: true })).toBeVisible()
  await expect(card.getByText('dot.example.com@8.8.8.8:853', { exact: true })).toBeVisible()

  await card.getByTestId('upstreams-add-trust').click()
  const dialog = page.getByRole('dialog', { name: '添加境外 DNS' })
  await expect(dialog).toBeVisible()
  await expect(dialog.getByTestId('upstreams-protocol-dot')).toHaveAttribute('aria-checked', 'true')
  await dialog.getByTestId('upstreams-add-trust-confirm').click()
  await expect(dialog.getByText('请输入 TLS 服务器名称。')).toBeVisible()
  await expect(dialog.getByText('请输入服务器 IP。')).toBeVisible()

  await dialog.getByTestId('upstreams-server-name').fill('dns.cloudflare.com')
  await dialog.getByTestId('upstreams-address').fill('1.1.1.1')
  await dialog.getByTestId('upstreams-add-trust-confirm').click()
  await expect(card.getByText('dns.cloudflare.com@1.1.1.1', { exact: true })).toBeVisible()
})

test('turning the Telegram bot toggle off disables it (mock accepts) and shows a success toast', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  await page.getByRole('switch', { name: 'Telegram 机器人状态' }).click()

  await expect(page.getByText('已应用 Telegram 机器人配置。')).toBeVisible()
})

test('the Speedtest ingress module stays a draft until confirmation, then applies TCP and UDP together', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  const card = page.getByTestId('ingress-ports-card')
  const toggle = card.getByRole('switch', { name: '切换 Speedtest 兼容' })
  await expect(toggle).not.toBeChecked()
  await toggle.click()
  await expect(toggle).toBeChecked()

  const requestPromise = page.waitForRequest((request) =>
    request.url().endsWith('/api/mihomo/ingress-modules/speedtest-5060') && request.method() === 'PUT',
  )
  await card.getByTestId('ingress-ports-save').click()
  const dialog = page.getByRole('dialog', { name: '启用入口端口？' })
  await expect(dialog.getByText(/云安全组/)).toBeVisible()
  await dialog.getByRole('button', { name: '保存并应用' }).click()

  const request = await requestPromise
  const body = request.postDataJSON() as { enabled?: unknown; revision?: unknown }
  expect(body.enabled).toBe(true)
  expect(body.revision).toMatch(/^[0-9a-f]{64}$/)
  await expect(page.getByText('已应用入口端口配置。')).toBeVisible()
})
