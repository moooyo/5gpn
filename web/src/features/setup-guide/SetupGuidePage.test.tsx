import { render, screen } from '@testing-library/react'
import { beforeEach, describe, expect, it } from 'vitest'
import { StatusContext } from '../../lib/StatusContext'
import i18n from '../../i18n'
import SetupGuidePage, { IOS_PROFILE_PATH, profileURL } from './SetupGuidePage'

beforeEach(async () => {
  await i18n.changeLanguage('zh')
})

describe('SetupGuidePage', () => {
  it('shows the real DoT hostname, iOS download link, and locally rendered QR code', () => {
    render(
      <StatusContext.Provider
        value={{
          dnsState: 'healthy',
          mihomoState: 'healthy',
          dnsOk: true,
          mihomoOk: true,
          loading: false,
          status: {
            version: 'test',
            uptime_seconds: 1,
            stats: {} as never,
            dot_domain: 'dot.5gpn.example.com',
          },
        }}
      >
        <SetupGuidePage />
      </StatusContext.Provider>,
    )

    expect(screen.getByTestId('page-setup-guide')).toBeInTheDocument()
    expect(screen.getByTestId('dot-domain')).toHaveTextContent('dot.5gpn.example.com')

    const links = screen.getAllByRole('link', { name: /iOS 描述文件|打开 iOS/ })
    expect(links.length).toBeGreaterThanOrEqual(2)
    for (const link of links) expect(link).toHaveAttribute('href', profileURL())

    expect(screen.getByRole('img', { name: 'iOS 描述文件下载二维码' }).querySelector('path')).toHaveAttribute('d')
  })

  it('builds an absolute same-origin profile URL', () => {
    expect(profileURL('https://console.5gpn.example.com')).toBe(
      `https://console.5gpn.example.com${IOS_PROFILE_PATH}`,
    )
  })
})
