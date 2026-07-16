import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { AppShell } from './AppShell'
import { ThemeProvider } from '../lib/theme'
import i18n from '../i18n'
import { api } from '../lib/api/client'
import type { Status, MihomoHealth } from '../lib/api/types'

// StatusProvider (mounted inside AppShell) polls these on render — mock so
// the test never touches the network.
vi.mock('../lib/api/client', () => ({
  api: { getStatus: vi.fn(), getMihomoHealth: vi.fn() },
}))

const OK_STATUS: Status = { version: 'dev', uptime_seconds: 42, stats: {} as Status['stats'] }
const OK_MIHOMO: MihomoHealth = { version: 'v1.19.0' }

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.getStatus).mockResolvedValue(OK_STATUS)
  vi.mocked(api.getMihomoHealth).mockResolvedValue(OK_MIHOMO)
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
})

// AppShell only renders the Outlet — a real nested route is needed to give
// it something to render, matching how router.tsx actually mounts it.
function renderShellAt(route: string) {
  return render(
    <ThemeProvider>
      <MemoryRouter initialEntries={[route]}>
        <Routes>
          <Route path="/" element={<AppShell />}>
            <Route index element={<div data-testid="outlet-child">overview placeholder</div>} />
            <Route path="logs" element={<div data-testid="outlet-child">logs placeholder</div>} />
          </Route>
        </Routes>
      </MemoryRouter>
    </ThemeProvider>,
  )
}

describe('AppShell', () => {
  it('renders the Sidebar, the Topbar, and the routed Outlet content', () => {
    const { container } = renderShellAt('/')

    expect(container.querySelector('aside')).toBeInTheDocument()
    expect(container.querySelector('header')).toBeInTheDocument()
    expect(screen.getByTestId('outlet-child')).toHaveTextContent('overview placeholder')
  })

  it('navigating to /logs shows the logs title in the topbar', () => {
    const { container } = renderShellAt('/logs')

    const header = container.querySelector('header')
    expect(header).not.toBeNull()
    expect(within(header!).getByText(i18n.t('nav.logs'))).toBeInTheDocument()
    expect(screen.getByTestId('outlet-child')).toHaveTextContent('logs placeholder')
  })

  it('opens the mobile navigation drawer and closes it after navigation', async () => {
    const user = userEvent.setup()
    renderShellAt('/')

    await user.click(screen.getByTestId('mobile-nav-open'))
    expect(await screen.findByTestId('mobile-sidebar-drawer')).toBeInTheDocument()

    await user.click(within(screen.getByTestId('mobile-sidebar-drawer')).getByText(i18n.t('nav.logs')))
    expect(screen.queryByTestId('mobile-sidebar-drawer')).not.toBeInTheDocument()
    expect(screen.getByTestId('outlet-child')).toHaveTextContent('logs placeholder')
  })
})
