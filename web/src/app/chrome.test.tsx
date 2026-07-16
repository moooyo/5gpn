import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { Sidebar } from './Sidebar'
import { Topbar, pageMeta } from './Topbar'
import { ProfileMenu } from './ProfileMenu'
import { ALL_NAV_ITEMS } from './navigation'
import { StatusContext, StatusProvider, useStatus, type StatusValue } from '../lib/StatusContext'
import { ThemeProvider } from '../lib/theme'
import i18n from '../i18n'
import { api } from '../lib/api/client'
import type { Status, MihomoHealth } from '../lib/api/types'

vi.mock('../lib/api/client', () => ({
  api: { getStatus: vi.fn(), getMihomoHealth: vi.fn() },
}))

// Count of <style> elements anywhere in the document — the CSP proxy
// assertion also used by overlays.test.tsx: ProfileMenu is built on
// ds/DropdownMenu, which is proven to inject zero <style> elements.
const styleCount = () => document.querySelectorAll('style').length

const OK_STATUS: Status = { version: 'dev', uptime_seconds: 42, stats: {} as Status['stats'] }
const OK_MIHOMO: MihomoHealth = { version: 'v1.19.0' }

function renderChrome(ui: React.ReactNode, { route = '/logs', status }: { route?: string; status: StatusValue }) {
  return render(
    <MemoryRouter initialEntries={[route]}>
      <ThemeProvider>
        <StatusContext.Provider value={status}>{ui}</StatusContext.Provider>
      </ThemeProvider>
    </MemoryRouter>,
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
})

describe('Sidebar', () => {
  it('renders all 8 nav item labels in zh, and the item matching the current route gets the active pill', async () => {
    renderChrome(<Sidebar />, { route: '/logs', status: { dnsOk: true, mihomoOk: true, loading: false } })

    for (const item of ALL_NAV_ITEMS) {
      expect(screen.getByText(i18n.t(item.labelKey))).toBeInTheDocument()
    }

    const activeLink = screen.getByText(i18n.t('nav.logs')).closest('a')
    expect(activeLink).not.toBeNull()
    expect(activeLink!.className).toContain('text-primary')

    const inactiveLink = screen.getByText(i18n.t('nav.overview')).closest('a')
    expect(inactiveLink).not.toBeNull()
    expect(inactiveLink!.className).not.toContain('text-primary')
  })

  it('kernel status card: dnsOk=true shows DNS row running (green), mihomoOk=false shows mihomo row stopped (red)', () => {
    renderChrome(<Sidebar />, { route: '/overview', status: { dnsOk: true, mihomoOk: false, loading: false } })

    expect(screen.getByText('DNS 服务器')).toBeInTheDocument()
    expect(screen.getByText('mihomo')).toBeInTheDocument()

    const runningEl = screen.getByText(i18n.t('common.running'))
    expect(runningEl.className).toContain('text-green')

    const stoppedEl = screen.getByText(i18n.t('settings.tgbotStateStopped'))
    expect(stoppedEl.className).toContain('text-red')
  })
})

describe('Topbar', () => {
  it('pageMeta maps a route to its nav item id, falling back to overview', () => {
    expect(pageMeta('/logs')).toBe('logs')
    expect(pageMeta('/setup-guide')).toBe('setup-guide')
    expect(pageMeta('/resolve-test')).toBe('resolve-test')
    expect(pageMeta('/does-not-exist')).toBe('overview')
    expect(pageMeta('/')).toBe('overview')
  })

  it('shows the title and subtitle for the current route (/logs)', () => {
    renderChrome(<Topbar />, { route: '/logs', status: { dnsOk: true, mihomoOk: true, loading: false } })

    expect(screen.getByText('解析日志')).toBeInTheDocument()
    expect(screen.getByText(i18n.t('topbar.sub.logs'))).toBeInTheDocument()
  })
})

