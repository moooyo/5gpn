import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import i18n from '../../i18n'
import { Toaster } from '../../components/ds'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'
import { ThemeProvider } from '../../lib/theme'
import { api } from '../../lib/api/client'
import { ApiError } from '../../lib/api/http'
import type { ECSView, IngressModulesView, MITMSettingsView, Status, TGBotView, UpstreamsView } from '../../lib/api/types'
import SettingsPage from './SettingsPage'
import { TgbotCard } from './_cards'

vi.mock('../../lib/api/client', () => ({
  api: {
    getUpstreams: vi.fn(),
    putUpstreams: vi.fn(),
    getEcs: vi.fn(),
    putEcs: vi.fn(),
    getTgbot: vi.fn(),
    putTgbot: vi.fn(),
    getIngressModules: vi.fn(),
    putIngressModule: vi.fn(),
    getMITMSettings: vi.fn(),
    putMITMSettings: vi.fn(),
    getInterceptModules: vi.fn(),
  },
}))

const UPSTREAMS: UpstreamsView = { china: ['223.5.5.5', '119.29.29.29'], trust: ['dns.google@8.8.8.8'] }
const ECS: ECSView = { subnet: '122.96.30.0/24' }
const TGBOT: TGBotView = { admins: [123456789], token_set: true, state: 'healthy' }
const INGRESS: IngressModulesView = {
  revision: 'r1',
  modules: [
    { id: 'speedtest-5060', port: 5060, networks: ['tcp', 'udp'], sniffers: ['http', 'tls', 'quic'], enabled: true, manageable: true },
    { id: 'block-quic-443', port: 443, networks: ['udp'], sniffers: [], enabled: true, manageable: true },
  ],
}
const MITM: MITMSettingsView = {
  revision: 'mitm-r1',
  enabled: false,
  http2: true,
  quic_fallback_protection: true,
}

function statusValue(overrides: Partial<StatusValue> = {}): StatusValue {
  return {
    dnsState: 'healthy',
    mihomoState: 'healthy',
    dnsOk: true,
    mihomoOk: true,
    loading: false,
    status: {
      version: 'dev+abc1234',
      uptime_seconds: 3600,
      stats: {} as Status['stats'],
      dot_domain: 'dot.example.com',
      cert: { not_after: '2026-10-01T00:00:00Z', days_remaining: 82, expired: false },
    },
    ...overrides,
  }
}

function renderSettings(status: StatusValue = statusValue()) {
  return render(
    <ThemeProvider>
      <StatusContext.Provider value={status}>
        <MemoryRouter>
          <SettingsPage />
          <Toaster />
        </MemoryRouter>
      </StatusContext.Provider>
    </ThemeProvider>,
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.getUpstreams).mockReset().mockResolvedValue(UPSTREAMS)
  vi.mocked(api.putUpstreams).mockReset().mockResolvedValue(UPSTREAMS)
  vi.mocked(api.getEcs).mockReset().mockResolvedValue(ECS)
  vi.mocked(api.putEcs).mockReset().mockResolvedValue(ECS)
  vi.mocked(api.getTgbot).mockReset().mockResolvedValue(TGBOT)
  vi.mocked(api.putTgbot).mockReset().mockResolvedValue(TGBOT)
  vi.mocked(api.getIngressModules).mockReset().mockResolvedValue(INGRESS)
  vi.mocked(api.putIngressModule).mockReset().mockImplementation(async (id, enabled) => ({
    revision: 'r2',
    modules: INGRESS.modules.map((module) => module.id === id ? { ...module, enabled } : module),
  }))
  vi.mocked(api.getMITMSettings).mockReset().mockResolvedValue(MITM)
  vi.mocked(api.putMITMSettings).mockReset().mockImplementation(async (update) => ({ ...update, revision: 'mitm-r2' }))
  vi.mocked(api.getInterceptModules).mockReset().mockResolvedValue({ revision: 'extensions-r1', catalog_url: '', active_capture_hosts: [], execution_order: [], available_egress_groups: [], modules: [] })
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
})

