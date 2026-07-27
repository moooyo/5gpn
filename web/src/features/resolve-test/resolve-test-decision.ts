import type { TFunction } from 'i18next'
import { resolveDecision } from '../logs/log-columns'
import type { ResolveProbe, ResolveTestResult } from '../../lib/api/types'

/**
 * One-click example domains from the brief's exact set. The six between them
 * cover all five decisions, which makes them the fastest way to understand the
 * whole split — so each one states which decision it is expected to hit rather
 * than being an unlabeled shortcut. `slot` is the categorical chart slot that
 * decision owns everywhere else in the console.
 */
export const EXAMPLE_DOMAINS: Array<{ domain: string; expectKey: string; slot: 1 | 2 | 3 | 4 | 5 }> = [
  { domain: 'www.youtube.com', expectKey: 'decision.forceProxy', slot: 3 },
  { domain: 'apple.com', expectKey: 'decision.chnrouteForeign', slot: 5 },
  { domain: 'baidu.com', expectKey: 'decision.chnrouteCn', slot: 4 },
  { domain: 'ads.doubleclick.net', expectKey: 'decision.block', slot: 1 },
  { domain: 'github.com', expectKey: 'decision.chnrouteForeign', slot: 5 },
  { domain: 'taobao.com', expectKey: 'decision.forceDirect', slot: 2 },
]

// reason -> i18n key slug shared by decision.<slug> and
// resolveTest.steps.<slug>. These are the five reasons with specialized UI.
const KNOWN_SLUG: Record<string, string> = {
  'block': 'block',
  'force-direct': 'forceDirect',
  'force-proxy': 'forceProxy',
  'chnroute-cn': 'chnrouteCn',
  'chnroute-foreign': 'chnrouteForeign',
}

export interface ResolveTestDecision {
  /** Shared with the logs view's reason→color mapping: the five reasons hold
   *  fixed categorical chart slots (block 1 / force-direct 2 / force-proxy 3 /
   *  chnroute-cn 4 / chnroute-foreign 5), falling back by `verdict`. Not
   *  semantic UI roles — ocean aliases primary onto trace and forest aliases
   *  primary onto success, which used to collapse five decisions into three. */
  color: string
  /** Already-localized pill text. */
  label: string
  /** Already-localized 决策路径 step strings — 3 for a known `reason`, a
   *  single generic step derived from `verdict` when `reason` is
   *  missing/unrecognized. */
  steps: string[]
}

/** Derives the verdict pill + numbered decision-path steps for a
 *  `/api/resolve-test` result. The color always comes from the logs view's
 *  `resolveDecision` (reason primary, verdict fallback) so the two live
 *  views never disagree on what color a given reason means. */
export function decideResolveTest(result: Pick<ResolveTestResult, 'reason' | 'verdict' | 'intercept'>, t: TFunction): ResolveTestDecision {
  const color = resolveDecision(result).color
  // A live extension capture and an operator proxy rule share `force-proxy`
  // deliberately — observability counts them as one thing — so the steps have
  // to branch on the attribution, not the reason.
  if (result.reason === 'force-proxy' && result.intercept?.ready) {
    return {
      color,
      label: t('decision.forceProxy'),
      steps: t('resolveTest.steps.interceptForceProxy', {
        name: result.intercept.module_name || result.intercept.module_id,
        returnObjects: true,
      }) as unknown as string[],
    }
  }
  const slug = result.reason ? KNOWN_SLUG[result.reason] : undefined
  if (slug) {
    return {
      color,
      label: t(`decision.${slug}`),
      steps: t(`resolveTest.steps.${slug}`, { returnObjects: true }) as unknown as string[],
    }
  }
  return {
    color,
    label: result.verdict || t('verdicts.noVerdict'),
    steps: [t('resolveTest.steps.generic', { verdict: result.verdict || t('verdicts.noVerdict') })],
  }
}

/** Which source the UI should attribute a gateway verdict to.
 *
 *  `intercept` — a live extension capture won, before policy was consulted.
 *  `policy`    — an operator rule won (an extension may still have DECLARED
 *                the name with capture inert; that is reported separately).
 *  `none`      — nothing to attribute (chnroute, fallback, block, …).
 *
 *  Kept beside `decideResolveTest` rather than inline in the page because both
 *  are "turn a raw result into what the operator should be told", and this one
 *  is worth testing without mounting a component. */
export type AttributionKind = 'intercept' | 'policy' | 'none'

export function attributionOf(result: Pick<ResolveTestResult, 'reason' | 'intercept' | 'policy'>): AttributionKind {
  if (result.intercept?.ready) return 'intercept'
  if (result.policy) return 'policy'
  return 'none'
}

/** 解析来源: `chosen` group name + a human group label (e.g. "china (国内
 *  UDP)"), falling back to the probe marked `selected` when `chosen` is
 *  absent. */
export function resolveSourceText(result: Pick<ResolveTestResult, 'chosen' | 'probes'>, t: TFunction): string {
  const groupLabel = (g: ResolveProbe['group']) => (g === 'china' ? t('resolveTest.groupChina') : t('resolveTest.groupTrust'))
  if (result.chosen === 'china' || result.chosen === 'trust') {
    return `${result.chosen} (${groupLabel(result.chosen)})`
  }
  const selected = result.probes?.find((p) => p.selected)
  if (selected) return `${selected.server} (${groupLabel(selected.group)})`
  return '—'
}
