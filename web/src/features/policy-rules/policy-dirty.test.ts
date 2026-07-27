import { describe, expect, it } from 'vitest'
import type { PolicyRule } from '../../lib/api/types'
import { diffPolicyRules } from './policy-dirty'

const RULES: PolicyRule[] = [
  { id: 'a', order: 0, matcher: { kind: 'domain-suffix', value: 'netflix.com' }, intent: 'proxy', enabled: true },
  { id: 'b', order: 1, matcher: { kind: 'domain-suffix', value: 'example.cn' }, intent: 'direct', enabled: true },
  { id: 'c', order: 2, matcher: { kind: 'domain', value: 'ads.example' }, intent: 'block', enabled: false },
]

const clone = (rules: PolicyRule[]) => rules.map((rule) => ({ ...rule, matcher: { ...rule.matcher } }))

/**
 * Every CRUD action here writes `policy.json` immediately while Apply is what
 * recompiles the live policy, and nothing on the page reconciled the two. This
 * is the comparison that answers "is what is running still what is saved".
 */
describe('diffPolicyRules', () => {
  it('reports nothing pending before the first apply of this session', () => {
    expect(diffPolicyRules(null, RULES)).toEqual({ ids: new Set(), count: 0 })
  })

  it('reports nothing pending when the list is unchanged', () => {
    expect(diffPolicyRules(RULES, clone(RULES))).toEqual({ ids: new Set(), count: 0 })
  })

  it('flags an edited matcher value', () => {
    const next = clone(RULES)
    next[1].matcher.value = 'example.com'
    expect(diffPolicyRules(RULES, next)).toEqual({ ids: new Set(['b']), count: 1 })
  })

  it('flags a toggled rule', () => {
    const next = clone(RULES)
    next[2].enabled = true
    expect(diffPolicyRules(RULES, next)).toEqual({ ids: new Set(['c']), count: 1 })
  })

  it('flags a changed intent', () => {
    const next = clone(RULES)
    next[0].intent = 'direct'
    expect(diffPolicyRules(RULES, next)).toEqual({ ids: new Set(['a']), count: 1 })
  })

  // Order is first-match precedence in this engine, so a move changes what the
  // policy does just as much as an edit does.
  it('flags both rules involved in a swap', () => {
    const next = clone(RULES)
    ;[next[0], next[1]] = [next[1], next[0]]
    expect(diffPolicyRules(RULES, next)).toEqual({ ids: new Set(['a', 'b']), count: 2 })
  })

  it('flags an added rule', () => {
    const next = [...clone(RULES), { id: 'd', order: 3, matcher: { kind: 'domain' as const, value: 'new.example' }, intent: 'block' as const, enabled: true }]
    expect(diffPolicyRules(RULES, next)).toEqual({ ids: new Set(['d']), count: 1 })
  })

  // A removed rule has no row left to mark, but the running policy is still
  // stale because of it — so it counts even though `ids` cannot carry it.
  it('counts a removed rule even though no row can carry the marker', () => {
    const next = clone(RULES).filter((rule) => rule.id !== 'b')
    const result = diffPolicyRules(RULES, next)
    expect(result.ids).toEqual(new Set(['c']))
    expect(result.count).toBe(2)
  })
})
