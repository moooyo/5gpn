import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { PolicyRuleDialog } from './PolicyRuleDialog'

vi.mock('../../lib/api/client', () => ({
  api: { createPolicyRule: vi.fn(async (r) => ({ ...r, id: 'prule-x', order: 9 })), updatePolicyRule: vi.fn() },
}))
import { api } from '../../lib/api/client'

describe('PolicyRuleDialog', () => {
  beforeEach(() => vi.clearAllMocks())

  it('keeps application egress out of every DNS intent', async () => {
    const user = userEvent.setup()
    render(<PolicyRuleDialog open onOpenChange={() => {}} onSaved={() => {}} />)
    // default intent = block -> no selector field
    expect(screen.queryByTestId('policy-rule-selector-field')).toBeNull()
    await user.click(screen.getByTestId('policy-rule-intent-proxy'))
    // proxy is only a DNS steering intent
    expect(screen.queryByTestId('policy-rule-selector-field')).toBeNull()
    await user.click(screen.getByTestId('policy-rule-intent-direct'))
    expect(screen.queryByTestId('policy-rule-selector-field')).toBeNull()
  })

  it('reveals url+format+interval only when matcher kind = subscription', async () => {
    const user = userEvent.setup()
    render(<PolicyRuleDialog open onOpenChange={() => {}} onSaved={() => {}} />)
    expect(screen.queryByTestId('policy-rule-format-field')).toBeNull()
    expect(screen.queryByTestId('policy-rule-interval-field')).toBeNull()
    await user.click(screen.getByTestId('policy-rule-kind-subscription'))
    expect(screen.getByTestId('policy-rule-format-field')).toBeInTheDocument()
    expect(screen.getByTestId('policy-rule-interval-field')).toBeInTheDocument()
  })

  it('rejects a subscription without a positive interval', async () => {
    const user = userEvent.setup()
    render(<PolicyRuleDialog open onOpenChange={() => {}} onSaved={() => {}} />)
    await user.click(screen.getByTestId('policy-rule-kind-subscription'))
    await user.type(screen.getByTestId('policy-rule-value'), 'https://example.test/list.txt')
    await user.clear(screen.getByPlaceholderText('24h0m0s'))
    await user.click(screen.getByTestId('policy-rule-dialog-save'))
    expect(screen.getByText('policyRules.dialog.errIntervalRequired')).toBeInTheDocument()
    expect(api.createPolicyRule).not.toHaveBeenCalled()
  })

  it('submits a proxy rule with just {intent:"proxy"} and no selector', async () => {
    const user = userEvent.setup()
    const onSaved = vi.fn()
    render(<PolicyRuleDialog open onOpenChange={() => {}} onSaved={onSaved} />)
    await user.click(screen.getByTestId('policy-rule-intent-proxy'))
    await user.type(screen.getByTestId('policy-rule-value'), 'netflix.com')
    await user.click(screen.getByTestId('policy-rule-dialog-save'))
    expect(api.createPolicyRule).toHaveBeenCalledWith(
      expect.objectContaining({ intent: 'proxy', matcher: expect.objectContaining({ kind: 'domain-suffix', value: 'netflix.com' }) }),
    )
    const body = vi.mocked(api.createPolicyRule).mock.calls[0][0]
    expect(body).not.toHaveProperty('selector')
    expect(onSaved).toHaveBeenCalled()
  })

  it('submits a plain domain-suffix block rule (default intent, no selector) with the typed value', async () => {
    const user = userEvent.setup()
    const onSaved = vi.fn()
    render(<PolicyRuleDialog open onOpenChange={() => {}} onSaved={onSaved} />)
    await user.type(screen.getByTestId('policy-rule-value'), 'awesome.com')
    await user.click(screen.getByTestId('policy-rule-dialog-save'))
    expect(api.createPolicyRule).toHaveBeenCalledWith(
      expect.objectContaining({ intent: 'block', matcher: expect.objectContaining({ kind: 'domain-suffix', value: 'awesome.com' }) }),
    )
    const body = vi.mocked(api.createPolicyRule).mock.calls[0][0]
    expect(body).not.toHaveProperty('selector')
    expect(onSaved).toHaveBeenCalled()
  })
})
