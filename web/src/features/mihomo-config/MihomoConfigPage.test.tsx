import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import MihomoConfigPage from './MihomoConfigPage'
// Side-effect import: initializes the real i18next singleton (mirrors
// FallbackControl.test.tsx / policy.test.tsx). Without it useTranslation()'s
// `t` has no stable identity, so the load useCallback's `[t]` dep re-creates
// every render and the mount effect re-fires, clobbering the loaded text.
import i18n from '../../i18n'
import { ApiError } from '../../lib/api/http'

const CURRENT_TEXT = 'mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\n'
const DEFAULT_TEXT = 'mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\n# restored default\n'
const INVARIANT_ERROR = 'missing required infrastructure: controller'
const CURRENT_REVISION = 'current-revision'

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
    vi.mocked(api.getMihomoConfig).mockReset().mockResolvedValue({
      text: CURRENT_TEXT,
      revision: CURRENT_REVISION,
      applied_at: '2026-07-10T00:00:00Z',
      controller_reachable: true,
      controller_authenticated: true,
    })
    vi.mocked(api.putMihomoConfig).mockReset()
    vi.mocked(api.resetMihomoConfig).mockReset().mockResolvedValue({
      text: DEFAULT_TEXT,
      revision: 'default-revision',
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
    expect(screen.getByText('Gateway ingress')).toBeInTheDocument()
    expect(screen.getByText('Controller secret')).toBeInTheDocument()
    expect(screen.getByText('Console SNI split')).toBeInTheDocument()
    expect(screen.getByText('Validation rejects the complete document when any item is missing.')).toBeInTheDocument()
    expect(screen.getByText('rev curr…sion')).toBeInTheDocument()
    expect(screen.queryByText('Saved snapshot')).not.toBeInTheDocument()
    expect(screen.queryByText('mihomo config (YAML)')).not.toBeInTheDocument()
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
      revision: CURRENT_REVISION,
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
    expect(api.putMihomoConfig).toHaveBeenCalledWith(CURRENT_TEXT, CURRENT_REVISION)
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

    await waitFor(() => expect(api.resetMihomoConfig).toHaveBeenCalledWith(CURRENT_REVISION))
    await waitFor(() => expect(textarea.value).toBe(DEFAULT_TEXT))
    expect(screen.queryByTestId('mihomo-config-error')).not.toBeInTheDocument()
  })

  it('keeps a local edit on conflict and offers an explicit confirmed reload', async () => {
    const user = userEvent.setup()
    const latest = {
      text: `${CURRENT_TEXT}# changed elsewhere\n`,
      revision: 'latest-revision',
      controller_reachable: true,
      controller_authenticated: true,
    }
    vi.mocked(api.getMihomoConfig)
      .mockResolvedValueOnce({
        text: CURRENT_TEXT,
        revision: CURRENT_REVISION,
        controller_reachable: true,
        controller_authenticated: true,
      })
      .mockResolvedValueOnce(latest)
    vi.mocked(api.putMihomoConfig).mockRejectedValue(new ApiError(409, 'mihomo config revision changed'))
    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    await user.type(textarea, '# local edit')
    await user.click(screen.getByTestId('mihomo-config-apply'))

    expect(await screen.findByTestId('mihomo-config-error')).toHaveTextContent('changed elsewhere')
    expect(textarea.value).toBe(`${CURRENT_TEXT}# local edit`)
    expect(api.putMihomoConfig).toHaveBeenCalledWith(`${CURRENT_TEXT}# local edit`, CURRENT_REVISION)
    expect(screen.getByTestId('mihomo-config-apply')).toBeDisabled()

    await user.click(screen.getByRole('button', { name: 'Load current config' }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/discards the text in this editor/i)).toBeInTheDocument()
    await user.click(within(dialog).getByRole('button', { name: 'Load current config' }))

    await waitFor(() => expect(textarea.value).toBe(latest.text))
    expect(api.getMihomoConfig).toHaveBeenCalledTimes(2)
    expect(screen.queryByTestId('mihomo-config-error')).not.toBeInTheDocument()
    expect(screen.getByTestId('mihomo-config-apply')).toBeEnabled()
  })

  it('refreshes the persisted revision after a raw apply is written but hot-apply returns 502', async () => {
    const user = userEvent.setup()
    const written = {
      text: CURRENT_TEXT,
      revision: 'written-revision',
      controller_reachable: false,
      controller_authenticated: false,
    }
    const applied = { ...written, revision: 'applied-revision', controller_reachable: true, controller_authenticated: true }
    vi.mocked(api.getMihomoConfig)
      .mockResolvedValueOnce({
        text: CURRENT_TEXT,
        revision: CURRENT_REVISION,
        controller_reachable: true,
        controller_authenticated: true,
      })
      .mockResolvedValueOnce(written)
    vi.mocked(api.putMihomoConfig)
      .mockRejectedValueOnce(new ApiError(502, 'config written but hot-apply failed'))
      .mockResolvedValueOnce(applied)
    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    await user.click(screen.getByTestId('mihomo-config-apply'))
    expect(await screen.findByTestId('mihomo-config-error')).toHaveTextContent('hot-apply failed')
    await waitFor(() => expect(api.getMihomoConfig).toHaveBeenCalledTimes(2))
    expect(screen.getByTestId('mihomo-config-editor')).toHaveAttribute('data-dirty', 'false')

    await user.click(screen.getByTestId('mihomo-config-apply'))
    await waitFor(() => expect(api.putMihomoConfig).toHaveBeenLastCalledWith(CURRENT_TEXT, written.revision))
  })

  it('does not adopt a third-party revision discovered after a raw apply 502', async () => {
    const user = userEvent.setup()
    vi.mocked(api.getMihomoConfig)
      .mockResolvedValueOnce({
        text: CURRENT_TEXT,
        revision: CURRENT_REVISION,
        controller_reachable: true,
        controller_authenticated: true,
      })
      .mockResolvedValueOnce({
        text: `${CURRENT_TEXT}# third-party edit\n`,
        revision: 'third-party-revision',
        controller_reachable: true,
        controller_authenticated: true,
      })
    vi.mocked(api.putMihomoConfig).mockRejectedValueOnce(new ApiError(502, 'config written but hot-apply failed'))
    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    await user.type(textarea, '# local edit')
    await user.click(screen.getByTestId('mihomo-config-apply'))

    expect(await screen.findByTestId('mihomo-config-error')).toHaveTextContent('hot-apply failed')
    expect(textarea.value).toBe(`${CURRENT_TEXT}# local edit`)
    expect(screen.getByTestId('mihomo-config-apply')).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Load current config' })).toBeInTheDocument()
  })

  it('reloads the on-disk seed after reset writes it but hot-apply returns 502', async () => {
    const user = userEvent.setup()
    const writtenDefault = {
      text: DEFAULT_TEXT,
      revision: 'written-default-revision',
      controller_reachable: false,
      controller_authenticated: false,
    }
    vi.mocked(api.getMihomoConfig)
      .mockResolvedValueOnce({
        text: CURRENT_TEXT,
        revision: CURRENT_REVISION,
        controller_reachable: true,
        controller_authenticated: true,
      })
      .mockResolvedValueOnce(writtenDefault)
    vi.mocked(api.resetMihomoConfig).mockRejectedValueOnce(new ApiError(502, 'config written but hot-apply failed'))
    render(<MihomoConfigPage />)
    const textarea = (await screen.findByTestId('mihomo-config-textarea')) as HTMLTextAreaElement
    await waitFor(() => expect(textarea.value).toBe(CURRENT_TEXT))

    await user.click(screen.getByTestId('mihomo-config-reset'))
    let dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: /restore default/i }))

    expect(await screen.findByTestId('mihomo-config-error')).toHaveTextContent('hot-apply failed')
    await waitFor(() => expect(textarea.value).toBe(DEFAULT_TEXT))
    expect(screen.getByTestId('mihomo-config-editor')).toHaveAttribute('data-dirty', 'false')

    await user.click(screen.getByTestId('mihomo-config-reset'))
    dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: /restore default/i }))
    await waitFor(() => expect(api.resetMihomoConfig).toHaveBeenLastCalledWith(writtenDefault.revision))
  })
})
