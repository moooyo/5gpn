import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { Toaster } from '../../components/ds'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'
import { api } from '../../lib/api/client'
import type { ECSView, Status, TGBotView, UpstreamsView } from '../../lib/api/types'
import SettingsPage from './SettingsPage'

vi.mock('../../lib/api/client', () => ({
  api: {
    getUpstreams: vi.fn(),
    putUpstreams: vi.fn(),
    getEcs: vi.fn(),
    putEcs: vi.fn(),
    getTgbot: vi.fn(),
    putTgbot: vi.fn(),
  },
}))

const UPSTREAMS: UpstreamsView = { china: ['223.5.5.5', '119.29.29.29'], trust: ['dns.google@8.8.8.8'] }
const ECS: ECSView = { subnet: '122.96.30.0/24' }
const TGBOT: TGBotView = { admins: [123456789], token_set: true, running: true }

function statusValue(overrides: Partial<StatusValue> = {}): StatusValue {
  return {
    dnsOk: true,
    mihomoOk: true,
    loading: false,
    status: {
      version: 'dev+abc1234',
      uptime_seconds: 3600,
      stats: {} as Status['stats'],
      cert: { not_after: '2026-10-01T00:00:00Z', days_remaining: 82, expired: false },
    },
    ...overrides,
  }
}

function renderSettings(status: StatusValue = statusValue()) {
  return render(
    <StatusContext.Provider value={status}>
      <SettingsPage />
      <Toaster />
    </StatusContext.Provider>,
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

    // getByDisplayValue's default normalizer collapses \n to a space, so
    // matching a textarea's literal multi-line value needs an identity normalizer.
    expect(
      await screen.findByDisplayValue('223.5.5.5\n119.29.29.29', { normalizer: (s) => s }),
    ).toBeInTheDocument()
    expect(screen.getByDisplayValue('dns.google@8.8.8.8')).toBeInTheDocument()
    expect(screen.getByDisplayValue('122.96.30.0/24')).toBeInTheDocument()
    expect(screen.getByDisplayValue('123456789')).toBeInTheDocument()
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

  it('the DoT-domain input and 修改密码 button are disabled and carry the greenfield tooltip', async () => {
    renderSettings()
    const tip = i18n.t('settings.greenfieldTip')

    const domainInput = await screen.findByLabelText(i18n.t('settings.dotDomain'))
    expect(domainInput).toBeDisabled()
    expect(domainInput).toHaveAttribute('title', tip)

    const changePwBtn = screen.getByRole('button', { name: i18n.t('settings.changePassword') })
    expect(changePwBtn).toBeDisabled()
    expect(changePwBtn).toHaveAttribute('title', tip)
  })

  it('saving upstreams splits/trims/drops-empty lines and calls putUpstreams with parsed arrays', async () => {
    const user = userEvent.setup()
    renderSettings()

    const chinaBox = await screen.findByDisplayValue('223.5.5.5\n119.29.29.29', { normalizer: (s) => s })
    await user.clear(chinaBox)
    await user.type(chinaBox, '223.5.5.5{enter}  119.29.29.29  {enter}{enter}1.1.1.1')

    await user.click(screen.getByTestId('upstreams-save'))

    await waitFor(() =>
      expect(api.putUpstreams).toHaveBeenCalledWith({
        china: ['223.5.5.5', '119.29.29.29', '1.1.1.1'],
        trust: ['dns.google@8.8.8.8'],
      }),
    )
  })

  it('shows the ApiError message via toast when saving upstreams fails (400)', async () => {
    vi.mocked(api.putUpstreams).mockRejectedValue(new Error('invalid upstream: bad-host'))
    const user = userEvent.setup()
    renderSettings()

    await screen.findByDisplayValue('223.5.5.5\n119.29.29.29', { normalizer: (s) => s })
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
    await user.click(screen.getByRole('switch'))

    await waitFor(() => expect(api.putTgbot).toHaveBeenCalledWith({ admins: [123456789], token: '' }))
  })

  it('turning the tgbot toggle on without a token set and without typing one shows an error toast instead of calling the API', async () => {
    vi.mocked(api.getTgbot).mockResolvedValue({ admins: [], token_set: false, running: false })
    const user = userEvent.setup()
    renderSettings()

    await waitFor(() => expect(screen.getByRole('switch')).not.toBeDisabled())
    await user.click(screen.getByRole('switch'))

    expect(await screen.findByText(i18n.t('settings.tgbotNeedToken'))).toBeInTheDocument()
    expect(api.putTgbot).not.toHaveBeenCalled()
  })
})
