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
  await expect(main.getByText('HTTPS 解密（MITM）')).toBeVisible()
  await expect(main.getByRole('switch', { name: '启用 MITM' })).not.toBeChecked()
  await expect(main.getByRole('switch', { name: 'MitM over HTTP/2' })).toHaveCount(0)
  await expect(page.getByTestId('mitm-host-audit-link')).toHaveAttribute('href', '/extensions/hosts')
  await expect(main.getByText('mihomo 功能模块')).toBeVisible()
  await expect(main.getByText(':5060', { exact: true })).toBeVisible()
  await expect(main.getByText('TCP · Host/SNI')).toHaveCount(1)
  await expect(main.getByText('UDP · 仅 QUIC')).toHaveCount(1)
  const quicBlock = page.getByTestId('ingress-module-block-quic-443')
  await expect(quicBlock.getByText('阻止 HTTP/3 / QUIC')).toBeVisible()
  await expect(quicBlock.getByText('UDP · 目标端口 443')).toBeVisible()
  await expect(quicBlock.getByRole('switch', { name: '切换 阻止 HTTP/3 / QUIC' })).toBeChecked()
  await expect(main.getByText('Telegram 机器人')).toBeVisible()
  await expect(main.getByText('上游 DNS')).toBeVisible()
  await expect(main.getByText('国内解析 ECS')).toBeVisible()
  await expect(main.getByText('5GPN 控制台')).toBeVisible()

  // Cert status from the shared mock fixture (days_remaining: 82, not expired/broken) -> 有效.
  await expect(page.getByText('有效')).toBeVisible()

  // Installer-owned controls stay read-only in the web console.
  const domainInput = page.getByLabel('DoT 域名')
  await expect(domainInput).toBeDisabled()
  await expect(domainInput).toHaveValue('dot.example.test')
  await expect(page.getByText('API 鉴权')).toBeVisible()
  await expect(page.getByText('Bearer', { exact: true })).toBeVisible()
  await expect(page.getByTestId('appearance-card')).toBeVisible()

  expect(await csp.all()).toEqual([])
})

test('MITM master applies only after explicit dialog confirmation', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  const card = page.getByTestId('mitm-settings-card')
  const master = card.getByRole('switch', { name: '启用 MITM' })
  await expect(master).not.toBeChecked()
  await master.click()
  const dialog = page.getByRole('dialog', { name: '启用 MITM？' })
  await expect(dialog).toContainText('启动 sidecar')
  const requestPromise = page.waitForRequest((request) =>
    request.url().endsWith('/api/interception/settings') && request.method() === 'PUT',
  )
  await dialog.getByRole('button', { name: '启用 MITM' }).click()

  const request = await requestPromise
  expect(request.postDataJSON()).toMatchObject({
    enabled: true,
    http2: true,
    quic_fallback_protection: true,
  })
  expect((request.postDataJSON() as { revision?: string }).revision).toMatch(/^[0-9a-f]{64}$/)
  await expect(page.getByText('MITM 已启用。')).toBeVisible()
  await expect(card.getByRole('switch', { name: 'MitM over HTTP/2' })).toBeChecked()
  await expect(card.getByRole('switch', { name: 'QUIC 回退保护' })).toBeChecked()
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

test('the default-enabled Speedtest ingress module stays a draft until disable confirmation', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  const card = page.getByTestId('ingress-ports-card')
  const toggle = card.getByRole('switch', { name: '切换 Speedtest 兼容' })
  await expect(toggle).toBeChecked()
  await toggle.click()
  await expect(toggle).not.toBeChecked()

  const requestPromise = page.waitForRequest((request) =>
    request.url().endsWith('/api/mihomo/ingress-modules/speedtest-5060') && request.method() === 'PUT',
  )
  await card.getByTestId('ingress-ports-save').click()
  const dialog = page.getByRole('dialog', { name: '停用所选模块？' })
  await expect(dialog.getByText(/连接可能中断/)).toBeVisible()
  await dialog.getByRole('button', { name: '保存并应用' }).click()

  const request = await requestPromise
  const body = request.postDataJSON() as { enabled?: unknown; revision?: unknown }
  expect(body.enabled).toBe(false)
  expect(body.revision).toMatch(/^[0-9a-f]{64}$/)
  await expect(page.getByText('已应用 mihomo 功能模块配置。')).toBeVisible()
})

test('the default HTTP3 and QUIC guard confirms before allowing UDP 443', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')
  await page.waitForLoadState('networkidle')

  const card = page.getByTestId('ingress-ports-card')
  const module = page.getByTestId('ingress-module-block-quic-443')
  const toggle = module.getByRole('switch', { name: '切换 阻止 HTTP/3 / QUIC' })
  await expect(toggle).toBeChecked()
  await toggle.click()

  const requestPromise = page.waitForRequest((request) =>
    request.url().endsWith('/api/mihomo/ingress-modules/block-quic-443') && request.method() === 'PUT',
  )
  await card.getByTestId('ingress-ports-save').click()
  const dialog = page.getByRole('dialog', { name: '允许 HTTP/3 与 QUIC？' })
  await expect(dialog).toContainText('兼容性异常')
  await dialog.getByRole('button', { name: '保存并应用' }).click()

  const body = (await requestPromise).postDataJSON() as { enabled?: unknown; revision?: unknown }
  expect(body.enabled).toBe(false)
  expect(body.revision).toMatch(/^[0-9a-f]{64}$/)
  await expect(page.getByText('已应用 mihomo 功能模块配置。')).toBeVisible()
})

test('online WLOC extension uses the native location setting and generic enable confirmation', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.route('https://tile.openstreetmap.org/**', (route) => route.abort())
  await page.goto('/extensions')
  await page.waitForLoadState('networkidle')

  const extension = page.getByTestId('extension-io.5gpn.apple-wloc')
  await extension.getByRole('button', { name: '设置 · 2' }).click()
  const dialog = page.getByRole('dialog', { name: /Apple WLOC/ })
  await dialog.getByLabel('搜索城市').fill('深圳')
  await dialog.getByRole('button', { name: '搜索', exact: true }).click()
  await dialog.getByRole('option', { name: /深圳市/ }).click()
  const fields = dialog.getByRole('spinbutton')
  await expect(fields).toHaveCount(3)
  await expect(fields.nth(0)).toHaveValue('113.94114')
  await expect(fields.nth(1)).toHaveValue('22.544577')
  await fields.nth(2).fill('25')
  const settingsRequest = page.waitForRequest((request) =>
    request.url().includes('/api/interception/modules/io.5gpn.apple-wloc') && request.method() === 'PUT',
  )
  await dialog.getByRole('button', { name: '保存' }).click()
  expect((await settingsRequest).postDataJSON()).toMatchObject({
    settings: {
      location: { longitude: 113.94114, latitude: 22.544577, accuracy: 25 },
      failClosed: true,
    },
  })
  await expect(page.getByText('插件设置已保存。')).toBeVisible()

  await extension.getByRole('switch').click()
  const confirm = page.getByRole('dialog', { name: /启用 Apple WLOC/ })
  await expect(confirm).toBeVisible()
  await confirm.getByRole('button', { name: '启用' }).click()
})
