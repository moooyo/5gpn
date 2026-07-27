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

  it('filters by matcher value and disables — rather than removes — the reorder arrows', async () => {
    const user = userEvent.setup()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={() => {}} onReorder={() => {}} />)
    expect(screen.getByText('netflix.com')).toBeInTheDocument()
    await user.type(screen.getByTestId('policy-rules-search'), 'example')
    expect(screen.queryByText('netflix.com')).toBeNull()
    expect(screen.getByText('example.cn')).toBeInTheDocument()
    // The control stays visible and disabled: unmounting it left a bare row
    // whose only explanation was one line of 11px grey text.
    expect(screen.getByLabelText(/move up/i)).toBeDisabled()
    expect(screen.getByRole('button', { name: /clear filters/i })).toBeInTheDocument()
  })

  it('restores reordering through the inline hint clear action', async () => {
    const user = userEvent.setup()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={() => {}} onReorder={() => {}} />)
    await user.type(screen.getByTestId('policy-rules-search'), 'example')
    await user.click(screen.getByRole('button', { name: /clear filters/i }))
    expect(screen.getByText('netflix.com')).toBeInTheDocument()
    expect(screen.getAllByLabelText(/move down/i)[0]).toBeEnabled()
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

  /** Edit and delete moved into a per-row overflow: two filled buttons per row
   *  painted the most destructive action in the page N times over, in
   *  error-container, right next to a routine one. */
  it('invokes edit from the row overflow menu', async () => {
    const user = userEvent.setup()
    const onEdit = vi.fn()
    render(<PolicyRulesTable rules={RULES} onEdit={onEdit} onDelete={() => {}} onToggle={() => {}} onReorder={() => {}} />)
    const row = screen.getByText('example.cn').closest('tr')!

    await user.click(within(row).getByRole('button', { name: /more actions/i }))
    await user.click(await screen.findByText('Edit'))
    expect(onEdit).toHaveBeenCalledWith(expect.objectContaining({ id: 'b' }))
  })

  it('invokes delete from the row overflow menu', async () => {
    const user = userEvent.setup()
    const onDelete = vi.fn()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={onDelete} onToggle={() => {}} onReorder={() => {}} />)
    const row = screen.getByText('example.cn').closest('tr')!

    await user.click(within(row).getByRole('button', { name: /more actions/i }))
    await user.click(await screen.findByText('Delete'))
    expect(onDelete).toHaveBeenCalledWith(expect.objectContaining({ id: 'b' }))
  })

  /** Moving rule 20 to the top used to be nineteen clicks and nineteen
   *  requests, even though Reorder replaces the whole table server-side. */
  it('moves a rule to the top of the full order in one request', async () => {
    const user = userEvent.setup()
    const onReorder = vi.fn()
    render(<PolicyRulesTable rules={RULES} onEdit={() => {}} onDelete={() => {}} onToggle={() => {}} onReorder={onReorder} />)
    const row = screen.getByText('netflix.com').closest('tr')!

    await user.click(within(row).getByRole('button', { name: /more actions/i }))
    await user.click(await screen.findByText('Move to top'))
    expect(onReorder).toHaveBeenCalledTimes(1)
    expect(onReorder).toHaveBeenCalledWith(['c', 'a', 'b'])
  })

  /** The 3px marker and the pending tag are how the header card's count maps
   *  back to individual rows. */
  it('marks the rules that differ from the last applied snapshot', () => {
    render(
      <PolicyRulesTable
        rules={RULES}
        pendingIds={new Set(['b'])}
        onEdit={() => {}}
        onDelete={() => {}}
        onToggle={() => {}}
        onReorder={() => {}}
      />,
    )
    const pendingRow = screen.getByText('example.cn').closest('tr')!
    expect(within(pendingRow).getByText('pending')).toBeInTheDocument()
    const cleanRow = screen.getByText('netflix.com').closest('tr')!
    expect(within(cleanRow).queryByText('pending')).toBeNull()
  })
})
