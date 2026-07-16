import type { TFunction } from 'i18next'
import { resolveDecision } from '../logs/log-columns'
import type { ResolveProbe, ResolveTestResult } from '../../lib/api/types'

/** One-click example domains from the brief's exact set (design handoff's
 *  `examples` list). */
export const EXAMPLE_DOMAINS = [
  'www.youtube.com',
  'apple.com',
  'baidu.com',
  'ads.doubleclick.net',
  'github.com',
  'taobao.com',
]

// reason -> i18n key slug shared by resolveTest.label.<slug> and
// resolveTest.steps.<slug>. These are the five reasons with specialized UI.
const KNOWN_SLUG: Record<string, string> = {
  'block': 'block',
  'force-direct': 'forceDirect',
  'force-proxy': 'forceProxy',
  'chnroute-cn': 'chnrouteCn',
  'chnroute-foreign': 'chnrouteForeign',
}

export interface ResolveTestDecision {
  /** Shared with the logs view's reason→color mapping (block red /
   *  force-direct green / force-proxy blue / chnroute-cn cyan /
   *  chnroute-foreign blue; falls back by `verdict`). */
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
export function decideResolveTest(result: Pick<ResolveTestResult, 'reason' | 'verdict'>, t: TFunction): ResolveTestDecision {
  const color = resolveDecision(result).color
  const slug = result.reason ? KNOWN_SLUG[result.reason] : undefined
  if (slug) {
    return {
      color,
      label: t(`resolveTest.label.${slug}`),
      steps: t(`resolveTest.steps.${slug}`, { returnObjects: true }) as unknown as string[],
    }
  }
  return {
    color,
    label: result.verdict || t('verdicts.noVerdict'),
    steps: [t('resolveTest.steps.generic', { verdict: result.verdict || t('verdicts.noVerdict') })],
  }
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
