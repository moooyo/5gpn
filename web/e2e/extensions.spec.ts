import { expect, test } from '@playwright/test'
import { gotoWithMock } from './fixtures/mock-api'

test('extension console installs and atomically toggles a native snapshot', async ({ page }) => {
  await gotoWithMock(page, '/extensions')

  await expect(page.getByTestId('page-extensions')).toBeVisible()
  await expect(page.getByTestId('mitm-readiness-notice')).toContainText('5GPN CA 证书')
  await expect(page.getByRole('link', { name: '前往配置向导安装' })).toHaveAttribute('href', '/setup-guide')
  await expect(page.getByTestId('extension-traffic-contract')).toHaveCount(0)
  await expect(page.getByRole('tab', { name: '插件市场' })).toHaveCount(0)
  const module = page.getByTestId('extension-io.example.response-cleaner')
  await expect(module.getByText('Response Cleaner')).toBeVisible()
  await expect(module.getByText('接管 · 1')).toBeVisible()

  await module.getByRole('button', { name: '上移 Response Cleaner' }).click()
  const reorderDialog = page.getByRole('dialog', { name: /确认调整执行顺序/ })
  await expect(reorderDialog).toContainText('first-match')
  await expect(reorderDialog).toContainText('调整前')
  await expect(reorderDialog).toContainText('调整后')
  const reorderRequest = page.waitForRequest((request) =>
    request.url().endsWith('/api/interception/modules/reorder') && request.method() === 'PUT',
  )
  await reorderDialog.getByRole('button', { name: '确认调整顺序' }).click()
  expect((await reorderRequest).postDataJSON()).toMatchObject({ execution_order: ['io.example.response-cleaner', 'io.5gpn.apple-wloc'] })

  await module.getByRole('switch').click()
  await page.getByRole('dialog').getByRole('button', { name: '启用' }).click()
  await expect(module.getByRole('switch')).toBeChecked()
  await expect(module.getByText('MITM 总开关未开')).toBeVisible()

  await page.getByRole('button', { name: '从 URL 安装' }).click()
  const dialog = page.getByRole('dialog')
  await expect(dialog.getByTestId('extension-install-url-info')).toContainText('5gpn.io/v1')
  await expect(dialog.getByLabel('原生插件 manifest')).toHaveCount(0)
  await dialog.getByLabel('Manifest URL').fill('https://example.com/extension.yaml')
  await dialog.getByRole('button', { name: '获取、固化并检查' }).click()
  await expect(page.getByTestId('extension-io.example.imported').getByText('Imported native extension')).toBeVisible()
})

test('URL extension update requires candidate review before replacement', async ({ page }) => {
  await gotoWithMock(page, '/extensions')
  const extension = page.getByTestId('extension-io.example.response-cleaner')
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
  await expect(page.getByText('v1.1.0')).toBeVisible()
})
