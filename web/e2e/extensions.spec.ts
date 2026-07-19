import { expect, test } from '@playwright/test'
import { gotoWithMock } from './fixtures/mock-api'

test('extension console imports and atomically toggles a Loon snapshot', async ({ page }) => {
  await gotoWithMock(page, '/extensions')

  await expect(page.getByTestId('page-extensions')).toBeVisible()
  await expect(page.getByTestId('mitm-readiness-notice')).toContainText('5GPN CA 证书')
  await expect(page.getByRole('link', { name: '前往配置向导安装' })).toHaveAttribute('href', '/setup-guide')
  const module = page.getByTestId('extension-mod-1234567890abcdef')
  await expect(module.getByText('Response Cleaner')).toBeVisible()
  await expect(module.getByText('MITM · 1')).toBeVisible()

  await module.getByRole('switch').click()
  await page.getByRole('dialog').getByRole('button', { name: '启用' }).click()
  await expect(module.getByRole('switch')).toBeChecked()
  await expect(module.getByText('MITM 总开关未开')).toBeVisible()

  await page.getByRole('button', { name: '从 URL 安装' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByTestId('extension-import-automatic')).toContainText('loon://import')
  await expect(dialog.getByLabel('格式')).toHaveCount(0)
  await expect(dialog.getByLabel('初始 $argument')).toHaveCount(0)
  await dialog.getByLabel('插件 URL').fill('loon://import?plugin=https://example.com/another.lpx')
  await dialog.getByRole('button', { name: '获取、固化并检查' }).click()
  await expect(page.getByText('Imported module snapshot')).toBeVisible()
})

test('URL extension update requires candidate review before replacement', async ({ page }) => {
  await gotoWithMock(page, '/extensions')
  const extension = page.getByTestId('extension-mod-1234567890abcdef')
  await extension.getByRole('button', { name: '检查更新' }).click()

  const dialog = page.getByRole('dialog', { name: /审查更新/ })
  await expect(dialog).toContainText('已审查候选')
  await expect(dialog).toContainText('ffffffff')
  const requestPromise = page.waitForRequest((request) =>
    request.url().endsWith('/update-apply') && request.method() === 'POST',
  )
  await dialog.getByRole('button', { name: '替换快照' }).click()
  const request = await requestPromise
  expect(request.postDataJSON()).toMatchObject({ snapshot_digest: 'f'.repeat(64) })
  await expect(page.getByText('Response Cleaner update')).toBeVisible()
})
