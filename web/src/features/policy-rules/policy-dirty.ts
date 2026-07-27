import type { PolicyRule } from '../../lib/api/types'

/**
 * Which rules differ from the last successfully applied policy.
 *
 * Every CRUD action on this page persists to `policy.json` immediately —
 * `FallbackControl` says so in its own comment, which is why it has no save
 * button — but what actually recompiles and hot-reloads the live DNS policy is
 * the separate Apply at the top. Two models coexisted with nothing on screen
 * reconciling them: after editing three rules the page looked exactly as it
 * did before, and the only feedback Apply ever gave was a toast after the
 * fact.
 *
 * The snapshot is taken client-side after each successful apply, so this
 * answers "is what is running the same as what is saved" without a new
 * endpoint. A rule counts as pending when it was added, removed, edited, or
 * moved — order is first-match precedence here, so a move changes behaviour
 * just as much as an edit does.
 */
export interface PolicyDirtyState {
  /** Rules whose current content or position differs from the snapshot. */
  ids: Set<string>
  /** `ids.size` plus rules that existed in the snapshot and are now gone —
   *  those have no row left to mark but still make the policy stale. */
  count: number
}

export const NO_PENDING: PolicyDirtyState = { ids: new Set(), count: 0 }

function sameContent(left: PolicyRule, right: PolicyRule): boolean {
  return left.enabled === right.enabled
    && left.intent === right.intent
    && left.matcher.kind === right.matcher.kind
    && left.matcher.value === right.matcher.value
}

export function diffPolicyRules(applied: PolicyRule[] | null, current: PolicyRule[]): PolicyDirtyState {
  // No snapshot yet means the page has not applied anything in this session;
  // the running policy is assumed to match what the daemon loaded from disk.
  if (!applied) return NO_PENDING

  const appliedById = new Map(applied.map((rule, index) => [rule.id, { rule, index }]))
  const ids = new Set<string>()
  current.forEach((rule, index) => {
    const previous = appliedById.get(rule.id)
    if (!previous || previous.index !== index || !sameContent(previous.rule, rule)) ids.add(rule.id)
  })

  const currentIds = new Set(current.map((rule) => rule.id))
  const removed = applied.reduce((total, rule) => (currentIds.has(rule.id) ? total : total + 1), 0)
  return { ids, count: ids.size + removed }
}
