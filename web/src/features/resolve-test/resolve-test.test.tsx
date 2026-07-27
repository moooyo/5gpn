import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { api } from '../../lib/api/client'
import type { ResolveTestResult } from '../../lib/api/types'
import ResolveTestPage from './ResolveTestPage'

vi.mock('../../lib/api/client', () => ({ api: { resolveTest: vi.fn() } }))

const CN_RESULT: ResolveTestResult = {
  name: 'baidu.com.',
  verdict: 'direct',
  reason: 'chnroute-cn',
  probes: [
    {
      server: '223.5.5.5:53',
      group: 'china',
      proto: 'udp',
      ips: ['110.242.68.66'],
      rcode: 'NOERROR',
      duration_ms: 5,
      selected: true,
    },
    {
      server: 'dot.example.com@8.8.8.8:853',
      group: 'trust',
      proto: 'dot',
      ips: ['110.242.68.66'],
      rcode: 'NOERROR',
      duration_ms: 40,
      selected: false,
    },
  ],
  chosen: 'china',
  chosen_ips: ['110.242.68.66'],
  client_ips: ['110.242.68.66'],
}

const BLOCK_RESULT: ResolveTestResult = {
  name: 'ads.doubleclick.net.',
  verdict: 'block',
  reason: 'block',
  probes: [],
  client_ips: [],
}

// A live extension capture. Note the verdict/reason are byte-identical to
// POLICY_RESULT below — that is the bug this feature exists to fix, and the
// reason the two fixtures must stay identical apart from the attribution.
const INTERCEPT_RESULT: ResolveTestResult = {
  name: 'api.example.com.',
  verdict: 'proxy',
  reason: 'force-proxy',
  probes: [],
  client_ips: ['10.0.0.1'],
  intercept: {
    module_id: 'io.moooyo.jd-price',
    module_name: '京东比价',
    matched_host: '*.example.com',
    ready: true,
  },
  intercept_module_count: 3,
}

const POLICY_RESULT: ResolveTestResult = {
  name: 'news.example.org.',
  verdict: 'proxy',
  reason: 'force-proxy',
  probes: [],
  client_ips: ['10.0.0.1'],
  policy: { rule_id: 'rule-3', order: 2, kind: 'domain-suffix', value: 'example.org' },
  intercept_module_count: 3,
}

// Enabled extension, MITM off: the capture never entered the table, so
// something else decided — but the extensions page still shows it as enabled.
const INERT_RESULT: ResolveTestResult = {
  name: 'api.example.com.',
  verdict: 'proxy',
  reason: 'fallback-gateway',
  probes: [],
  client_ips: ['10.0.0.1'],
  intercept: {
    module_id: 'io.moooyo.jd-price',
    module_name: '京东比价',
    matched_host: '*.example.com',
    ready: false,
    reason: 'mitm-disabled',
  },
  intercept_module_count: 1,
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.resolveTest).mockReset()
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
})

