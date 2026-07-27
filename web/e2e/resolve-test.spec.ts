import { test, expect } from '@playwright/test'
import { setupMockApiWithToken } from './fixtures/mock-api'
import { collectCSPViolations } from './helpers/csp'

test('resolve-test page runs a domain and renders the verdict + decision path with zero CSP violations', async ({ page }) => {
  const csp = collectCSPViolations(page)
  await setupMockApiWithToken(page)
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  await page.getByPlaceholder('example.com').fill('example.com')
  await page.getByRole('button', { name: '测试', exact: true }).click()

  // The shared mock fixture's /api/resolve-test response has reason
  // 'chnroute-foreign'. Overview, the query log and this page share one
  // decision namespace now, so the label reads the same on all three.
  const result = page.getByTestId('resolve-test-result')
  await expect(result.getByText('境外走网关').first()).toBeVisible()
  await expect(page.getByText('未命中策略规则，进入 chnroute 仲裁')).toBeVisible()
  await expect(page.getByText('93.184.216.34')).toBeVisible()
  // The chain no longer ends at the verdict.
  await expect(result.getByRole('link', { name: '在日志中筛选此域名' })).toHaveAttribute('href', '/logs?q=example.com')

  expect(await csp.all()).toEqual([])
})

test('resolve-test page: clicking an example chip runs the test', async ({ page }) => {
  await setupMockApiWithToken(page)
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  // Each example now states which decision it is expected to hit, so its
  // accessible name is the domain plus that label.
  await page.getByRole('button', { name: /^baidu\.com/ }).click()

  await expect(page.getByPlaceholder('example.com')).toHaveValue('baidu.com')
  await expect(page.getByTestId('resolve-test-result').getByText('境外走网关').first()).toBeVisible()
})

// Attribution: an extension capture and an operator proxy rule produce the
// identical verdict and reason, so these two cases differ ONLY in the
// attribution block. A regression that drops it is invisible to every other
// assertion in this file.
const GATEWAY_BASE = {
  name: 'api.example.com.',
  verdict: 'proxy',
  reason: 'force-proxy',
  probes: [],
  client_ips: ['10.0.0.1'],
  intercept_module_count: 3,
}

async function stubResolveTest(page: import('@playwright/test').Page, body: unknown) {
  await page.route('**/api/resolve-test*', (route) =>
    route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(body) }),
  )
}

test('resolve-test names the extension behind a capture-driven gateway verdict', async ({ page }) => {
  await setupMockApiWithToken(page)
  await stubResolveTest(page, {
    ...GATEWAY_BASE,
    intercept: {
      module_id: 'io.moooyo.jd-price',
      module_name: '京东比价',
      matched_host: '*.example.com',
      ready: true,
    },
  })
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  await page.getByPlaceholder('example.com').fill('api.example.com')
  await page.getByRole('button', { name: '测试', exact: true }).click()

  await expect(page.getByTestId('resolve-test-attribution')).toBeVisible()
  await expect(page.getByTestId('resolve-test-by-plugin')).toBeVisible()
  // The name appears in the evidence block, the decision step, and the raw
  // response — scope to the evidence block rather than relaxing to .first().
  const declaredBy = page.getByTestId('resolve-test-declared-by')
  await expect(declaredBy.getByText('京东比价')).toBeVisible()
  await expect(declaredBy.getByText('io.moooyo.jd-price')).toBeVisible()
  await expect(page.getByText('命中 *.example.com，判定在此终止')).toBeVisible()
})

test('resolve-test states the capture-table miss and names the winning policy rule', async ({ page }) => {
  await setupMockApiWithToken(page)
  await stubResolveTest(page, {
    ...GATEWAY_BASE,
    name: 'news.example.org.',
    policy: { rule_id: 'rule-3', order: 2, kind: 'domain-suffix', value: 'example.org' },
  })
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  await page.getByPlaceholder('example.com').fill('news.example.org')
  await page.getByRole('button', { name: '测试', exact: true }).click()

  await expect(page.getByText('SOURCE=POLICY')).toBeVisible()
  await expect(page.getByTestId('resolve-test-by-plugin')).toHaveCount(0)
  // The exclusion is the finding, so the miss row renders rather than hides.
  await expect(page.getByText('3 个已启用插件，均未声明该域名')).toBeVisible()
  await expect(page.getByText('第 3 条 domain-suffix example.org')).toBeVisible()
})

test('resolve-test warns when an enabled extension declared the name but MITM left it inert', async ({ page }) => {
  await setupMockApiWithToken(page)
  await stubResolveTest(page, {
    ...GATEWAY_BASE,
    reason: 'fallback-gateway',
    intercept_module_count: 1,
    intercept: {
      module_id: 'io.moooyo.jd-price',
      module_name: '京东比价',
      matched_host: '*.example.com',
      ready: false,
      reason: 'mitm-disabled',
    },
  })
  await page.goto('/resolve-test')
  await page.waitForLoadState('networkidle')

  await page.getByPlaceholder('example.com').fill('api.example.com')
  await page.getByRole('button', { name: '测试', exact: true }).click()

  await expect(page.getByTestId('resolve-test-intercept-inert')).toBeVisible()
  await expect(page.getByText('捕获未生效：MITM 未开启')).toBeVisible()
  await expect(page.getByTestId('resolve-test-by-plugin')).toHaveCount(0)
})
