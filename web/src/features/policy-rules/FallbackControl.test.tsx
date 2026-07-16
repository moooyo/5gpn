import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { FallbackControl } from './FallbackControl'
// Side-effect import: initializes the real i18next singleton (mirrors
// egress.test.tsx). Without it useTranslation()'s `t` has no stable identity
// (NO_I18NEXT_INSTANCE), so the load useCallback ([t] dep) re-creates every
// render and the mount useEffect re-fires on every state change, clobbering
// the optimistic edit before its persist settles.
import i18n from '../../i18n'

vi.mock('../../lib/api/client', () => ({
  api: {
    getPolicyFallback: vi.fn(async () => ({ policy: 'auto' })),
    putPolicyFallback: vi.fn(async () => ({ ok: true })),
  },
}))
import { api } from '../../lib/api/client'

describe('FallbackControl', () => {
  beforeEach(async () => {
    vi.clearAllMocks()
    // fallbackLng is 'zh' — pin to 'en' so the segmented-control tab labels
    // are stable/ASCII for the /gateway/i query, matching egress.test.tsx's
    // pattern of explicitly setting the language rather than relying on
    // whatever a previous test file left the shared i18n singleton at.
    await i18n.changeLanguage('en')
  })

  it('persists a policy change immediately on selection (no save button)', async () => {
    const user = userEvent.setup()
    render(<FallbackControl />)
    await waitFor(() => expect(screen.getByRole('tab', { name: /gateway/i })).toBeInTheDocument())
    await user.click(screen.getByRole('tab', { name: /gateway/i }))
    await waitFor(() => expect(api.putPolicyFallback).toHaveBeenCalledWith({ policy: 'gateway' }))
    // The separate save button is gone — the segmented selection IS the save.
    expect(screen.queryByTestId('policy-fallback-save')).toBeNull()
  })

  it('keeps application egress out of the DNS fallback control', async () => {
    render(<FallbackControl />)
    await waitFor(() => expect(screen.getByRole('tab', { name: /gateway/i })).toBeInTheDocument())
    expect(screen.queryByRole('combobox')).toBeNull()
  })
})
