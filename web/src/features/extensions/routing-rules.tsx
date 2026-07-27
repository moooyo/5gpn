import type { InterceptRoutingRule } from '../../lib/api/types'
import { cn } from '../../lib/cn'

/**
 * A reviewed manifest may declare bounded, typed mihomo REJECT/DIRECT rules.
 * They were rendered as `JSON.stringify(rule)` inside a 9.5px monospace block
 * on a warning background — in the card AND in each of the three dialogs. The
 * operator has to read these to make an enable decision, so the shape that
 * decision is made from is the one that matters.
 *
 * This turns each rule into mihomo's own vocabulary: a matcher type, its
 * value, the action it produces, and any narrowing constraints. Nothing is
 * dropped — the enable confirmation is required to show every declared rule
 * exactly, so every field a rule can carry appears here.
 */
export interface RoutingRuleView {
  /** mihomo rule type, e.g. DOMAIN-SUFFIX. */
  kind: string
  /** The matched value as written in the manifest. */
  value: string
  /** Where the match sends the traffic. These rules cannot name a proxy
   *  group; the only outcomes are REJECT and DIRECT. */
  action: 'REJECT' | 'DIRECT'
  /** Narrowing conditions (network, destination port), if declared. */
  constraints: string[]
}

export function describeRoutingRule(rule: InterceptRoutingRule): RoutingRuleView {
  let kind = 'RULE'
  let value = ''
  if (rule.domain !== undefined) {
    kind = 'DOMAIN'
    value = rule.domain
  } else if (rule.domain_suffix !== undefined) {
    kind = 'DOMAIN-SUFFIX'
    value = rule.domain_suffix
  } else if (rule.domain_keywords !== undefined) {
    kind = 'DOMAIN-KEYWORD'
    value = rule.domain_keywords.join(', ')
  } else if (rule.all_domain_keywords !== undefined) {
    // Every keyword has to match, which is a materially narrower rule than the
    // any-of form above — the two must not read the same.
    kind = 'DOMAIN-KEYWORD-ALL'
    value = rule.all_domain_keywords.join(' + ')
  } else if (rule.ip_cidr !== undefined) {
    kind = 'IP-CIDR'
    value = rule.ip_cidr
  }

  const constraints: string[] = []
  if (rule.network) constraints.push(rule.network.toUpperCase())
  if (rule.destination_port !== undefined) constraints.push(`:${rule.destination_port}`)

  return { kind, value, action: rule.action === 'reject' ? 'REJECT' : 'DIRECT', constraints }
}

const ACTION_CLASS: Record<RoutingRuleView['action'], string> = {
  REJECT: 'bg-[var(--md-sys-color-error-container)] text-[var(--md-sys-color-on-error-container)]',
  DIRECT: 'bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]',
}

/** Two columns: what is matched on the left, where it goes on the right. */
export function RoutingRuleList({
  rules,
  className,
  testId,
}: {
  rules: InterceptRoutingRule[]
  className?: string
  testId?: string
}) {
  return (
    <ul className={cn('flex flex-col gap-1.5', className)} data-testid={testId}>
      {rules.map((rule, index) => {
        const view = describeRoutingRule(rule)
        return (
          <li key={`${index}:${view.kind}:${view.value}`} className="flex min-w-0 items-center gap-2 rounded-chip bg-[rgb(0_0_0_/_6%)] px-2 py-1.5">
            <span className="shrink-0 font-mono text-meta opacity-70">{view.kind}</span>
            <span className="min-w-0 flex-1 break-all font-mono text-meta font-medium">{view.value}</span>
            {view.constraints.length > 0 ? (
              <span className="shrink-0 font-mono text-meta opacity-70">{view.constraints.join(' ')}</span>
            ) : null}
            <span aria-hidden="true" className="shrink-0 opacity-60">→</span>
            <span className={cn('shrink-0 rounded-chip px-2 py-0.5 font-mono text-meta font-semibold', ACTION_CLASS[view.action])}>
              {view.action}
            </span>
          </li>
        )
      })}
    </ul>
  )
}
