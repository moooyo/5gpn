import type { FallbackPolicyKind, PolicyRule } from '../../lib/api/types'

/**
 * What differs from the last successfully applied policy.
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
 *
 * The unmatched fallback is part of the same comparison. It saves through the
 * same write-now/apply-later path as a rule, so leaving it out did not merely
 * under-report: with the rules untouched the count stayed 0, which made the
 * page consider itself up to date and DISABLE the only Apply button on it. A
 * fallback change was then unpublishable until the operator reloaded the page,
 * which is the one thing that clears the snapshot.
 */
export interface PolicyDirtyState {
  /** Rules whose current content or position differs from the snapshot. */
  ids: Set<string>
  /** `ids.size`, plus rules that existed in the snapshot and are now gone —
   *  those have no row left to mark but still make the policy stale — plus one
   *  for the fallback when it differs. */
  count: number
  /** The unmatched fallback differs from the snapshot. Carried separately
   *  because it has no id and its own card renders the marker. */
  fallbackPending: boolean
}

/** Everything Apply publishes: the ordered rules and the unmatched fallback. */
export interface PolicySnapshot {
  rules: PolicyRule[]
  /** `null` while the control is still loading its current value. */
  fallback: FallbackPolicyKind | null
}

export const NO_PENDING: PolicyDirtyState = { ids: new Set(), count: 0, fallbackPending: false }

function sameContent(left: PolicyRule, right: PolicyRule): boolean {
  return left.enabled === right.enabled
    && left.intent === right.intent
    && left.matcher.kind === right.matcher.kind
    && left.matcher.value === right.matcher.value
}

export function diffPolicyRules(applied: PolicySnapshot | null, current: PolicySnapshot): PolicyDirtyState {
  // No snapshot yet means the page has not applied anything in this session;
  // the running policy is assumed to match what the daemon loaded from disk.
  if (!applied) return NO_PENDING

  const appliedById = new Map(applied.rules.map((rule, index) => [rule.id, { rule, index }]))
  const ids = new Set<string>()
  current.rules.forEach((rule, index) => {
    const previous = appliedById.get(rule.id)
    if (!previous || previous.index !== index || !sameContent(previous.rule, rule)) ids.add(rule.id)
  })

  const currentIds = new Set(current.rules.map((rule) => rule.id))
  const removed = applied.rules.reduce((total, rule) => (currentIds.has(rule.id) ? total : total + 1), 0)
  // A null on either side means the control had not loaded yet when the
  // snapshot was taken, which is not an operator edit.
  const fallbackPending = applied.fallback !== null
    && current.fallback !== null
    && applied.fallback !== current.fallback
  return { ids, count: ids.size + removed + (fallbackPending ? 1 : 0), fallbackPending }
}
