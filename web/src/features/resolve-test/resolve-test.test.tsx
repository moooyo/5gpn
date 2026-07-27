import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { api } from '../../lib/api/client'
import type { ResolveTestResult } from '../../lib/api/types'
import ResolveTestPage from './ResolveTestPage'
import { MemoryRouter } from 'react-router-dom'

/** The result card links to /policy-rules and /logs now, so the page needs a
 *  router in scope. */
function renderResolveTest() {
  return render(<MemoryRouter><ResolveTestPage /></MemoryRouter>)
}

/** The example buttons now state which decision they are expected to hit, so
 *  a decision label appears both there and in the result — queries for the
 *  verdict have to say which one they mean. */
const result = () => within(screen.getByTestId('resolve-test-result'))

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
    renderResolveTest()

    await user.type(screen.getByPlaceholderText('example.com'), 'baidu.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByTestId('resolve-test-result')).toBeInTheDocument()
    expect(result().getByText('国内直连')).toBeInTheDocument()
    expect(screen.getByText('未命中策略规则，进入 chnroute 仲裁')).toBeInTheDocument()
    expect(screen.getByText('并发查询：国内组 ‖ 可信组')).toBeInTheDocument()
    expect(screen.getByText('国内答案 IP ∈ chnroute → 采用，直连')).toBeInTheDocument()
    expect(screen.getByText('110.242.68.66')).toBeInTheDocument()
    expect(vi.mocked(api.resolveTest)).toHaveBeenCalledWith('baidu.com')
  })

  it('renders 拦截 + the NXDOMAIN steps for a block result', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(BLOCK_RESULT)
    const user = userEvent.setup()
    renderResolveTest()

    await user.type(screen.getByPlaceholderText('example.com'), 'ads.doubleclick.net')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))

    expect(await screen.findByTestId('resolve-test-result')).toBeInTheDocument()
    expect(result().getByText('拦截')).toBeInTheDocument()
    expect(screen.getByText('5gpn-dns 返回 NXDOMAIN')).toBeInTheDocument()
    expect(screen.getByText('客户端不发起任何连接')).toBeInTheDocument()
    expect(screen.getByText('(已拦截)')).toBeInTheDocument() // no client_ips -> blocked fallback
  })

  it('clicking an example chip fills the input and runs the test', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(CN_RESULT)
    const user = userEvent.setup()
    renderResolveTest()

    await user.click(screen.getByRole('button', { name: /^baidu\.com/ }))

    await waitFor(() => expect(vi.mocked(api.resolveTest)).toHaveBeenCalledWith('baidu.com'))
    expect(screen.getByPlaceholderText('example.com')).toHaveValue('baidu.com')
    expect(await screen.findByTestId('resolve-test-result')).toBeInTheDocument()
    expect(result().getByText('国内直连')).toBeInTheDocument()
  })

  /**
   * The chain used to end at the verdict: the result named a rule it could not
   * take you to, and finding the same domain in the log meant memorizing it
   * and retyping it on another page.
   */
  it('links the result back to the matched rule and to the log filtered by this domain', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue({
      ...CN_RESULT,
      policy: { rule_id: 'rule-7', order: 3, kind: 'domain-suffix', value: 'baidu.com' },
    })
    const user = userEvent.setup()
    renderResolveTest()

    await user.type(screen.getByPlaceholderText('example.com'), 'baidu.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))
    await screen.findByTestId('resolve-test-result')

    const actions = within(screen.getByTestId('resolve-test-actions'))
    expect(actions.getByRole('link', { name: i18n.t('resolveTest.viewMatchedRule') }))
      .toHaveAttribute('href', '/policy-rules?highlight=rule-7')
    expect(actions.getByRole('link', { name: i18n.t('resolveTest.filterInLogs') }))
      .toHaveAttribute('href', '/logs?q=baidu.com')
  })

  it('offers only the log hand-off when no policy rule produced the verdict', async () => {
    vi.mocked(api.resolveTest).mockResolvedValue(CN_RESULT)
    const user = userEvent.setup()
    renderResolveTest()

    await user.type(screen.getByPlaceholderText('example.com'), 'baidu.com')
    await user.click(screen.getByRole('button', { name: i18n.t('resolveTest.run') }))
    await screen.findByTestId('resolve-test-result')

    const actions = within(screen.getByTestId('resolve-test-actions'))
    expect(actions.queryByRole('link', { name: i18n.t('resolveTest.viewMatchedRule') })).toBeNull()
    expect(actions.getByRole('link', { name: i18n.t('resolveTest.filterInLogs') })).toBeInTheDocument()
  })

  /** Each run used to overwrite the last, so comparing two domains meant
   *  writing one answer down first. */
  it('keeps recent results available for comparison', async () => {
    const user = userEvent.setup()
    vi.mocked(api.resolveTest).mockResolvedValueOnce(CN_RESULT).mockResolvedValueOnce(BLOCK_RESULT)
    renderResolveTest()

    await user.click(screen.getByRole('button', { name: /^baidu\.com/ }))
    await screen.findByTestId('resolve-test-result')
    await user.click(screen.getByRole('button', { name: /^ads\.doubleclick\.net/ }))
    await waitFor(() => expect(result().getByText('拦截')).toBeInTheDocument())

    const chips = within(screen.getByTestId('resolve-test-history')).getAllByRole('button')
    expect(chips.map((chip) => chip.textContent)).toEqual([BLOCK_RESULT.name, CN_RESULT.name])
    await user.click(chips[1])
    expect(result().getByText('国内直连')).toBeInTheDocument()
  })

  it('shows a loading state on the run button while the test is pending', async () => {
    let resolvePromise: (v: ResolveTestResult) => void = () => {}
    vi.mocked(api.resolveTest).mockReturnValue(
      new Promise((resolve) => {
        resolvePromise = resolve
      }),
    )
    const user = userEvent.setup()
    renderResolveTest()

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
    renderResolveTest()

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
    renderResolveTest()

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
    renderResolveTest()

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
