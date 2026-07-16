import { render, screen, waitFor } from '@testing-library/react'
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

function renderPage() {
  return render(
    <>
      <PolicyRulesPage />
      <Toaster />
    </>,
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

    await user.click(screen.getByText('Edit'))

    expect(screen.getByText('Edit policy rule')).toBeInTheDocument()
    expect(screen.getByDisplayValue('netflix.com')).toBeInTheDocument()
  })

  it('deletes a rule via the confirm dialog, then reloads', async () => {
    const user = userEvent.setup()
    renderPage()
    await waitFor(() => expect(screen.getByText('netflix.com')).toBeInTheDocument())

    await user.click(screen.getByText('Delete'))
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
