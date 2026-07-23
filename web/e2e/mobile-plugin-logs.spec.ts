import { expect, test, type Page, type WebSocketRoute } from '@playwright/test'
import type { PluginEngineLogLine } from '../src/lib/api/types'
import { setupMockApiWithToken } from './fixtures/mock-api'

async function expectNoHorizontalOverflow(page: Page): Promise<void> {
  const dimensions = await page.evaluate(() => ({
    viewport: window.innerWidth,
    document: document.documentElement.scrollWidth,
  }))
  expect(dimensions.document).toBeLessThanOrEqual(dimensions.viewport)
}

async function expectCircularButton(button: ReturnType<Page['getByRole']>): Promise<void> {
  const geometry = await button.evaluate((element) => {
    const bounds = element.getBoundingClientRect()
    return {
      width: bounds.width,
      height: bounds.height,
      radius: Number.parseFloat(getComputedStyle(element).borderTopLeftRadius),
    }
  })
  expect(geometry.width).toBeCloseTo(36, 0)
  expect(geometry.height).toBeCloseTo(36, 0)
  expect(geometry.radius).toBeGreaterThanOrEqual(geometry.width / 2)
}

async function setupMobilePluginLogStream(page: Page): Promise<WebSocketRoute[]> {
  await setupMockApiWithToken(page)
  await page.route('/api/intercept/health', (route) => route.fulfill({
    status: 200,
    contentType: 'application/json',
    body: JSON.stringify({ running: true, expected: true, installed_plugins: 2, active_plugins: 1, version: 'e2e' }),
  }))
  const sockets: WebSocketRoute[] = []
  await page.routeWebSocket(/\/intercept\/logs(?:\?|$)/, (socket) => {
    sockets.push(socket)
  })
  return sockets
}

function mobileFrame(): PluginEngineLogLine {
  return {
    time: '2026-07-23T08:12:34Z',
    level: 'warn',
    source: 'engine',
    extension: 'io.5gpn.apple-wloc',
    action: 'mobile-transform',
    phase: 'response',
    duration_ms: 7.2,
    script_digest: 'sha256:abcdef1234567890',
    url: 'https://gs-loc.apple.com/clls/wloc',
    message: 'mobile engine warning',
  }
}

test('mobile plugin logs use split filter rails, compact cards, circular actions, and expandable details', async ({ page }) => {
  const sockets = await setupMobilePluginLogStream(page)
  await page.goto('/plugin-logs')
  await expect.poll(() => sockets.length).toBe(1)
  await expect(page.getByTestId('page-plugin-logs')).toBeVisible()
  await expect(page.getByText('实时日志已连接')).toBeHidden()

  sockets[0].send(JSON.stringify(mobileFrame()))

  const levelFilters = page.getByRole('group', { name: '按级别筛选' })
  const pluginFilters = page.getByRole('group', { name: '按插件筛选' })
  await expect(levelFilters).toBeVisible()
  await expect(pluginFilters).toBeVisible()
  await expect(levelFilters.getByRole('button')).toHaveCount(4)
  await expect(pluginFilters.getByRole('button')).toHaveCount(3)
  const [levelBox, pluginBox] = await Promise.all([levelFilters.boundingBox(), pluginFilters.boundingBox()])
  expect(levelBox).not.toBeNull()
  expect(pluginBox).not.toBeNull()
  expect(pluginBox!.y).toBeGreaterThan(levelBox!.y + levelBox!.height)

  const pauseButton = page.getByRole('button', { name: '暂停' })
  const clearButton = page.getByRole('button', { name: '清空当前日志视图' })
  await expectCircularButton(pauseButton)
  await expectCircularButton(clearButton)

  const virtualScroll = page.getByTestId('virtual-scroll')
  await expect(virtualScroll).toBeVisible()
  await expect(virtualScroll.locator('..')).toHaveClass(/\bcard\b/)
  const row = virtualScroll.getByRole('button', { name: /展开日志详情/ }).filter({ hasText: 'mobile engine warning' })
  await expect(row).toBeVisible()
  await expect(row).toContainText('warn')
  await expect(row).toContainText('Apple WLOC Location Override · mobile-transform')
  await expect(row).toContainText(/\d{2}:\d{2}:\d{2}/)
  const title = row.getByText('Apple WLOC Location Override · mobile-transform', { exact: true })
  const message = row.getByText('mobile engine warning', { exact: true })
  const [titleBox, messageBox] = await Promise.all([title.boundingBox(), message.boundingBox()])
  expect(titleBox).not.toBeNull()
  expect(messageBox).not.toBeNull()
  expect(messageBox!.y).toBeGreaterThan(titleBox!.y)

  await row.click()
  const expandedRow = virtualScroll.getByRole('button', { name: /收起日志详情/ }).filter({ hasText: 'mobile engine warning' })
  await expect(expandedRow).toHaveAttribute('aria-expanded', 'true')
  await expect(expandedRow).toContainText('阶段 response')
  await expect(expandedRow).toContainText('耗时 7.2ms')
  await expect(expandedRow).toContainText('sha256:abcdef12…')
  await expectNoHorizontalOverflow(page)
})
