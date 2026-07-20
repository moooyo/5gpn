import { expect, test } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'

async function expectNoHorizontalOverflow(page: import('@playwright/test').Page) {
  const dimensions = await page.evaluate(() => ({ width: window.innerWidth, scrollWidth: document.documentElement.scrollWidth }))
  expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.width)
}

test('iPhone layout uses a drawer without squeezing or overflowing the page', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/overview')

  await expect(page.getByTestId('page-overview')).toBeVisible()
  await expect(page.getByTestId('desktop-sidebar')).toBeHidden()
  await expect(page.getByTestId('mobile-nav-open')).toBeVisible()
  await expectNoHorizontalOverflow(page)

  await page.getByTestId('mobile-nav-open').click()
  const drawer = page.getByTestId('mobile-sidebar-drawer')
  await expect(drawer).toBeVisible()
  await drawer.getByRole('link', { name: /DNS Log|解析日志/ }).click()

  await expect(page).toHaveURL(/\/logs$/)
  await expect(page.getByTestId('page-logs')).toBeVisible()
  await expect(drawer).toBeHidden()
  await expectNoHorizontalOverflow(page)
})

test('iPhone settings layout stacks controls and keeps dialogs in view', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/settings')

  const mitm = page.getByTestId('mitm-settings-card')
  await expect(mitm).toBeVisible()
  await expect(mitm.getByRole('switch')).toHaveCount(1)
  await mitm.getByRole('switch', { name: '启用 MITM' }).click()
  const mitmDialog = page.getByRole('dialog', { name: '启用 MITM？' })
  await expect(mitmDialog).toBeVisible()
  await mitmDialog.getByRole('button', { name: '启用 MITM' }).click()
  await expect(mitm.getByRole('switch')).toHaveCount(3)
  const mitmBox = await mitm.boundingBox()
  const viewportWidth = await page.evaluate(() => window.innerWidth)
  expect(mitmBox).not.toBeNull()
  expect(mitmBox!.x).toBeGreaterThanOrEqual(0)
  expect(mitmBox!.x + mitmBox!.width).toBeLessThanOrEqual(viewportWidth)

  const card = page.getByTestId('upstreams-card')
  await expect(card).toBeVisible()
  const china = card.getByRole('region', { name: '境内组（china）' })
  const trust = card.getByRole('region', { name: '境外组（trust）' })
  const [chinaBox, trustBox] = await Promise.all([china.boundingBox(), trust.boundingBox()])
  expect(chinaBox).not.toBeNull()
  expect(trustBox).not.toBeNull()
  expect(trustBox!.y).toBeGreaterThan(chinaBox!.y + chinaBox!.height)
  await expectNoHorizontalOverflow(page)

  await card.getByTestId('upstreams-add-trust').click()
  const dialog = page.getByRole('dialog', { name: '添加境外 DNS' })
  await expect(dialog).toBeVisible()
  const dialogBox = await dialog.boundingBox()
  expect(dialogBox).not.toBeNull()
  expect(dialogBox!.x).toBeGreaterThanOrEqual(0)
  expect(dialogBox!.x + dialogBox!.width).toBeLessThanOrEqual(viewportWidth)
})

test('iPhone extension layout stacks snapshots and keeps the import dialog in view', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/extensions')

  await expect(page.getByTestId('page-extensions')).toBeVisible()
  const wlocExtension = page.getByTestId('extension-io.5gpn.apple-wloc')
  const imported = page.getByTestId('extension-io.example.response-cleaner')
  const [wlocBox, importedBox] = await Promise.all([wlocExtension.boundingBox(), imported.boundingBox()])
  expect(wlocBox).not.toBeNull()
  expect(importedBox).not.toBeNull()
  expect(importedBox!.y).toBeGreaterThan(wlocBox!.y + wlocBox!.height)
  await expectNoHorizontalOverflow(page)

  await page.getByRole('button', { name: /从 URL 安装|Install from URL/ }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog).toBeVisible()
  const dialogBox = await dialog.boundingBox()
  expect(dialogBox).not.toBeNull()
  expect(dialogBox!.x).toBeGreaterThanOrEqual(0)
  expect(dialogBox!.x + dialogBox!.width).toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth))
})

test('iPhone extension permission and egress dialogs stay inside the viewport', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/extensions')

  const extension = page.getByTestId('extension-io.example.response-cleaner')
  await extension.getByRole('switch').click()
  const permissionDialog = page.getByRole('dialog', { name: /启用|Enable/ })
  await expect(permissionDialog.getByText('https://origin.example.net')).toHaveClass(/break-all/)
  let box = await permissionDialog.boundingBox()
  const viewportWidth = await page.evaluate(() => window.innerWidth)
  expect(box).not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(viewportWidth)
  await expectNoHorizontalOverflow(page)
  await permissionDialog.getByRole('button', { name: 'Close' }).click()

  await extension.getByRole('button', { name: /配置|Configure/ }).click()
  const egressDialog = page.getByRole('dialog', { name: /Response Cleaner/ })
  await expect(egressDialog.getByRole('combobox')).toBeVisible()
  box = await egressDialog.boundingBox()
  expect(box).not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(viewportWidth)
  await expectNoHorizontalOverflow(page)
})

test('iPhone host audit remains searchable and grouped without overflow', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/extensions/hosts')

  await expect(page.getByTestId('host-audit-view')).toBeVisible()
  await page.getByTestId('host-audit-search').fill('api.example.com')
  await expect(page.getByTestId('host-group-io.example.response-cleaner')).toContainText('api.example.com')
  await expectNoHorizontalOverflow(page)
})

test('iPhone native location setting keeps the map and precision fields inside the dialog', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.route('https://tile.openstreetmap.org/**', (route) => route.abort())
  await page.goto('/extensions')

  const extension = page.getByTestId('extension-io.5gpn.apple-wloc')
  await extension.getByRole('button', { name: /设置 · 2|Settings · 2/ }).click()
  const dialog = page.getByRole('dialog', { name: /Apple WLOC/ })
  await expect(dialog.getByTestId('extension-location-picker')).toBeVisible()
  const box = await dialog.boundingBox()
  expect(box).not.toBeNull()
  expect(box!.x).toBeGreaterThanOrEqual(0)
  expect(box!.x + box!.width).toBeLessThanOrEqual(await page.evaluate(() => window.innerWidth))
  await expectNoHorizontalOverflow(page)
})

test('iPhone setup guide distinguishes Android DoT from unsupported Android MITM', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/setup-guide')

  await expect(page.getByText('Android 9+')).toBeVisible()
  await expect(page.getByText('现代 Android 应用不支持 MITM 配置')).toBeVisible()
  await expect(page.getByRole('link', { name: '前往 MITM 设置' })).toHaveAttribute('href', '/settings')
  await expectNoHorizontalOverflow(page)
})
