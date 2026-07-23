import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import { StatusContext } from '../../lib/StatusContext'
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

beforeEach(async () => {
  localStorage.clear()
  await i18n.changeLanguage('zh')
  vi.mocked(api.getMITMSettings).mockReset().mockResolvedValue({
    revision: '1'.repeat(64), enabled: false, http2: true, quic_fallback_protection: true,
  })
})

describe('SetupGuidePage', () => {
  it('shows the real DoT hostname, iOS download link, and locally rendered QR code', () => {
    render(
      <MemoryRouter><StatusContext.Provider
        value={{
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
        }}
      >
        <SetupGuidePage />
      </StatusContext.Provider></MemoryRouter>,
    )

    expect(screen.getByTestId('page-setup-guide')).toBeInTheDocument()
    expect(screen.getByTestId('dot-domain')).toHaveTextContent('dot.5gpn.example.com')

    const links = screen.getAllByRole('link', { name: /iOS 描述文件|打开 iOS/ })
    expect(links.length).toBeGreaterThanOrEqual(2)
    for (const link of links) expect(link).toHaveAttribute('href', profileURL())

    expect(screen.getByRole('img', { name: 'iOS 描述文件下载二维码' }).querySelector('path')).toHaveAttribute('d')

    expect(screen.getByTestId('intercept-ca-guide')).toBeInTheDocument()
    const caLinks = screen.getAllByRole('link', { name: /共享根证书|共享 CA/ })
    expect(caLinks.length).toBeGreaterThanOrEqual(2)
    for (const link of caLinks) expect(link).toHaveAttribute('href', interceptCAProfileURL())
    expect(screen.getByRole('img', { name: 'MITM 共享根证书描述文件下载二维码' }).querySelector('path')).toHaveAttribute('d')
    expect(screen.getByText(/必须在设置中开启网关 MITM 总开关/)).toBeInTheDocument()
    expect(screen.getByText('现代 Android 应用不支持 MITM 配置')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: '前往 MITM 设置' })).toHaveAttribute('href', '/settings')
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
    vi.mocked(api.getMITMSettings).mockResolvedValue({
      revision: '1'.repeat(64), enabled: true, http2: true, quic_fallback_protection: true,
    })
    render(
      <MemoryRouter><StatusContext.Provider
        value={{
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
        }}
      >
        <SetupGuidePage />
      </StatusContext.Provider></MemoryRouter>,
    )

    const warning = await screen.findByTestId('intercept-ca-trust-warning')
    expect(warning).toHaveAttribute('role', 'alert')
    expect(warning).toHaveTextContent('仅安装 DoT 或 CA 描述文件还不够')
    expect(warning).toHaveTextContent('YouTube 等被接管的应用会因 TLS 证书校验失败而无法加载')
    expect(screen.getByRole('link', { name: '下载 MITM 根证书' })).toHaveAttribute('href', interceptCAProfileURL())
  })
})