describe('SettingsPage', () => {
  it('loads upstreams/ecs/tgbot on mount and prefills the cards', async () => {
    renderSettings()

    await waitFor(() => expect(api.getUpstreams).toHaveBeenCalled())
    expect(api.getEcs).toHaveBeenCalled()
    expect(api.getTgbot).toHaveBeenCalled()
    expect(api.getIngressModules).toHaveBeenCalled()
    expect(api.getMITMSettings).toHaveBeenCalled()

    expect(await screen.findByText('223.5.5.5')).toBeInTheDocument()
    expect(screen.getByText('119.29.29.29')).toBeInTheDocument()
    expect(screen.getByText('dns.google@8.8.8.8')).toBeInTheDocument()
    expect(screen.getAllByText('UDP')).toHaveLength(2)
    expect(screen.getByText('DoT')).toBeInTheDocument()
    expect(screen.getByDisplayValue('122.96.30.0/24')).toBeInTheDocument()
    expect(screen.getByDisplayValue('123456789')).toBeInTheDocument()
    expect(screen.getByTestId('mitm-host-audit-link')).toHaveAttribute('href', '/extensions/hosts')
    expect(screen.queryByTestId('mitm-capabilities')).not.toBeInTheDocument()
    expect(screen.getByText('Material 3 · 安全 DNS 网关')).toBeInTheDocument()
  })

  it('saves HTTP/2 and QUIC capabilities without changing the MITM master state', async () => {
    vi.mocked(api.getMITMSettings).mockResolvedValue({ ...MITM, enabled: true })
    const user = userEvent.setup()
    renderSettings()

    const http2 = await screen.findByRole('switch', { name: i18n.t('settings.mitmHTTP2') })
    await waitFor(() => expect(http2).toBeChecked())
    await user.click(http2)

    await waitFor(() => expect(api.putMITMSettings).toHaveBeenCalledWith({
      revision: 'mitm-r1',
      enabled: true,
      http2: false,
      quic_fallback_protection: true,
    }))
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('confirms the master switch before starting MITM', async () => {
    const user = userEvent.setup()
    renderSettings()

    const master = await screen.findByRole('switch', { name: i18n.t('settings.mitmMaster') })
    await waitFor(() => expect(master).not.toBeDisabled())
    await user.click(master)
    expect(api.putMITMSettings).not.toHaveBeenCalled()

    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(i18n.t('settings.mitmEnableConfirmBody'))).toBeInTheDocument()
    await user.click(within(dialog).getByRole('button', { name: i18n.t('settings.mitmEnableAction') }))
    await waitFor(() => expect(api.putMITMSettings).toHaveBeenCalledWith({
      revision: 'mitm-r1',
      enabled: true,
      http2: true,
      quic_fallback_protection: true,
    }))
    expect(await screen.findByTestId('mitm-capabilities')).toBeInTheDocument()
  })

  it('loads the default-enabled ingress module, keeps changes as a draft, then confirms disable', async () => {
    const user = userEvent.setup()
    renderSettings()

    expect(await screen.findByText('Speedtest 兼容')).toBeInTheDocument()
    expect(screen.getByText(':5060')).toBeInTheDocument()
    expect(screen.getAllByText('TCP · Host/SNI')).toHaveLength(1)
    expect(screen.getAllByText('UDP · 仅 QUIC')).toHaveLength(1)

    await user.click(screen.getByRole('switch', { name: '切换 Speedtest 兼容' }))
    expect(api.putIngressModule).not.toHaveBeenCalled()
    await user.click(screen.getByTestId('ingress-ports-save'))
    expect(api.putIngressModule).not.toHaveBeenCalled()

    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: i18n.t('settings.ingressSave') }))
    await waitFor(() => expect(api.putIngressModule).toHaveBeenCalledWith('speedtest-5060', false, 'r1'))
  })

  it('defaults to blocking HTTP/3 and QUIC, then confirms before allowing UDP 443', async () => {
    const user = userEvent.setup()
    renderSettings()

    const card = await screen.findByTestId('ingress-module-block-quic-443')
    expect(within(card).getByText('阻止 HTTP/3 / QUIC')).toBeInTheDocument()
    expect(within(card).getByText('UDP · 目标端口 443')).toBeInTheDocument()
    expect(within(card).getByText('由 mihomo 拒绝')).toBeInTheDocument()
    const toggle = within(card).getByRole('switch', { name: '切换 阻止 HTTP/3 / QUIC' })
    expect(toggle).toBeChecked()

    await user.click(toggle)
    expect(screen.getByRole('switch', { name: '切换 Speedtest 兼容' })).toBeDisabled()
    await user.click(screen.getByTestId('ingress-ports-save'))
    const dialog = await screen.findByRole('dialog', { name: '允许 HTTP/3 与 QUIC？' })
    expect(within(dialog).getByText(i18n.t('settings.quicBlockDisableConfirmBody'))).toBeInTheDocument()
    await user.click(within(dialog).getByRole('button', { name: i18n.t('settings.ingressSave') }))
    await waitFor(() => expect(api.putIngressModule).toHaveBeenCalledWith('block-quic-443', false, 'r1'))
  })

  it('keeps a module unavailable for custom YAML and links to the mihomo editor', async () => {
    vi.mocked(api.getIngressModules).mockResolvedValue({
      revision: 'custom',
      modules: [{ ...INGRESS.modules[0], enabled: true, manageable: false, reason: 'custom_config' }],
    })
    renderSettings()

    const toggle = await screen.findByRole('switch', { name: '切换 Speedtest 兼容' })
    expect(toggle).toBeDisabled()
    expect(screen.getByRole('link', { name: 'mihomo 配置' })).toHaveAttribute('href', '/mihomo-config')
  })

  it('shows an ingress load error and retries without reloading the page', async () => {
    const user = userEvent.setup()
    vi.mocked(api.getIngressModules).mockRejectedValueOnce(new ApiError(0, 'offline'))
    renderSettings()

    expect(await screen.findByTestId('ingress-ports-load-error')).toHaveTextContent('无法加载当前 mihomo 功能模块配置')
    await user.click(screen.getByRole('button', { name: '重新加载' }))

    expect(await screen.findByText('Speedtest 兼容')).toBeInTheDocument()
    expect(api.getIngressModules).toHaveBeenCalledTimes(2)
    expect(screen.queryByTestId('ingress-ports-load-error')).not.toBeInTheDocument()
  })

  it('refreshes the current module state and shows a localized conflict after a stale revision', async () => {
    const user = userEvent.setup()
    vi.mocked(api.getIngressModules)
      .mockResolvedValueOnce(INGRESS)
      .mockResolvedValueOnce({ revision: 'r-current', modules: INGRESS.modules })
    vi.mocked(api.putIngressModule).mockRejectedValue(new ApiError(409, 'mihomo config revision changed'))
    renderSettings()
    await screen.findByText('Speedtest 兼容')

    await user.click(screen.getByRole('switch', { name: '切换 Speedtest 兼容' }))
    await user.click(screen.getByTestId('ingress-ports-save'))
    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: i18n.t('settings.ingressSave') }))

    expect(await screen.findByTestId('ingress-ports-error')).toHaveTextContent('入口配置已被其他编辑修改')
    await waitFor(() => expect(api.getIngressModules).toHaveBeenCalledTimes(2))
    expect(screen.getByRole('switch', { name: '切换 Speedtest 兼容' })).toBeChecked()
  })

  it('refreshes module state after a hot-apply failure and rollback', async () => {
    const user = userEvent.setup()
    vi.mocked(api.getIngressModules)
      .mockResolvedValueOnce(INGRESS)
      .mockResolvedValueOnce({ revision: 'r-rolled-back', modules: INGRESS.modules })
    vi.mocked(api.putIngressModule).mockRejectedValue(new ApiError(502, 'candidate apply failed; previous config restored'))
    renderSettings()
    await screen.findByText('Speedtest 兼容')

    await user.click(screen.getByRole('switch', { name: '切换 Speedtest 兼容' }))
    await user.click(screen.getByTestId('ingress-ports-save'))
    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: i18n.t('settings.ingressSave') }))

    expect(await screen.findByTestId('ingress-ports-error')).toHaveTextContent('previous config restored')
    await waitFor(() => expect(api.getIngressModules).toHaveBeenCalledTimes(2))
    expect(screen.getByRole('switch', { name: '切换 Speedtest 兼容' })).toBeChecked()
  })

  it('aborts the in-flight Telegram health poll on unmount', async () => {
    vi.mocked(api.getTgbot).mockImplementation(() => new Promise<TGBotView>(() => {}))
    const view = renderSettings()
    await waitFor(() => expect(api.getTgbot).toHaveBeenCalled())
    const signal = vi.mocked(api.getTgbot).mock.calls[0]?.[0]
    expect(signal).toBeInstanceOf(AbortSignal)
    expect(signal?.aborted).toBe(false)
    view.unmount()
    expect(signal?.aborted).toBe(true)
  })

  it('cert status renders 有效 + days_remaining from status.cert', async () => {
    renderSettings()
    expect(await screen.findByText('有效')).toBeInTheDocument()
    expect(screen.getByText((text) => text.includes('82'))).toBeInTheDocument()
  })

  it('cert status renders 已过期 in red when status.cert.expired is true', async () => {
    renderSettings(
      statusValue({
        status: {
          version: 'dev',
          uptime_seconds: 1,
          stats: {} as Status['stats'],
          cert: { not_after: '2020-01-01T00:00:00Z', days_remaining: 0, expired: true },
        },
      }),
    )
    expect(await screen.findByText('已过期')).toBeInTheDocument()
  })

  it('cert status renders the broken error message in a red badge', async () => {
    renderSettings(
      statusValue({
        status: {
          version: 'dev',
          uptime_seconds: 1,
          stats: {} as Status['stats'],
          cert: { not_after: '', days_remaining: 0, expired: false, broken: true, error: 'cert load failed' },
        },
      }),
    )
    expect(await screen.findByText('cert load failed')).toBeInTheDocument()
  })

  it('the DoT-domain identity is read-only and the console documents bearer authentication', async () => {
    renderSettings()

    const domainInput = await screen.findByLabelText(i18n.t('settings.dotDomain'))
    expect(domainInput).toBeDisabled()
    expect(domainInput).toHaveValue('dot.example.com')
    expect(screen.getByText(i18n.t('settings.consoleAuth'))).toBeInTheDocument()
    expect(screen.getByText('Bearer')).toBeInTheDocument()
  })

  it('adds and removes validated list entries before saving the ordered groups', async () => {
    const user = userEvent.setup()
    renderSettings()

    await screen.findByText('223.5.5.5')
    await user.click(screen.getByTestId('upstreams-add-china'))
    await user.type(screen.getByTestId('upstreams-address'), '1.1.1.1:5353')
    await user.click(screen.getByTestId('upstreams-add-china-confirm'))
    expect(await screen.findByText('1.1.1.1:5353')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: '删除 119.29.29.29' }))

    await user.click(screen.getByTestId('upstreams-add-trust'))
    expect(screen.getByTestId('upstreams-protocol-dot')).toHaveAttribute('aria-checked', 'true')
    await user.type(screen.getByTestId('upstreams-server-name'), 'dns.cloudflare.com')
    await user.type(screen.getByTestId('upstreams-address'), '1.1.1.1')
    await user.click(screen.getByTestId('upstreams-add-trust-confirm'))
    await user.click(screen.getByRole('button', { name: '删除 dns.google@8.8.8.8' }))

    expect(api.putUpstreams).not.toHaveBeenCalled()
    await user.click(screen.getByTestId('upstreams-save'))

    await waitFor(() =>
      expect(api.putUpstreams).toHaveBeenCalledWith({
        china: ['223.5.5.5', '1.1.1.1:5353'],
        trust: ['dns.cloudflare.com@1.1.1.1'],
      }),
    )
  })

  it('rejects invalid protocol fields and duplicate entries in the add dialog', async () => {
    const user = userEvent.setup()
    renderSettings()

    await screen.findByText('223.5.5.5')
    await user.click(screen.getByTestId('upstreams-add-trust'))
    await user.type(screen.getByTestId('upstreams-address'), 'dns.google')
    await user.click(screen.getByTestId('upstreams-add-trust-confirm'))
    expect(screen.getByText('请输入 TLS 服务器名称。')).toBeInTheDocument()
    expect(screen.getByText('请输入合法 IP；端口可选，范围为 1–65535。')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: '取消' }))
    await user.click(screen.getByTestId('upstreams-add-china'))
    await user.type(screen.getByTestId('upstreams-address'), '223.5.5.5')
    await user.click(screen.getByTestId('upstreams-add-china-confirm'))
    expect(screen.getByRole('alert')).toHaveTextContent('该上游已在列表中。')
  })

  it('prevents saving when either upstream group is empty', async () => {
    const user = userEvent.setup()
    renderSettings()

    await screen.findByText('223.5.5.5')
    await user.click(screen.getByRole('button', { name: '删除 223.5.5.5' }))
    await user.click(screen.getByRole('button', { name: '删除 119.29.29.29' }))

    expect(screen.getByText('至少添加一个上游 DNS 后才能保存。')).toBeInTheDocument()
    expect(screen.getByTestId('upstreams-save')).toBeDisabled()
  })

  it('shows the ApiError message via toast when saving upstreams fails (400)', async () => {
    vi.mocked(api.putUpstreams).mockRejectedValue(new Error('invalid upstream: bad-host'))
    const user = userEvent.setup()
    renderSettings()

    await screen.findByText('223.5.5.5')
    await user.click(screen.getByTestId('upstreams-save'))

    expect(await screen.findByText('invalid upstream: bad-host')).toBeInTheDocument()
  })

  it('saving ecs calls putEcs with the trimmed subnet', async () => {
    const user = userEvent.setup()
    renderSettings()

    const subnetInput = await screen.findByDisplayValue('122.96.30.0/24')
    await user.clear(subnetInput)
    await user.type(subnetInput, '  1.2.3.0/24  ')

    await user.click(screen.getByTestId('ecs-save'))

    await waitFor(() => expect(api.putEcs).toHaveBeenCalledWith('1.2.3.0/24'))
  })

  it('saving tgbot admins without editing the token field omits token from the PUT body', async () => {
    const user = userEvent.setup()
    renderSettings()

    await screen.findByDisplayValue('123456789')
    await user.click(screen.getByTestId('tgbot-save'))

    await waitFor(() => expect(api.putTgbot).toHaveBeenCalledWith({ admins: [123456789] }))
  })

  it('shows the effective Telegram health state and last error', async () => {
    vi.mocked(api.getTgbot).mockResolvedValue({
      admins: [123456789],
      token_set: true,
      state: 'degraded',
      last_error: 'getUpdates conflict',
    })
    renderSettings()
    expect(await screen.findByText(i18n.t('settings.tgbotState_degraded'))).toBeInTheDocument()
    expect(screen.getByText('getUpdates conflict').closest('[role="alert"]')).toHaveTextContent('getUpdates conflict')
    expect(screen.getByRole('switch', { name: i18n.t('settings.tgbotStatus') })).toBeChecked()
  })

  it('does not wipe an in-progress admin edit when only Telegram health changes', async () => {
    const user = userEvent.setup()
    const { rerender } = render(<TgbotCard tgbot={TGBOT} onSaved={() => {}} />)
    const input = await screen.findByDisplayValue('123456789')
    await user.type(input, ',222')
    rerender(
      <TgbotCard
        tgbot={{ ...TGBOT, state: 'degraded', last_error: 'temporary outage' }}
        onSaved={() => {}}
      />,
    )
    expect(input).toHaveValue('123456789,222')
  })

  it('saving tgbot after editing the token field includes token in the PUT body', async () => {
    const user = userEvent.setup()
    renderSettings()

    await screen.findByDisplayValue('123456789')
    await user.type(screen.getByPlaceholderText(i18n.t('settings.tgbotTokenKeep')), 'new-token-value')
    await user.click(screen.getByTestId('tgbot-save'))

    await waitFor(() =>
      expect(api.putTgbot).toHaveBeenCalledWith({ admins: [123456789], token: 'new-token-value' }),
    )
  })

  it('turning the tgbot toggle off disables the bot by sending an empty token', async () => {
    const user = userEvent.setup()
    renderSettings()

    await screen.findByDisplayValue('123456789')
    await user.click(screen.getByRole('switch', { name: i18n.t('settings.tgbotStatus') }))

    await waitFor(() => expect(api.putTgbot).toHaveBeenCalledWith({ admins: [123456789], token: '' }))
  })

  it('turning the tgbot toggle on without a token set and without typing one shows an error toast instead of calling the API', async () => {
    vi.mocked(api.getTgbot).mockResolvedValue({ admins: [], token_set: false, state: 'disabled' })
    const user = userEvent.setup()
    renderSettings()

    await waitFor(() => expect(screen.getByRole('switch', { name: i18n.t('settings.tgbotStatus') })).not.toBeDisabled())
    await user.click(screen.getByRole('switch', { name: i18n.t('settings.tgbotStatus') }))

    expect(await screen.findByText(i18n.t('settings.tgbotNeedToken'))).toBeInTheDocument()
    expect(api.putTgbot).not.toHaveBeenCalled()
  })
})
