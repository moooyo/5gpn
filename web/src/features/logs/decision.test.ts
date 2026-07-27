import { describe, expect, it } from 'vitest'
import { resolveDecision } from './log-columns'

/**
 * Table-driven coverage for `resolveDecision` (amendment A-H1): the label +
 * color for a log row come from `reason`, NOT the coarser `verdict` — this
 * is the exact 5-label / 5-color distinction A-H1 exists to protect, so
 * every one of the 5 reasons is asserted individually (a regression that
 * collapses any two of them back onto the same color/label would slip past
 * a test that only spot-checks one or two).
 *
 * Colors are theme-scoped categorical slots rather than literal hex: fixed
 * values could not answer the dark theme, and several themes alias the
 * semantic roles the page used to borrow (forest primary == success, ocean
 * primary == trace), which painted distinct decisions the same.
 */
describe('resolveDecision (amendment A-H1)', () => {
  it.each([
    ['block', 'decision.block', 'var(--color-chart-1)'],
    ['force-direct', 'decision.forceDirect', 'var(--color-chart-2)'],
    ['force-proxy', 'decision.forceProxy', 'var(--color-chart-3)'],
    ['chnroute-cn', 'decision.chnrouteCn', 'var(--color-chart-4)'],
    ['chnroute-foreign', 'decision.chnrouteForeign', 'var(--color-chart-5)'],
  ])('reason=%s -> { key: %s, color: %s }', (reason, key, color) => {
    expect(resolveDecision({ reason, verdict: undefined })).toEqual({ key, color })
  })

  it('reason takes priority over verdict when both are present', () => {
    expect(resolveDecision({ reason: 'block', verdict: 'proxy' })).toEqual({
      key: 'decision.block',
      color: 'var(--color-chart-1)',
    })
  })

  it.each([
    ['block', 'decision.block', 'var(--color-chart-1)'],
    ['direct', 'decision.direct', 'var(--color-chart-2)'],
    ['proxy', 'decision.proxy', 'var(--color-chart-3)'],
  ])('falls back to the coarser verdict=%s when reason is missing -> { key: %s, color: %s }', (verdict, key, color) => {
    expect(resolveDecision({ reason: undefined, verdict })).toEqual({ key, color })
  })

  it('falls back to the neutral unknown decision when neither reason nor verdict is a recognized value', () => {
    const unknown = { key: 'verdicts.noVerdict', color: 'var(--color-text-faint)' }
    expect(resolveDecision({ reason: 'not-a-real-reason', verdict: 'not-a-real-verdict' })).toEqual(unknown)
    expect(resolveDecision({})).toEqual(unknown)
    expect(resolveDecision({ reason: undefined, verdict: undefined })).toEqual(unknown)
  })
})
