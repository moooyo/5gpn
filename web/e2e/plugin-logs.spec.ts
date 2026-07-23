import { expect, test, type Page, type WebSocketRoute } from '@playwright/test'
import type { PluginEngineLogLine } from '../src/lib/api/types'
import { setupMockApiWithToken, VALID_TOKEN } from './fixtures/mock-api'

interface PluginLogStream {
  sockets: WebSocketRoute[]
  tickets: string[]
  authorizations: string[]
}

function logFrame(message: string, overrides: Partial<PluginEngineLogLine> = {}): PluginEngineLogLine {
  return {
    time: '2026-07-23T08:00:00Z',
    level: 'info',
    source: 'script',
    extension: 'io.5gpn.apple-wloc',
    action: 'rewrite-wloc',
    phase: 'request',
    message,
    ...overrides,
  }
}

async function setupPluginLogStream(page: Page): Promise<PluginLogStream> {
  await setupMockApiWithToken(page)

  const stream: PluginLogStream = { sockets: [], tickets: [], authorizations: [] }
  await page.route('/api/intercept/health', (route) => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ running: true, expected: true, installed_plugins: 2, active_plugins: 2, version: 'e2e' }),
  }))
  await page.route('/api/intercept/logs/ticket', async (route) => {
    const ticket = `e2e-plugin-ticket-${stream.tickets.length + 1}`
    stream.tickets.push(ticket)
    stream.authorizations.push(route.request().headers()['authorization'] ?? '')
    await route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ ticket, expires_in_seconds: 30 }),
    })
  })
  await page.routeWebSocket(/\/intercept\/logs(?:\?|$)/, (socket) => {
    stream.sockets.push(socket)
  })
  return stream
}

async function waitForSocket(stream: PluginLogStream, index = 0): Promise<WebSocketRoute> {
  await expect.poll(() => stream.sockets.length).toBeGreaterThan(index)
  return stream.sockets[index]
}

test('plugins navigation opens the connected log route and prepends the latest frame', async ({ page }) => {
  const stream = await setupPluginLogStream(page)
  await page.goto('/overview')

  const sidebar = page.getByTestId('desktop-sidebar')
  const pluginLogsLink = sidebar.getByRole('link', { name: '插件日志' })
  const pluginsGroup = sidebar.locator('nav > div').filter({ hasText: '插件日志' })
  await expect(pluginsGroup.getByText('插件', { exact: true })).toBeVisible()
  await expect(pluginsGroup.getByRole('link')).toHaveCount(3)
  await expect(pluginsGroup.getByRole('link', { name: '插件模块' })).toBeVisible()
  await expect(pluginsGroup.getByRole('link', { name: '插件市场' })).toBeVisible()

  await pluginLogsLink.click()
  await expect(page).toHaveURL(/\/plugin-logs$/)
  await expect(page.getByTestId('page-plugin-logs')).toBeVisible()
  const socket = await waitForSocket(stream)
  await expect(page.getByText('实时日志已连接')).toBeVisible()
  expect(stream.authorizations).toEqual([`Bearer ${VALID_TOKEN}`])
  expect(new URL(socket.url()).searchParams.get('ticket')).toBe('e2e-plugin-ticket-1')

  socket.send(JSON.stringify(logFrame('older plugin entry', { time: '2026-07-23T08:00:01Z' })))
  socket.send(JSON.stringify(logFrame('newest plugin entry', { time: '2026-07-23T08:00:02Z' })))

  const rows = page.getByTestId('virtual-scroll').getByRole('button', { name: /展开日志详情/ })
  await expect(rows).toHaveCount(2)
  await expect(rows.nth(0)).toContainText('newest plugin entry')
  await expect(rows.nth(1)).toContainText('older plugin entry')
})

