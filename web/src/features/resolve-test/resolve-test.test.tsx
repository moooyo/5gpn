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
    expect(screen.getByText('并发查询：国内 UDP ‖ 可信 DoT')).toBeInTheDocument()
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
})
