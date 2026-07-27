import { useTranslation } from 'react-i18next'
import { CheckIcon, ExtensionIcon, RuleIcon, WarningIcon } from '../../components/icons'
import { Card, SectionLabel } from '../../components/ds'
import type { ResolveTestResult } from '../../lib/api/types'
import { attributionOf } from './resolve-test-decision'

/** One row of the decision-order table.
 *
 *  `mark` is deliberately plain ink even on the winning row: the hue lives in
 *  the dot. `--color-chart-3` on 11px text over the card surface lands around
 *  2.9:1, below AA — the same reason `log-columns` colors only the StatusDot
 *  and leaves its label in text ink. */
type StageState = 'hit' | 'miss' | 'skipped' | 'answer'

interface Stage {
  state: StageState
  stage: string
  detail: string
  mark?: string
  markStrong?: boolean
  markMono?: boolean
}

function StageDot({ state }: { state: StageState }) {
  if (state === 'hit') {
    return (
      <span
        className="grid h-[22px] w-[22px] shrink-0 place-items-center rounded-full text-white"
        style={{ background: 'var(--color-chart-3)' }}
        aria-hidden="true"
      >
        <CheckIcon className="h-3.5 w-3.5" />
      </span>
    )
  }
  if (state === 'answer') {
    return (
      <span
        className="grid h-[22px] w-[22px] shrink-0 place-items-center rounded-full bg-primary-container text-on-primary-container"
        aria-hidden="true"
      >
        <span className="text-[13px] leading-none">→</span>
      </span>
    )
  }
  return (
    <span
      className="grid h-[22px] w-[22px] shrink-0 place-items-center rounded-full bg-surface-container text-[13px] leading-none text-text-faint"
      aria-hidden="true"
    >
      −
    </span>
  )
}

function DecisionOrder({ stages }: { stages: Stage[] }) {
  const { t } = useTranslation()
  return (
    <div>
      <SectionLabel className="mb-3.5">{t('resolveTest.intercept.orderTitle')}</SectionLabel>
      <ol>
        {stages.map((row, index) => (
          <li
            key={row.stage}
            className={`flex items-center gap-3.5 py-[11px] ${index < stages.length - 1 ? 'border-b border-surface-container-low' : ''}`}
          >
            <StageDot state={row.state} />
            <span
              className={`w-[150px] shrink-0 text-[12.5px] ${
                row.state === 'hit' || row.state === 'answer' ? 'font-medium text-text-strong' : 'text-text-faint'
              } max-sm:w-auto`}
            >
              {row.stage}
            </span>
            <span className="min-w-0 flex-1 text-[11.5px] leading-5 text-text-mid">{row.detail}</span>
            {row.mark ? (
              <span
                className={`shrink-0 text-[11px] font-medium ${row.markMono ? 'font-mono text-text-strong' : ''}`}
                style={row.markStrong ? { color: 'var(--md-sys-color-success)' } : undefined}
              >
                {!row.markStrong && !row.markMono ? <span className="text-text-faint">{row.mark}</span> : row.mark}
              </span>
            ) : null}
          </li>
        ))}
      </ol>
    </div>
  )
}

/** The de-identified response, verbatim. The point of a forensic view is that
 *  the operator can check the rendering against the wire, so this is the real
 *  object rather than a re-serialization of what the UI happened to read. */
function RawResponse({ result, note }: { result: ResolveTestResult; note?: string }) {
  const { t } = useTranslation()
  return (
    <div>
      <SectionLabel className="mb-3">{t('resolveTest.intercept.rawTitle')}</SectionLabel>
      <pre className="whitespace-pre-wrap break-all font-mono text-[11.5px] leading-5 text-text-strong">
        {JSON.stringify(result, null, 2)}
      </pre>
      {note ? <div className="mt-2 font-mono text-[11.5px] text-text-faint">{note}</div> : null}
    </div>
  )
}

