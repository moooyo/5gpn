import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import MihomoConfigPage from './MihomoConfigPage'
// Side-effect import: initializes the real i18next singleton (mirrors
// FallbackControl.test.tsx / policy.test.tsx). Without it useTranslation()'s
// `t` has no stable identity, so the load useCallback's `[t]` dep re-creates
// every render and the mount effect re-fires, clobbering the loaded text.
import i18n from '../../i18n'

const CURRENT_TEXT = 'mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\n'
const DEFAULT_TEXT = 'mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\n# restored default\n'
const INVARIANT_ERROR = 'missing required infrastructure: controller'

vi.mock('../../lib/api/client', () => ({
  api: {
    getMihomoConfig: vi.fn(),
    putMihomoConfig: vi.fn(),
    resetMihomoConfig: vi.fn(),
  },
}))
import { api } from '../../lib/api/client'

describe('MihomoConfigPage', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    await i18n.changeLanguage('en')
    vi.mocked(api.getMihomoConfig).mockResolvedValue({
      text: CURRENT_TEXT,
      applied_at: '2026-07-10T00:00:00Z',
      controller_reachable: true,
      controller_authenticated: true,
    })
    vi.mocked(api.resetMihomoConfig).mockResolvedValue({
      text: DEFAULT_TEXT,
      applied_at: '2026-07-15T00:00:00Z',
      controller_reachable: true,
      controller_authenticated: true,
    })
  })

  it('loads and shows the current config text', async () => {
    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))
    expect(api.getMihomoConfig).toHaveBeenCalledTimes(1)
    expect(screen.getByText('Console SNI split')).toBeInTheDocument()
  })

  it('keeps an unsaved edit when the UI language changes', async () => {
    const user = userEvent.setup()
    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    await user.type(textarea, '# unsaved')
    expect(screen.getByTestId('mihomo-config-editor')).toHaveAttribute('data-dirty', 'true')

    await i18n.changeLanguage('zh')
    await waitFor(() => expect(textarea.value).toBe(`${CURRENT_TEXT}# unsaved`))
    expect(api.getMihomoConfig).toHaveBeenCalledTimes(1)
  })

  it('shows a distinct warning when the controller is reachable but rejects the secret', async () => {
    vi.mocked(api.getMihomoConfig).mockResolvedValueOnce({
      text: CURRENT_TEXT,
      applied_at: '2026-07-10T00:00:00Z',
      controller_reachable: true,
      controller_authenticated: false,
    })
    render(<MihomoConfigPage />)

    expect(await screen.findByText('Controller reachable, but the secret was rejected')).toBeInTheDocument()
    expect(screen.queryByText('Controller reachable')).not.toBeInTheDocument()
  })

  it('shows a persistent error banner and KEEPS the editor content on a 400 invariant rejection', async () => {
    const user = userEvent.setup()
    vi.mocked(api.putMihomoConfig).mockRejectedValue(new Error(INVARIANT_ERROR))

    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    await user.click(screen.getByTestId('mihomo-config-apply'))

    await waitFor(() => expect(screen.getByTestId('mihomo-config-error')).toHaveTextContent(INVARIANT_ERROR))
    expect(api.putMihomoConfig).toHaveBeenCalledWith(CURRENT_TEXT)
    // The editor content must survive the rejection untouched.
    expect(textarea.value).toBe(CURRENT_TEXT)
    expect(api.resetMihomoConfig).not.toHaveBeenCalled()
  })

  it('restores the default config only after confirming, and clears a prior error banner', async () => {
    const user = userEvent.setup()
    vi.mocked(api.putMihomoConfig).mockRejectedValue(new Error(INVARIANT_ERROR))

    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    // Provoke the error banner first, so the reset path is proven to clear it.
    await user.click(screen.getByTestId('mihomo-config-apply'))
    await screen.findByTestId('mihomo-config-error')

    await user.click(screen.getByTestId('mihomo-config-reset'))
    expect(api.resetMihomoConfig).not.toHaveBeenCalled()

    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: /restore default/i }))

    await waitFor(() => expect(api.resetMihomoConfig).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(textarea.value).toBe(DEFAULT_TEXT))
    expect(screen.queryByTestId('mihomo-config-error')).not.toBeInTheDocument()
  })
})
