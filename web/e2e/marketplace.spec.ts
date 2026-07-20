import { expect, test } from '@playwright/test'
import { gotoWithMock } from './fixtures/mock-api'

test('marketplace is a top-level source browser with install confirmation', async ({ page }) => {
  await gotoWithMock(page, '/marketplace')

  const marketplace = page.getByTestId('page-marketplace')
  await expect(marketplace).toBeVisible()
  await expect(page.getByRole('link', { name: '插件市场' })).toHaveClass(/sidebar-tab-active/)
  await expect(marketplace.getByText('Marketplace Response Cleaner')).toBeVisible()
  await expect(marketplace.getByText('接管 · 1')).toBeVisible()
  await expect(marketplace.getByText('动作 · 1')).toBeVisible()

  await marketplace.getByLabel('搜索市场插件').fill('does-not-exist')
  await expect(marketplace.getByText('该市场暂无匹配插件')).toBeVisible()
  await marketplace.getByLabel('搜索市场插件').fill('response')

  await marketplace.getByRole('button', { name: '安装快照' }).click()
  const dialog = page.getByRole('dialog', { name: /安装快照前确认/ })
  await expect(dialog).toContainText('插件使用不可变的清单与脚本快照运行')
  await expect(dialog).toContainText('extensions.example.test')
  const installRequest = page.waitForRequest((request) =>
    request.url().endsWith('/api/interception/marketplaces/io.5gpn.official/entries/io.example.marketplace-cleaner/install') && request.method() === 'POST',
  )
  await dialog.getByRole('button', { name: '确认安装' }).click()
  expect((await installRequest).postDataJSON()).toMatchObject({ marketplace_revision: expect.any(String), module_revision: expect.any(String) })
  const installedDialog = page.getByRole('dialog', { name: /快照已安装/ })
  await expect(installedDialog).toContainText('Marketplace Response Cleaner')
  await expect(installedDialog).toContainText('已关闭')
})

test('add marketplace sends the optional local display name', async ({ page }) => {
  await gotoWithMock(page, '/marketplace')
  await page.getByRole('button', { name: '添加市场' }).click()
  const dialog = page.getByRole('dialog', { name: /添加插件市场/ })
  await dialog.getByLabel('市场 URL').fill('https://community.example.test/index.json')
  await dialog.getByLabel('显示名称（可选）').fill('社区镜像')
  const request = page.waitForRequest((candidate) => candidate.url().endsWith('/api/interception/marketplaces') && candidate.method() === 'POST')
  await dialog.getByRole('button', { name: '添加并拉取' }).click()
  expect((await request).postDataJSON()).toEqual(expect.objectContaining({ url: 'https://community.example.test/index.json', name: '社区镜像' }))
  await expect(page.getByRole('button', { name: /社区镜像/ })).toBeVisible()
})

test('marketplace refresh and cards remain usable at a narrow viewport', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  await gotoWithMock(page, '/marketplace')
  const marketplace = page.getByTestId('page-marketplace')
  const refreshRequest = page.waitForRequest((request) => request.url().endsWith('/api/interception/marketplaces/io.5gpn.official/refresh') && request.method() === 'POST')
  await marketplace.getByRole('button', { name: '刷新市场源' }).click()
  await refreshRequest
  await expect(marketplace.getByRole('button', { name: '安装快照' })).toBeVisible()
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth)).toBe(true)
})