function stageRows(result: ResolveTestResult, t: ReturnType<typeof useTranslation>['t']): Stage[] {
  const kind = attributionOf(result)
  const answerIP = result.client_ips?.length ? result.client_ips.join(', ') : undefined
  const count = result.intercept_module_count ?? 0

  const interceptRow: Stage =
    kind === 'intercept' && result.intercept
      ? {
          state: 'hit',
          stage: t('resolveTest.intercept.stageIntercept'),
          detail: t('resolveTest.intercept.interceptHit', { host: result.intercept.matched_host }),
          mark: t('resolveTest.intercept.markActive'),
          markStrong: true,
        }
      : result.intercept
        ? {
            // Declared but inert. Reporting this as "none declared it" would
            // contradict the notice directly above and send the operator
            // looking for a rule that does not exist.
            state: 'miss',
            stage: t('resolveTest.intercept.stageIntercept'),
            detail: t('resolveTest.intercept.interceptDeclaredInert', { host: result.intercept.matched_host }),
            mark: t('resolveTest.intercept.markInert'),
          }
        : {
            state: 'miss',
            stage: t('resolveTest.intercept.stageIntercept'),
            // The exclusion IS the finding, so this row renders even on a miss
            // — and states how many extensions were checked, because "none of
            // 3" is an answer while silence is not.
            detail: count > 0
              ? t('resolveTest.intercept.interceptMissWithCount', { count })
              : t('resolveTest.intercept.interceptMiss'),
            mark: t('resolveTest.intercept.markMiss'),
          }

  const policyRow: Stage =
    kind === 'policy' && result.policy
      ? {
          state: 'hit',
          stage: t('resolveTest.intercept.stagePolicy'),
          detail: t('resolveTest.intercept.policyHit', {
            order: result.policy.order + 1,
            kind: result.policy.kind,
            value: result.policy.value,
          }),
          mark: t('resolveTest.intercept.markActive'),
          markStrong: true,
        }
      : {
          state: 'skipped',
          stage: t('resolveTest.intercept.stagePolicy'),
          detail: t('resolveTest.intercept.policySkipped'),
          mark: t('resolveTest.intercept.markSkipped'),
        }

  return [
    interceptRow,
    policyRow,
    {
      state: 'skipped',
      stage: t('resolveTest.intercept.stageFallback'),
      detail: t('resolveTest.intercept.fallbackSkipped'),
      mark: t('resolveTest.intercept.markSkipped'),
    },
    {
      state: 'answer',
      stage: t('resolveTest.intercept.stageAnswer'),
      detail: t('resolveTest.intercept.answerSynthesized'),
      mark: answerIP,
      markMono: true,
    },
  ]
}

/** Renders the attribution for a gateway verdict.
 *
 *  A live extension capture gets its own card — who declared the name, which
 *  pattern matched, what was skipped, and the raw response. An operator rule
 *  gets the same evidence inline, since there is no extension to introduce.
 *  Returns null when there is nothing to attribute. */
