import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import { StatusContext, type StatusValue } from '../../lib/StatusContext'
import i18n from '../../i18n'
import SetupGuidePage, {
  INTERCEPT_CA_PROFILE_PATH,
  IOS_PROFILE_PATH,
  interceptCAProfileURL,
  profileURL,
} from './SetupGuidePage'
import { api } from '../../lib/api/client'

vi.mock('../../lib/api/client', () => ({
  api: { getMITMSettings: vi.fn() },
}))

const STATUS: StatusValue = {
  dnsState: 'healthy',
  mihomoState: 'healthy',
  interceptState: 'healthy',
  dnsOk: true,
  mihomoOk: true,
  interceptOk: true,
  loading: false,
  interceptLoading: false,
  status: {
    version: 'test',
    uptime_seconds: 1,
    stats: {} as never,
    dot_domain: 'dot.5gpn.example.com',
  },
}

function renderPage() {
  return render(
    <MemoryRouter>
      <StatusContext.Provider value={STATUS}>
        <SetupGuidePage />
      </StatusContext.Provider>
    </MemoryRouter>,
  )
}

function mitmEnabled(enabled: boolean) {
  vi.mocked(api.getMITMSettings).mockResolvedValue({
    revision: '1'.repeat(64), enabled, http2: true, quic_fallback_protection: true,
  })
}

beforeEach(async () => {
  localStorage.clear()
  await i18n.changeLanguage('zh')
  vi.mocked(api.getMITMSettings).mockReset()
  mitmEnabled(false)
})

describe('SetupGuidePage', () => {
  it('opens on the iOS branch and shows the download link plus a locally rendered QR code', () => {
    renderPage()

    expect(screen.getByTestId('page-setup-guide')).toBeInTheDocument()
    expect(screen.getByTestId('ios-guide')).toBeInTheDocument()
    // Only the chosen branch is expanded — the page used to lay all thirteen
    // numbered steps out at once and never ask which device this was for.
    expect(screen.queryByTestId('android-guide')).not.toBeInTheDocument()

    const links = screen.getAllByRole('link', { name: /iOS 描述文件/ })
    expect(links.length).toBeGreaterThanOrEqual(1)
    for (const link of links) expect(link).toHaveAttribute('href', profileURL())

    expect(screen.getByRole('img', { name: 'iOS 描述文件下载二维码' }).querySelector('path')).toHaveAttribute('d')
  })

  it('switches to the Android branch and remembers the choice for the next visit', async () => {
    const user = userEvent.setup()
    const view = renderPage()

    await user.click(screen.getByRole('tab', { name: i18n.t('setupGuide.deviceAndroid') }))
    expect(screen.getByTestId('android-guide')).toBeInTheDocument()
    expect(screen.getByTestId('dot-domain')).toHaveTextContent('dot.5gpn.example.com')
    expect(screen.queryByTestId('ios-guide')).not.toBeInTheDocument()

    view.unmount()
    renderPage()
    expect(screen.getByTestId('android-guide')).toBeInTheDocument()
  })

  /**
   * The top warning banner already gated on `enabled`; the five-step CA card
   * did not, so with the master switch off the page still walked the operator
   * through installing a root certificate that could not do anything.
   */
  it('collapses the CA card to one row with a way to enable MITM while the master switch is off', async () => {
    renderPage()

    const collapsed = await screen.findByTestId('intercept-ca-collapsed')
    expect(collapsed).toHaveTextContent(i18n.t('setupGuide.interceptCA.collapsedBody'))
    expect(screen.queryByTestId('intercept-ca-guide')).not.toBeInTheDocument()
    expect(screen.getByRole('link', { name: new RegExp(i18n.t('setupGuide.interceptCA.enableMITM')) }))
      .toHaveAttribute('href', '/settings')
  })

  it('expands the CA card once the master switch is on', async () => {
    mitmEnabled(true)
    renderPage()

    expect(await screen.findByTestId('intercept-ca-guide')).toBeInTheDocument()
    // The QR is no longer a link: clicking it on a desktop downloaded a
    // .mobileconfig onto a machine with no use for one. The download button
    // is the only link to the profile now.
    const caLinks = screen.getAllByRole('link', { name: /共享 CA/ })
    expect(caLinks).toHaveLength(1)
    for (const link of caLinks) expect(link).toHaveAttribute('href', interceptCAProfileURL())
    expect(screen.getByRole('img', { name: 'MITM 共享根证书描述文件下载二维码' }).closest('a')).toBeNull()
    expect(screen.getByRole('img', { name: 'MITM 共享根证书描述文件下载二维码' }).querySelector('path')).toHaveAttribute('d')
  })

  /**
   * The left tile reads localStorage and the right one reads the server-side
   * switch. They used to render identically, so opening the console on another
   * machine flipped the left one back with no visual cue as to why.
   */
  it('marks the client-trust tile as a local-only record', async () => {
    mitmEnabled(true)
    renderPage()

    await screen.findByTestId('intercept-ca-guide')
    expect(screen.getByText(i18n.t('setupGuide.interceptCA.localOnlyTag'))).toBeInTheDocument()
  })

  it('builds an absolute same-origin profile URL', () => {
    expect(profileURL('https://console.5gpn.example.com')).toBe(
      `https://console.5gpn.example.com${IOS_PROFILE_PATH}`,
    )
    expect(interceptCAProfileURL('https://console.5gpn.example.com')).toBe(
      `https://console.5gpn.example.com${INTERCEPT_CA_PROFILE_PATH}`,
    )
  })

  it('prominently warns when MITM is enabled but client trust is not acknowledged', async () => {
    mitmEnabled(true)
    renderPage()

    const warning = await screen.findByTestId('intercept-ca-trust-warning')
    expect(warning).toHaveAttribute('role', 'alert')
    expect(warning).toHaveTextContent('仅安装 DoT 或 CA 描述文件还不够')
    expect(warning).toHaveTextContent('YouTube 等被接管的应用会因 TLS 证书校验失败而无法加载')
    expect(screen.getByRole('link', { name: '下载 MITM 根证书' })).toHaveAttribute('href', interceptCAProfileURL())
  })
})