describe('ResolveTestPage', () => {
  it('renders the 国内直连 pill + chnroute-cn steps + client IPs for a chnroute-cn result', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(CN_RESULT)
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.type(screen.getByPlaceholderText('example.com'), 'baidu.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByText('国内直连')).toBeInTheDocument()
    expect(screen.getByText('未命中策略规则，进入 chnroute 仲裁')).toBeInTheDocument()
    expect(screen.getByText('并发查询：国内组 ‖ 可信组')).toBeInTheDocument()
    expect(screen.getByText('国内答案 IP ∈ chnroute → 采用，直连')).toBeInTheDocument()
    expect(screen.getByText('110.242.68.66')).toBeInTheDocument()
    expect(vi.mocked(api.resolveTest)).toHaveBeenCalledWith('baidu.com')
  })

  it('renders 拦截 + the NXDOMAIN steps for a block result', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(BLOCK_RESULT)
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.type(screen.getByPlaceholderText('example.com'), 'ads.doubleclick.net')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByText('拦截')).toBeInTheDocument()
    expect(screen.getByText('5gpn-dns 返回 NXDOMAIN')).toBeInTheDocument()
    expect(screen.getByText('客户端不发起任何连接')).toBeInTheDocument()
    expect(screen.getByText('(已拦截)')).toBeInTheDocument() // no client_ips -> blocked fallback
  })

  it('clicking an example chip fills the input and runs the test', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(CN_RESULT)
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.click(screen.getByRole('button', { name: 'baidu.com' }))

    await waitFor(() => expect(vi.mocked(api.resolveTest)).toHaveBeenCalledWith('baidu.com'))
    expect(screen.getByPlaceholderText('example.com')).toHaveValue('baidu.com')
    expect(await screen.findByText('国内直连')).toBeInTheDocument()
  })

  it('shows a loading state on the run button while the test is pending', async () => {
    let resolvePromise: (v: ResolveTestResult) => void = () => {}
    vi.mocked(api.resolveTest).mockReturnValue(
      new Promise((resolve) => {
        resolvePromise = resolve
      }),
    )
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.type(screen.getByPlaceholderText('example.com'), 'baidu.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    const runningButton = await screen.findByRole('button', { name: i18n.t('resolveTest.running') })
    expect(runningButton).toBeDisabled()

    resolvePromise(CN_RESULT)
    expect(await screen.findByRole('button', { name: i18n.t('resolveTest.run') })).toBeInTheDocument()
  })

  // The three attribution cases. INTERCEPT_RESULT and POLICY_RESULT carry the
  // identical verdict and reason on purpose — if the UI ever stops
  // distinguishing them, only these assertions notice.
  it('names the extension, its matched pattern, and what was skipped when a capture fired', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(INTERCEPT_RESULT)
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.type(screen.getByPlaceholderText('example.com'), 'api.example.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByTestId('resolve-test-attribution')).toBeInTheDocument()
    expect(screen.getByTestId('resolve-test-by-plugin')).toBeInTheDocument()
    expect(screen.getByText('京东比价')).toBeInTheDocument()
    expect(screen.getByText('io.moooyo.jd-price')).toBeInTheDocument()
    expect(screen.getByText('命中 *.example.com，判定在此终止')).toBeInTheDocument()
    // The plugin-specific decision path replaces the generic proxy-rule one.
    expect(screen.getByText('插件「京东比价」声明捕获该域名')).toBeInTheDocument()
    // A terminal verdict consults no upstream; say so rather than show '—'.
    expect(screen.getByText('未查询上游')).toBeInTheDocument()
  })

  it('states the capture-table miss as a finding and names the policy rule that won', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(POLICY_RESULT)
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.type(screen.getByPlaceholderText('example.com'), 'news.example.org')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByText('SOURCE=POLICY')).toBeInTheDocument()
    expect(screen.queryByTestId('resolve-test-by-plugin')).not.toBeInTheDocument()
    // Elimination is the conclusion, so the miss row must render.
    expect(screen.getByText('3 个已启用插件，均未声明该域名')).toBeInTheDocument()
    expect(screen.getByText('第 3 条 domain-suffix example.org')).toBeInTheDocument()
  })

  it('warns that an enabled extension declared the name but MITM left the capture inert', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(INERT_RESULT)
    const user = userEvent.setup()
    render(<ResolveTestPage />)

    await user.type(screen.getByPlaceholderText('example.com'), 'api.example.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByTestId('resolve-test-intercept-inert')).toBeInTheDocument()
    expect(screen.getByText('捕获未生效：MITM 未开启')).toBeInTheDocument()
    expect(
      screen.getByText('声明的 *.example.com 未进入捕获表，本次强制网关与该插件无关。'),
    ).toBeInTheDocument()
    // The capture-table row must agree with the notice above it: the extension
    // DID declare the name, so "none declared it" would send the operator
    // hunting for a rule that does not exist.
    expect(screen.getByText('已声明 *.example.com，但捕获表未生效')).toBeInTheDocument()
    expect(screen.queryByText('1 个已启用插件，均未声明该域名')).not.toBeInTheDocument()
    // Not attributed to the extension: it did not cause this verdict.
    expect(screen.queryByTestId('resolve-test-by-plugin')).not.toBeInTheDocument()
  })
})
