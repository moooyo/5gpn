import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import i18n from '../../i18n'
import { Toaster } from '../../components/ds'
import { api } from '../../lib/api/client'
import * as http from '../../lib/api/http'
import type { Status } from '../../lib/api/types'
import { LoginPage } from './LoginPage'

// Mock only the one live call LoginPage drives (getStatus, used as the
// post-setToken probe) — everything else about the auth flow (setToken,
// clearToken, AuthError) is real, so the mock below spies on setToken/
// clearToken while keeping the real AuthError/ApiError classes (LoginPage's
// `err instanceof AuthError` check needs the SAME class identity).
vi.mock('../../lib/api/client', () => ({
  api: { getStatus: vi.fn() },
}))

vi.mock('../../lib/api/http', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../lib/api/http')>()
  return { ...actual, setToken: vi.fn(), clearToken: vi.fn() }
})

function renderLogin() {
  return render(
    <>
      <LoginPage />
      <Toaster />
    </>,
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.getStatus).mockReset()
  vi.mocked(http.setToken).mockClear()
  vi.mocked(http.clearToken).mockClear()
})

afterEach(async () => {
  await i18n.changeLanguage('zh')
  vi.restoreAllMocks()
})

/** Drives the real form (types into the token input, clicks 登录) rather than
 *  pre-seeding a token — the point of this test is the submit HANDLER, not
 *  just that setToken/clearToken work in isolation. */
describe('LoginPage submit flow', () => {
  it('stores the typed token via setToken and shows no error toast when the getStatus probe succeeds', async () => {
    vi.mocked(api.getStatus).mockResolvedValue({ version: 'dev', uptime_seconds: 1, stats: {} as Status['stats'] })
    const user = userEvent.setup()
    renderLogin()

    const submitButton = screen.getByRole('button', { name: i18n.t('auth.submit') })
    await user.type(screen.getByPlaceholderText(i18n.t('auth.tokenPlaceholder')), 'good-token')
    await user.click(submitButton)

    // Wait for the whole submit handler (through its `finally`) to settle —
    // not just the mock call — so no state update escapes this test's act()
    // scope.
    await waitFor(() => expect(submitButton).not.toBeDisabled())

    expect(api.getStatus).toHaveBeenCalledTimes(1)
    expect(http.setToken).toHaveBeenCalledWith('good-token')
    expect(http.clearToken).not.toHaveBeenCalled()
    expect(screen.queryByText(i18n.t('errors.tokenRejected'))).not.toBeInTheDocument()
  })

  it('rolls back via clearToken and shows an error toast when the probe rejects with AuthError', async () => {
    vi.mocked(api.getStatus).mockRejectedValue(new http.AuthError(i18n.t('errors.tokenRejected')))
    const user = userEvent.setup()
    renderLogin()

    const submitButton = screen.getByRole('button', { name: i18n.t('auth.submit') })
    await user.type(screen.getByPlaceholderText(i18n.t('auth.tokenPlaceholder')), 'bad-token')
    await user.click(submitButton)

    expect(await screen.findByText(i18n.t('errors.tokenRejected'))).toBeInTheDocument()
    await waitFor(() => expect(submitButton).not.toBeDisabled())

    expect(http.setToken).toHaveBeenCalledWith('bad-token')
    expect(http.clearToken).toHaveBeenCalledTimes(1)
  })
})