export function AttributionSection({ result }: { result: ResolveTestResult }) {
  const { t } = useTranslation()
  const kind = attributionOf(result)
  const intercept = result.intercept
  const inert = intercept !== undefined && !intercept.ready

  if (kind === 'none' && !inert) return null

  const stages = stageRows(result, t)

  if (kind !== 'intercept') {
    return (
      <div className="border-t border-divider">
        {inert && intercept ? (
          <div className="px-5 pt-5 sm:px-6">
            <InertNotice host={intercept.matched_host} moduleName={intercept.module_name} moduleID={intercept.module_id} />
          </div>
        ) : null}
        <div className="px-5 py-5 sm:px-6">
          <DecisionOrder stages={stages} />
        </div>
        <div className="border-t border-divider bg-surface-container-low px-5 py-5 sm:px-6">
          <RawResponse result={result} note={t('resolveTest.intercept.rawPolicyNote')} />
        </div>
      </div>
    )
  }

  return (
    <Card className="overflow-hidden" data-testid="resolve-test-attribution">
      <div className="flex flex-wrap items-center gap-3 border-b border-divider bg-surface-container-low px-5 py-3.5 sm:px-6">
        <span className="text-[13px] font-medium text-text-strong">{t('resolveTest.intercept.title')}</span>
        <span className="ml-auto font-mono text-[10.5px] uppercase tracking-[.06em] text-text-faint">
          {t('resolveTest.intercept.meta', { reason: result.reason })}
        </span>
      </div>

      <div className="grid gap-px bg-divider sm:grid-cols-2">
        <div className="bg-card px-5 py-5 sm:px-6" data-testid="resolve-test-declared-by">
          <SectionLabel className="mb-3">{t('resolveTest.intercept.declaredBy')}</SectionLabel>
          <div className="flex items-center gap-3.5">
            <span className="grid h-11 w-11 shrink-0 place-items-center rounded-[12px] bg-tertiary-container text-tertiary">
              <ExtensionIcon className="h-[22px] w-[22px]" aria-hidden="true" />
            </span>
            <span className="flex min-w-0 flex-col">
              <span className="truncate text-[15px] font-medium text-text-strong">
                {intercept?.module_name || intercept?.module_id}
              </span>
              <span className="truncate font-mono text-[11.5px] text-text-faint">{intercept?.module_id}</span>
            </span>
          </div>
        </div>
        <div className="bg-card px-5 py-5 sm:px-6">
          <SectionLabel className="mb-3">{t('resolveTest.intercept.matchedHost')}</SectionLabel>
          <span className="inline-block rounded-[8px] bg-secondary-container px-3 py-2 font-mono text-[13px] font-medium text-on-secondary-container">
            {intercept?.matched_host}
          </span>
          <p className="mt-2.5 text-[11.5px] leading-5 text-text-mid">
            {intercept?.matched_host?.startsWith('*.')
              ? t('resolveTest.intercept.wildcardMatch', { name: result.name })
              : t('resolveTest.intercept.exactMatch', { name: result.name })}
          </p>
        </div>
      </div>

      <div className="border-t border-divider px-5 py-5 sm:px-6">
        <DecisionOrder stages={stages} />
      </div>

      <div className="border-t border-divider bg-surface-container-low px-5 py-5 sm:px-6">
        <RawResponse result={result} />
      </div>
    </Card>
  )
}

/** An extension listed as enabled whose capture never ran. Without this the
 *  operator sees "enabled" on the extensions page and reasonably concludes the
 *  extension caused the gateway verdict — when in fact nothing it declared
 *  entered the capture table. */
function InertNotice({ host, moduleName, moduleID }: { host: string; moduleName: string; moduleID: string }) {
  const { t } = useTranslation()
  return (
    <div
      className="flex items-start gap-2.5 rounded-[12px] px-3.5 py-3"
      style={{
        background: 'var(--md-sys-color-warning-container)',
        color: 'var(--md-sys-color-on-warning-container)',
      }}
      role="status"
      data-testid="resolve-test-intercept-inert"
    >
      <WarningIcon
        className="mt-0.5 h-[18px] w-[18px] shrink-0"
        style={{ color: 'var(--md-sys-color-warning)' }}
        aria-hidden="true"
      />
      <span className="flex min-w-0 flex-col gap-1">
        <span className="text-[12px] font-medium">{t('resolveTest.intercept.notReadyTitle')}</span>
        <span className="text-[11.5px] leading-5">{t('resolveTest.intercept.notReadyBody', { host })}</span>
        <span className="flex items-center gap-1.5 text-[11px] opacity-80">
          <RuleIcon className="h-3.5 w-3.5" aria-hidden="true" />
          <span className="truncate font-mono">{moduleName || moduleID}</span>
        </span>
      </span>
    </div>
  )
}
