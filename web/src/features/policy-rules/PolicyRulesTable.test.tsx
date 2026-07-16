import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeAll, describe, expect, it, vi } from 'vitest'
// Side-effect import: initializes the real i18next singleton (mirrors
// egress.test.tsx / FallbackControl.test.tsx). Without it useTranslation()'s
// `t` has no stable identity, which can re-fire memoized callbacks/effects
// that depend on [t] — a real gap hit in B2.
import i18n from '../../i18n'
import { PolicyRulesTable } from './PolicyRulesTable'
import type { PolicyRule } from '../../lib/api/types'

const RULES: PolicyRule[] = [
  { id: 'a', order: 0, matcher: { kind: 'subscription', value: 'https://x/blocklist.txt', format: 'plain', interval: '24h0m0s' }, intent: 'block', enabled: true },
  { id: 'b', order: 1, matcher: { kind: 'domain-suffix', value: 'example.cn' }, intent: 'direct', enabled: true },
  { id: 'c', order: 2, matcher: { kind: 'domain-suffix', value: 'netflix.com' }, intent: 'proxy', enabled: false },
]

describe('PolicyRulesTable', () => {
  beforeAll(async () => {
    await i18n.changeLanguage('en')
  })

  it('filters by matcher value and hides reorder arrows while filtering', async () => {
    const user = userEvent.setup()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={() => {}} onReorder={() => {}} />)
    expect(screen.getByText('netflix.com')).toBeInTheDocument()
    await user.type(screen.getByTestId('policy-rules-search'), 'example')
    expect(screen.queryByText('netflix.com')).toBeNull()
    expect(screen.getByText('example.cn')).toBeInTheDocument()
    expect(screen.queryByLabelText(/move up/i)).toBeNull() // arrows hidden while filtering
  })

  it('move-down calls onReorder with the swapped full id list', async () => {
    const user = userEvent.setup()
    const onReorder = vi.fn()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={() => {}} onReorder={onReorder} />)
    const firstRow = screen.getByText('https://x/blocklist.txt').closest('tr')!
    await user.click(within(firstRow).getByLabelText(/move down/i))
    expect(onReorder).toHaveBeenCalledWith(['b', 'a', 'c'])
  })

  it('toggling enabled calls onToggle with the rule', async () => {
    const user = userEvent.setup()
    const onToggle = vi.fn()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={onToggle} onReorder={() => {}} />)
    const proxyRow = screen.getByText('netflix.com').closest('tr')!
    await user.click(within(proxyRow).getByRole('switch'))
    expect(onToggle).toHaveBeenCalledWith(expect.objectContaining({ id: 'c' }))
  })

  it('filters by intent', async () => {
    const user = userEvent.setup()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={() => {}} onReorder={() => {}} />)
    await user.click(screen.getByRole('tab', { name: /^direct$/i }))
    expect(screen.getByText('example.cn')).toBeInTheDocument()
    expect(screen.queryByText('netflix.com')).toBeNull()
    expect(screen.queryByText('https://x/blocklist.txt')).toBeNull()
  })

  it('edit and delete buttons invoke the handlers with the row rule', async () => {
    const user = userEvent.setup()
    const onEdit = vi.fn()
    const onDelete = vi.fn()
    render(<PolicyRulesTable rules={RULES} onEdit={onEdit} onDelete={onDelete} onToggle={() => {}} onReorder={() => {}} />)
    const row = screen.getByText('example.cn').closest('tr')!
    await user.click(within(row).getByText('Edit'))
    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: 'b' }))
    await user.click(within(row).getByText('Delete'))
    expect(onDelete).toHaveBeenCalledWith(expect.objectContaining({ id: 'b' }))
  })
})
