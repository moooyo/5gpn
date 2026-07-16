import { describe, expect, it } from 'vitest'
import { resolveDecision } from './log-columns'

/**
 * Table-driven coverage for `resolveDecision` (amendment A-H1): the label +
 * color for a log row come from `reason`, NOT the coarser `verdict` — this
 * is the exact 5-label / 5-color distinction A-H1 exists to protect, so
 * every one of the 5 reasons is asserted individually (a regression that
 * collapses any two of them back onto the same color/label would slip past
 * a test that only spot-checks one or two).
 */
describe('resolveDecision (amendment A-H1)', () => {
  it.each([
    ['block', 'logs.decision.block', '#dc2626'],
    ['force-direct', 'logs.decision.forceDirect', '#16a34a'],
    ['force-proxy', 'logs.decision.forceProxy', '#2563eb'],
    ['chnroute-cn', 'logs.decision.chnrouteCn', '#0891b2'],
    ['chnroute-foreign', 'logs.decision.chnrouteForeign', '#2563eb'],
  ])('reason=%s -> { key: %s, color: %s }', (reason, key, color) => {
    expect(resolveDecision({ reason, verdict: undefined })).toEqual({ key, color })
  })

  it('reason takes priority over verdict when both are present', () => {
    expect(resolveDecision({ reason: 'block', verdict: 'proxy' })).toEqual({
      key: 'logs.decision.block',
      color: '#dc2626',
    })
  })

  it.each([
    ['block', 'logs.decision.block', '#dc2626'],
    ['direct', 'logs.decision.direct', '#16a34a'],
    ['proxy', 'logs.decision.proxy', '#2563eb'],
  ])('falls back to the coarser verdict=%s when reason is missing -> { key: %s, color: %s }', (verdict, key, color) => {
    expect(resolveDecision({ reason: undefined, verdict })).toEqual({ key, color })
  })

  it('falls back to the neutral unknown decision when neither reason nor verdict is a recognized value', () => {
    const unknown = { key: 'verdicts.noVerdict', color: '#93a2bd' }
    expect(resolveDecision({ reason: 'not-a-real-reason', verdict: 'not-a-real-verdict' })).toEqual(unknown)
    expect(resolveDecision({})).toEqual(unknown)
    expect(resolveDecision({ reason: undefined, verdict: undefined })).toEqual(unknown)
  })
})