describe('ProfileMenu', () => {
  it('opens, shows the language + theme segmented controls and logout, changing language calls i18n.changeLanguage, and injects no <style>', async () => {
    const user = userEvent.setup()
    const before = styleCount()
    const changeLanguageSpy = vi.spyOn(i18n, 'changeLanguage')

    render(
      <ThemeProvider>
        <ProfileMenu />
      </ThemeProvider>,
    )

    await user.click(screen.getByText(i18n.t('topbar.admin')))

    expect(await screen.findByText(i18n.t('topbar.superAdmin'))).toBeInTheDocument()
    expect(screen.getByText('中文')).toBeInTheDocument()
    expect(screen.getByText('English')).toBeInTheDocument()
    expect(screen.getByText(i18n.t('topbar.light'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('topbar.dark'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('topbar.system'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('topbar.logout'))).toBeInTheDocument()

    expect(styleCount()).toBe(before)

    await user.click(screen.getByText('English'))
    expect(changeLanguageSpy).toHaveBeenCalledWith('en')
  })
})

describe('StatusProvider / useStatus', () => {
  beforeEach(() => {
    vi.mocked(api.getStatus).mockReset()
    vi.mocked(api.getMihomoHealth).mockReset()
  })

  function Probe() {
    const { status, mihomo, dnsOk, mihomoOk, loading } = useStatus()
    return (
      <div data-testid="probe">
        {JSON.stringify({ dnsOk, mihomoOk, loading, hasStatus: status !== undefined, hasMihomo: mihomo !== undefined })}
      </div>
    )
  }

  it('polls getStatus + getMihomoHealth on mount and derives dnsOk/mihomoOk (mihomo liveness from getMihomoHealth, NOT status.version)', async () => {
    vi.mocked(api.getStatus).mockResolvedValue(OK_STATUS)
    vi.mocked(api.getMihomoHealth).mockResolvedValue(OK_MIHOMO)

    render(
      <StatusProvider intervalMs={100_000}>
        <Probe />
      </StatusProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('probe').textContent).toBe(
        JSON.stringify({ dnsOk: true, mihomoOk: true, loading: false, hasStatus: true, hasMihomo: true }),
      )
    })
  })

  it('swallows poll errors into dnsOk=false/mihomoOk=false without throwing', async () => {
    vi.mocked(api.getStatus).mockRejectedValue(new Error('network'))
    vi.mocked(api.getMihomoHealth).mockRejectedValue(new Error('network'))

    render(
      <StatusProvider intervalMs={100_000}>
        <Probe />
      </StatusProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId('probe').textContent).toBe(
        JSON.stringify({ dnsOk: false, mihomoOk: false, loading: false, hasStatus: false, hasMihomo: false }),
      )
    })
  })

  it('clears the completion-scheduled poll on unmount', async () => {
    vi.mocked(api.getStatus).mockResolvedValue(OK_STATUS)
    vi.mocked(api.getMihomoHealth).mockResolvedValue(OK_MIHOMO)

    const { unmount } = render(
      <StatusProvider intervalMs={15}>
        <Probe />
      </StatusProvider>,
    )

    await waitFor(() => expect(vi.mocked(api.getStatus).mock.calls.length).toBeGreaterThanOrEqual(2))
    unmount()
    const callsAtUnmount = vi.mocked(api.getStatus).mock.calls.length
    await new Promise((resolve) => setTimeout(resolve, 60))
    expect(vi.mocked(api.getStatus).mock.calls.length).toBe(callsAtUnmount)
  })

  it('never starts a second poll while the first one is still pending', async () => {
    vi.useFakeTimers()
    let resolveStatus!: (value: Status) => void
    let resolveMihomo!: (value: MihomoHealth) => void
    vi.mocked(api.getStatus).mockImplementation(
      () => new Promise<Status>((resolve) => { resolveStatus = resolve }),
    )
    vi.mocked(api.getMihomoHealth).mockImplementation(
      () => new Promise<MihomoHealth>((resolve) => { resolveMihomo = resolve }),
    )

    const { unmount } = render(
      <StatusProvider intervalMs={50}>
        <Probe />
      </StatusProvider>,
    )
    expect(api.getStatus).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(500)
    expect(api.getStatus).toHaveBeenCalledTimes(1)

    resolveStatus(OK_STATUS)
    resolveMihomo(OK_MIHOMO)
    await Promise.resolve()
    await vi.advanceTimersByTimeAsync(49)
    expect(api.getStatus).toHaveBeenCalledTimes(1)
    await vi.advanceTimersByTimeAsync(1)
    expect(api.getStatus).toHaveBeenCalledTimes(2)
    unmount()
    vi.useRealTimers()
  })
})
