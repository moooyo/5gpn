import { describe, expect, it } from 'vitest'
import type { FallbackPolicyKind, PolicyRule } from '../../lib/api/types'
import { diffPolicyRules, type PolicySnapshot } from './policy-dirty'

const RULES: PolicyRule[] = [
  { id: 'a', order: 0, matcher: { kind: 'domain-suffix', value: 'netflix.com' }, intent: 'proxy', enabled: true },
  { id: 'b', order: 1, matcher: { kind: 'domain-suffix', value: 'example.cn' }, intent: 'direct', enabled: true },
  { id: 'c', order: 2, matcher: { kind: 'domain', value: 'ads.example' }, intent: 'block', enabled: false },
]

const clone = (rules: PolicyRule[]) => rules.map((rule) => ({ ...rule, matcher: { ...rule.matcher } }))
/** The fallback is held steady in the rule cases so each asserts one thing. */
const snap = (rules: PolicyRule[], fallback: FallbackPolicyKind | null = 'auto'): PolicySnapshot => ({ rules, fallback })
const APPLIED = snap(RULES)

/**
 * Every CRUD action here writes `policy.json` immediately while Apply is what
 * recompiles the live policy, and nothing on the page reconciled the two. This
 * is the comparison that answers "is what is running still what is saved".
 */
describe('diffPolicyRules', () => {
  it('reports nothing pending before the first apply of this session', () => {
    expect(diffPolicyRules(null, snap(RULES))).toEqual({ ids: new Set(), count: 0, fallbackPending: false })
  })

  it('reports nothing pending when the list is unchanged', () => {
    expect(diffPolicyRules(APPLIED, snap(clone(RULES)))).toEqual({ ids: new Set(), count: 0, fallbackPending: false })
  })

  it('flags an edited matcher value', () => {
    const next = clone(RULES)
    next[1].matcher.value = 'example.com'
    expect(diffPolicyRules(APPLIED, snap(next))).toEqual({ ids: new Set(['b']), count: 1, fallbackPending: false })
  })

  it('flags a toggled rule', () => {
    const next = clone(RULES)
    next[2].enabled = true
    expect(diffPolicyRules(APPLIED, snap(next))).toEqual({ ids: new Set(['c']), count: 1, fallbackPending: false })
  })

  it('flags a changed intent', () => {
    const next = clone(RULES)
    next[0].intent = 'direct'
    expect(diffPolicyRules(APPLIED, snap(next))).toEqual({ ids: new Set(['a']), count: 1, fallbackPending: false })
  })

  // Order is first-match precedence in this engine, so a move changes what the
  // policy does just as much as an edit does.
  it('flags both rules involved in a swap', () => {
    const next = clone(RULES)
    ;[next[0], next[1]] = [next[1], next[0]]
    expect(diffPolicyRules(APPLIED, snap(next))).toEqual({ ids: new Set(['a', 'b']), count: 2, fallbackPending: false })
  })

  it('flags an added rule', () => {
    const next = [...clone(RULES), { id: 'd', order: 3, matcher: { kind: 'domain' as const, value: 'new.example' }, intent: 'block' as const, enabled: true }]
    expect(diffPolicyRules(APPLIED, snap(next))).toEqual({ ids: new Set(['d']), count: 1, fallbackPending: false })
  })

  // A removed rule has no row left to mark, but the running policy is still
  // stale because of it — so it counts even though `ids` cannot carry it.
  it('counts a removed rule even though no row can carry the marker', () => {
    const next = clone(RULES).filter((rule) => rule.id !== 'b')
    const result = diffPolicyRules(APPLIED, snap(next))
    expect(result.ids).toEqual(new Set(['c']))
    expect(result.count).toBe(2)
  })

  /**
   * The fallback saves through the same write-now/apply-later path as a rule.
   * Leaving it out of the diff did not merely under-report: with the rules
   * untouched the count stayed 0, the page called itself up to date, and that
   * DISABLES Apply — so changing the fallback after one apply left it
   * unpublishable until a reload cleared the snapshot.
   */
  it('flags a changed fallback even when no rule moved', () => {
    const result = diffPolicyRules(APPLIED, snap(clone(RULES), 'gateway'))
    expect(result).toEqual({ ids: new Set(), count: 1, fallbackPending: true })
  })

  it('adds the fallback to the rule count rather than replacing it', () => {
    const next = clone(RULES)
    next[0].intent = 'direct'
    const result = diffPolicyRules(APPLIED, snap(next, 'direct'))
    expect(result).toEqual({ ids: new Set(['a']), count: 2, fallbackPending: true })
  })

  // `null` is "the control has not loaded yet", not a value the operator chose.
  it('does not flag a fallback that is still loading on either side', () => {
    expect(diffPolicyRules(APPLIED, snap(clone(RULES), null)).fallbackPending).toBe(false)
    expect(diffPolicyRules(snap(RULES, null), snap(clone(RULES), 'gateway')).fallbackPending).toBe(false)
  })
})