test('desktop filters locally, buffers while paused, clears by watermark, and expands details', async ({ page }) => {
  const stream = await setupPluginLogStream(page)
  await page.goto('/plugin-logs')
  const socket = await waitForSocket(stream)
  await expect(page.getByText('实时日志已连接')).toBeVisible()

  socket.send(JSON.stringify(logFrame('apple routine info')))
  socket.send(JSON.stringify(logFrame('cleaner fatal failure', {
    level: 'error',
    extension: 'io.example.response-cleaner',
    action: 'clean-response',
  })))
  socket.send(JSON.stringify(logFrame('apple warning needle', { level: 'warn' })))
  await expect(page.getByText('cleaner fatal failure')).toBeVisible()

  const levelFilters = page.getByRole('group', { name: '按级别筛选' })
  await levelFilters.getByRole('button', { name: 'error' }).click()
  await expect(page.getByText('cleaner fatal failure')).toBeVisible()
  await expect(page.getByText('apple routine info')).toBeHidden()
  await expect(page.getByText('apple warning needle')).toBeHidden()

  await levelFilters.getByRole('button', { name: '全部级别' }).click()
  const pluginFilter = page.getByRole('combobox', { name: '按插件筛选' })
  await pluginFilter.click()
  await page.getByRole('option', { name: /Response Cleaner/ }).click()
  await expect(page.getByText('cleaner fatal failure')).toBeVisible()
  await expect(page.getByText('apple warning needle')).toBeHidden()

  await pluginFilter.click()
  await page.getByRole('option', { name: /全部插件/ }).click()
  const search = page.getByRole('textbox', { name: '搜索插件日志' })
  await search.fill('needle')
  await expect(page.getByText('apple warning needle')).toBeVisible()
  await expect(page.getByText('cleaner fatal failure')).toBeHidden()

  await search.fill('')
  await expect(page.getByText('apple routine info')).toBeVisible()
  await page.getByRole('button', { name: '暂停' }).click()
  socket.send(JSON.stringify(logFrame('buffered while paused')))
  await expect(page.getByText('buffered while paused')).toBeHidden()
  await expect(page.getByText('已暂停 · 1 条新日志已缓冲')).toBeVisible()

  await page.getByRole('button', { name: '恢复' }).click()
  await expect(page.getByText('buffered while paused')).toBeVisible()
  await page.getByRole('button', { name: '清空当前日志视图' }).click()
  await expect(page.getByText('buffered while paused')).toBeHidden()
  await expect(page.getByText('暂无插件日志')).toBeVisible()

  socket.send(JSON.stringify(logFrame('expanded engine failure\nstack line', {
    level: 'error',
    source: 'engine',
    phase: 'response',
    duration_ms: 18.4,
    script_digest: 'sha256:1234567890abcdef',
    url: 'https://gs-loc.apple.com/clls/wloc',
  })))
  const detailedRow = page.getByRole('button', { name: /展开日志详情/ }).filter({ hasText: 'expanded engine failure' })
  await expect(detailedRow).toBeVisible()
  await detailedRow.click()
  const expandedRow = page.getByRole('button', { name: /收起日志详情/ }).filter({ hasText: 'expanded engine failure' })
  await expect(expandedRow).toHaveAttribute('aria-expanded', 'true')
  await expect(expandedRow).toContainText('插件 ID')
  await expect(expandedRow).toContainText('sha256:12345678…')
  await expect(expandedRow).toContainText('18ms')
  await expect(expandedRow).toContainText('https://gs-loc.apple.com/clls/wloc')
})

test('a dropped stream shows the banner and reconnects with a newly minted ticket', async ({ page }) => {
  const stream = await setupPluginLogStream(page)
  await page.goto('/plugin-logs')

  const firstSocket = await waitForSocket(stream)
  await expect(page.getByText('实时日志已连接')).toBeVisible()
  expect(stream.tickets).toEqual(['e2e-plugin-ticket-1'])

  await firstSocket.close({ code: 1012, reason: 'sidecar restart' })
  await expect(page.getByText('实时日志已断开 · 每 3 秒自动重连，恢复后继续接收新日志')).toBeVisible()

  const secondSocket = await waitForSocket(stream, 1)
  await expect(page.getByText('实时日志已连接')).toBeVisible()
  await expect(page.getByText('实时日志已断开 · 每 3 秒自动重连，恢复后继续接收新日志')).toBeHidden()
  expect(stream.tickets).toEqual(['e2e-plugin-ticket-1', 'e2e-plugin-ticket-2'])
  expect(stream.authorizations).toEqual([`Bearer ${VALID_TOKEN}`, `Bearer ${VALID_TOKEN}`])
  expect(new URL(secondSocket.url()).searchParams.get('ticket')).toBe('e2e-plugin-ticket-2')
})
