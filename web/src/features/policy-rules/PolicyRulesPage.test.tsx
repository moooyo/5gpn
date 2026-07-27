import { render, screen, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
// Side-effect import: initializes the real i18next singleton (mirrors
// egress.test.tsx / FallbackControl.test.tsx / PolicyRulesTable.test.tsx).
// Without it useTranslation()'s `t` has no stable identity, so the `load`
// useCallback ([t] dep) re-creates every render and the mount useEffect
// re-fires on every state change.
import i18n from '../../i18n'
import { Toaster } from '../../components/ds'
import PolicyRulesPage from './PolicyRulesPage'
import type { PolicyRule } from '../../lib/api/types'

const RULES: PolicyRule[] = [
  { id: 'a', order: 0, matcher: { kind: 'domain-suffix', value: 'netflix.com' }, intent: 'proxy', enabled: true },
]

vi.mock('../../lib/api/client', () => ({
  api: {
    getPolicyRules: vi.fn(async () => RULES),
    getPolicyFallback: vi.fn(async () => ({ policy: 'auto' })),
    putPolicyFallback: vi.fn(async () => ({ ok: true })),
    applyPolicy: vi.fn(async () => ({ ok: true })),
    deletePolicyRule: vi.fn(async () => ({ ok: true })),
    updatePolicyRule: vi.fn(async (_id: string, r: unknown) => ({ ...(r as object), id: 'a', order: 0 })),
    reorderPolicyRules: vi.fn(async () => ({ ok: true })),
    createPolicyRule: vi.fn(),
  },
}))
import { api } from '../../lib/api/client'


/** Layout branches at 767px, matching every other page in this console. */
function setMobile(mobile: boolean) {
  vi.stubGlobal('matchMedia', vi.fn().mockImplementation((query: string) => ({
    matches: mobile && query.includes('max-width: 767px'),
    media: query,
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })))
}

function renderPage(initialPath = '/policy-rules') {
  return render(
    <MemoryRouter initialEntries={[initialPath]}>
      <PolicyRulesPage />
      <Toaster />
    </MemoryRouter>,
  )
}

describe('PolicyRulesPage', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    await i18n.changeLanguage('en')
    vi.mocked(api.getPolicyRules).mockResolvedValue([...RULES])
    vi.mocked(api.getPolicyFallback).mockResolvedValue({ policy: 'auto' })
    vi.mocked(api.putPolicyFallback).mockResolvedValue({ ok: true })
    vi.mocked(api.applyPolicy).mockResolvedValue({ ok: true })
    vi.mocked(api.deletePolicyRule).mockResolvedValue({ ok: true })
    vi.mocked(api.reorderPolicyRules).mockResolvedValue({ ok: true })
  })

  it('renders the rules table and fallback control', async () => {
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())
    // FallbackControl self-loads with the same shared selector list.
    expect(await screen.findByText('Fallback policy')).toBeInTheDocument()
  })

  it('drives Apply, toasting success', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getByTestId('policy-apply'))

    await waitFor(() => expect(api.applyPolicy).toHaveBeenCalled())
    expect(await screen.findByText('Applied — resolver policy reloaded.')).toBeInTheDocument()
  })

  /**
   * Saving and applying are two different acts here, and until now the page
   * said nothing about the gap: after editing three rules Apply looked exactly
   * as it did with nothing changed, and its only feedback was a toast.
   */
  it('turns the header card warning and counts pending changes after an edit lands', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    // A snapshot only exists after an apply, so the page starts neutral.
    await user.click(screen.getByTestId('policy-apply'))
    await waitFor(() => expect(screen.getByTestId('policy-header')).toHaveAttribute('data-dirty', 'false'))
    expect(screen.getByTestId('policy-apply')).toBeDisabled()
    expect(screen.getByTestId('policy-apply')).toHaveTextContent('Up to date')

    vi.mocked(api.getPolicyRules).mockResolvedValue([
      { ...RULES[0], matcher: { kind: 'domain-suffix', value: 'netflix.com' }, enabled: false },
    ])
    await user.click(screen.getByRole('switch'))

    await waitFor(() => expect(screen.getByTestId('policy-header')).toHaveAttribute('data-dirty', 'true'))
    expect(screen.getByTestId('policy-apply')).toHaveTextContent('1')
    expect(screen.getByTestId('policy-apply')).toBeEnabled()
    expect(screen.getByText('pending')).toBeInTheDocument()
  })

  /**
   * The fallback saves through the same write-now/apply-later path as a rule,
   * but it was not in the diff. So after one apply, changing it left the count
   * at 0 — and a count of 0 is exactly what disables Apply. The one control on
   * the page that cannot self-apply was also the one whose change could not be
   * applied, short of a reload clearing the snapshot.
   */
  it('re-enables apply when only the fallback changed', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getByTestId('policy-apply'))
    await waitFor(() => expect(screen.getByTestId('policy-apply')).toBeDisabled())

    // Touch nothing but the fallback.
    await user.click(screen.getByRole('tab', { name: /gateway/i }))

    await waitFor(() => expect(screen.getByTestId('policy-apply')).toBeEnabled())
    expect(screen.getByTestId('policy-header')).toHaveAttribute('data-dirty', 'true')
    expect(screen.getByTestId('policy-apply')).toHaveTextContent('1')
    // The count has to be traceable to a control, so the card carries the marker.
    expect(screen.getByTestId('policy-fallback')).toHaveAttribute('data-pending', 'true')

    // And applying again settles it rather than leaving it permanently dirty.
    await user.click(screen.getByTestId('policy-apply'))
    await waitFor(() => expect(screen.getByTestId('policy-apply')).toBeDisabled())
    expect(screen.getByTestId('policy-fallback')).toHaveAttribute('data-pending', 'false')
  })

  /**
   * The rule list is unbounded, so on a phone the only control that publishes
   * an edit scrolled away from the edits that needed publishing. The brief
   * pins it; there is exactly one Apply on screen either way.
   */
  it('pins apply to the bottom of the viewport on a phone', async () => {
    setMobile(true)
    try {
      renderPage()
      await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())
      const bar = screen.getByTestId('policy-apply-bar')
      expect(bar.className).toContain('sticky')
      expect(within(bar).getByTestId('policy-apply')).toBeInTheDocument()
      expect(screen.getAllByTestId('policy-apply')).toHaveLength(1)
    } finally {
      setMobile(false)
    }
  })

  it('surfaces an apply validation error as a toast, not a crash', async () => {
    vi.mocked(api.applyPolicy).mockRejectedValueOnce(new Error('mihomo -t: bad rule'))
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getByTestId('policy-apply'))

    await waitFor(() => expect(screen.getByText(/mihomo -t: bad rule/)).toBeInTheDocument())
  })

  it('opens the add dialog from the header button', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getByRole('button', { name: 'Add rule' }))

    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.getByText('Add policy rule')).toBeInTheDocument()
  })

  it('opens the edit dialog from a table row, prefilled with that rule', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getAllByRole('button', { name: /more actions/i })[0])
    await user.click(await screen.findByText('Edit'))

    expect(screen.getByText('Edit policy rule')).toBeInTheDocument()
    expect(screen.getByDisplayValue('netflix.com')).toBeInTheDocument()
  })

  it('deletes a rule via the confirm dialog, then reloads', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getAllByRole('button', { name: /more actions/i })[0])
    await user.click(await screen.findByText('Delete'))
    await user.click(screen.getByTestId('policy-rule-delete-confirm'))

    await waitFor(() => expect(api.deletePolicyRule).toHaveBeenCalledWith('a'))
    await waitFor(() => expect(api.getPolicyRules).toHaveBeenCalledTimes(2)) // initial load + post-delete reload
  })

  it('toggles enabled via updatePolicyRule, then reloads', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getByRole('switch'))

    await waitFor(() =>
      expect(api.updatePolicyRule).toHaveBeenCalledWith('a', {
        matcher: { kind: 'domain-suffix', value: 'netflix.com' },
        intent: 'proxy',
        enabled: false,
      }),
    )
  })
})
