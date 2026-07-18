import { expect, test } from '@playwright/test'
import { gotoWithMock } from './fixtures/mock-api'

test('module console imports and atomically toggles a Surge snapshot', async ({ page }) => {
  await gotoWithMock(page, '/modules')

  await expect(page.getByTestId('page-modules')).toBeVisible()
  const module = page.getByTestId('module-mod-1234567890abcdef')
  await expect(module.getByText('Response Cleaner')).toBeVisible()
  await expect(module.getByText('api.example.com')).toBeVisible()

  await module.getByRole('switch').click()
  await page.getByRole('dialog').getByRole('button', { name: '启用' }).click()
  await expect(module.getByText('已启用')).toBeVisible()

  await page.getByRole('button', { name: /导入模块/ }).click()
  const dialog = page.getByRole('dialog')
  await dialog.getByLabel('模块 URL').fill('https://example.com/another.sgmodule')
  await dialog.getByRole('button', { name: '获取、固化并检查' }).click()
  await expect(page.getByText('Imported module snapshot')).toBeVisible()
})
