import { useCallback, useState, type CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { ArrowRightIcon, LanguageIcon, NetworkCheckIcon, ReceiptIcon, RuleIcon } from '../../components/icons'
import { Badge, Button, Card, Input, SectionLabel, StatusDot, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { ResolveTestResult } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { AttributionSection } from './AttributionSection'
import { attributionOf, decideResolveTest, EXAMPLE_DOMAINS, resolveSourceText } from './resolve-test-decision'

/** How many previous results stay available for comparison. Each run used to
 *  overwrite the last one outright, so comparing two domains meant running one,
 *  writing the answer down, and running the other. */
const HISTORY_LIMIT = 5

export default function ResolveTestPage() {
  const { t } = useTranslation()
  const [domain, setDomain] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [result, setResult] = useState<ResolveTestResult | null>(null)
  const [history, setHistory] = useState<ResolveTestResult[]>([])
  const [runSeq, setRunSeq] = useState(0)

  const show = useCallback((next: ResolveTestResult) => {
    setResult(next)
    setRunSeq((value) => value + 1)
  }, [])

  async function run(target: string) {
    const name = target.trim()
    if (!name || submitting) return
    setSubmitting(true)
    try {
      const next = await api.resolveTest(name)
      show(next)
      setHistory((previous) => [next, ...previous.filter((item) => item.name !== next.name)].slice(0, HISTORY_LIMIT))
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('errors.network'))
    } finally {
      setSubmitting(false)
    }
  }

  const decision = result ? decideResolveTest(result, t) : null
  const ruleId = result?.policy?.rule_id
  // The resolver answers with the FQDN's trailing dot; the log filters by
  // substring, so handing over the bare name matches either form and reads
  // like what the operator typed.
  const logQuery = result ? result.name.replace(/\.$/, '') : ''

  return (
    <div className="flex flex-col gap-4" data-testid="page-resolve-test">
      <Card variant="tonal" className="p-5 sm:p-6">
        <div className="mb-3 flex items-center gap-3">
          <div className="grid h-11 w-11 place-items-center rounded-pill bg-primary-container text-on-primary-container">
            <NetworkCheckIcon className="h-6 w-6" aria-hidden="true" />
          </div>
          <div>
            <h1 className="text-title font-medium text-text-strong">{t('resolveTest.domainLabel')}</h1>
            <p className="mt-0.5 text-label text-text-faint">{t('resolveTest.description')}</p>
          </div>
        </div>
        <div className="flex flex-col gap-2.5 sm:flex-row">
          <div className="relative flex-1">
            <LanguageIcon className="pointer-events-none absolute left-4 top-1/2 h-5 w-5 -translate-y-1/2 text-text-faint" aria-hidden="true" />
            <Input
              mono
              value={domain}
              onChange={(event) => setDomain(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === 'Enter') void run(domain)
              }}
              placeholder="example.com"
              className="h-field rounded-pill bg-card pl-12 text-title"
            />
          </div>
          <Button onClick={() => void run(domain)} disabled={submitting || !domain.trim()} className="h-field px-7">
            {submitting ? t('resolveTest.running') : t('resolveTest.run')}
          </Button>
        </div>
        {/* Six examples that happen to cover all five decisions are the fastest
            way to understand the whole split. They were 10.5px outlined
            footnotes under the input that said nothing about what they would
            hit. */}
        <div className="mt-5">
          <SectionLabel className="mb-2">{t('resolveTest.examplesTitle')}</SectionLabel>
          <div className="flex flex-wrap gap-2">
            {EXAMPLE_DOMAINS.map(({ domain: example, expectKey, slot }) => (
              <button
                key={example}
                type="button"
                onClick={() => {
                  setDomain(example)
                  void run(example)
                }}
                className="zds-state-layer flex min-h-field flex-col items-start gap-0.5 rounded-ctl border border-border bg-card px-3 py-2 text-left"
              >
                <span className="font-mono text-label font-medium text-text-strong">{example}</span>
                <span className="flex items-center gap-1.5 text-meta text-text-faint">
                  <StatusDot color={`var(--color-chart-${slot})`} square />
                  {t(expectKey)}
                </span>
              </button>
            ))}
          </div>
        </div>
        {history.length > 1 ? (
          <div className="mt-4 flex flex-wrap items-center gap-2" data-testid="resolve-test-history">
            <span className="text-meta text-text-faint">{t('resolveTest.recent')}</span>
            {history.map((item) => (
              <button
                key={item.name}
                type="button"
                onClick={() => show(item)}
                aria-pressed={item.name === result?.name}
                className={cn(
                  'zds-state-layer inline-flex h-chip items-center gap-1.5 rounded-pill border border-border px-3 font-mono text-meta',
                  item.name === result?.name ? 'bg-secondary-container text-on-secondary-container' : 'text-text-mid',
                )}
              >
                <StatusDot color={decideResolveTest(item, t).color} square />
                {item.name}
              </button>
            ))}
          </div>
        ) : null}
      </Card>

      {result && decision ? (
        <div key={runSeq} className="ds-rows-in flex flex-col gap-4" data-testid="resolve-test-result">
          <Card className="overflow-hidden">
            <div className="flex flex-wrap items-center gap-3 border-b border-border px-5 py-4 sm:px-6">
              <span className="min-w-0 truncate font-mono text-title font-medium text-text-strong">{result.name}</span>
              <ArrowRightIcon className="h-5 w-5 text-text-faint" aria-hidden="true" />
              <span className="inline-flex items-center gap-2 rounded-pill bg-secondary-container px-4 py-2 text-body font-medium text-on-secondary-container">
                <StatusDot color={decision.color} />
                {decision.label}
              </span>
              {/* Which source produced the verdict, stated at the top: an
                  extension capture and an operator rule are indistinguishable
                  from the verdict alone. */}
              {attributionOf(result) === 'intercept' ? (
                <Badge tone="indigo" className="ml-auto" data-testid="resolve-test-by-plugin">
                  {t('resolveTest.intercept.byPlugin')}
                </Badge>
              ) : attributionOf(result) === 'policy' ? (
                <span className="ml-auto font-mono text-meta tracking-[.06em] text-text-faint">
                  {t('resolveTest.intercept.sourcePolicy')}
                </span>
              ) : null}
            </div>

            <div className="grid gap-3 p-5 sm:grid-cols-3 sm:p-6">
              {[
                [
                  t('resolveTest.ruleLabel'),
                  attributionOf(result) === 'intercept'
                    ? t('resolveTest.intercept.ruleBasis')
                    : result.reason || '—',
                  false,
                ],
                // A terminal name-only verdict consults no upstream. Saying so
                // beats the old '—', which read as missing data rather than as
                // the finding it is — the probes card is absent for the same
                // reason and would otherwise look like something went wrong.
                [
                  t('resolveTest.sourceLabel'),
                  result.probes?.length ? resolveSourceText(result, t) : t('resolveTest.intercept.noUpstream'),
                  false,
                ],
                [t('resolveTest.answerLabel'), result.client_ips?.length ? result.client_ips.join(', ') : t('resolveTest.blocked'), true],
              ].map(([label, value, mono]) => (
                <div key={String(label)} className="rounded-card bg-surface-container-low p-4">
                  <div className="mb-2 text-meta font-medium text-text-faint">{label}</div>
                  <div className={mono ? 'break-all font-mono text-label font-medium text-text-strong' : 'text-body font-medium text-text-strong'}>{value}</div>
                </div>
              ))}
            </div>

            {/* The chain used to end here. `reason` already identifies exactly
                one rule and the log page already filters by name, so both
                destinations existed — there was just no way to walk to them. */}
            <div className="flex flex-wrap gap-2 border-t border-border px-5 pb-5 sm:px-6" data-testid="resolve-test-actions">
              {ruleId ? (
                <Link
                  to={`/policy-rules?highlight=${encodeURIComponent(ruleId)}`}
                  className="zds-state-layer mt-5 inline-flex h-field w-full items-center gap-2 rounded-pill bg-primary-container px-4 text-label font-medium text-on-primary-container md:h-ctl md:w-auto"
                >
                  <RuleIcon className="h-4 w-4" aria-hidden="true" />
                  {t('resolveTest.viewMatchedRule')}
                </Link>
              ) : null}
              <Link
                to={`/logs?q=${encodeURIComponent(logQuery)}`}
                className="zds-state-layer mt-5 inline-flex h-field w-full items-center gap-2 rounded-pill border border-border px-4 text-label font-medium text-text-mid md:h-ctl md:w-auto"
              >
                <ReceiptIcon className="h-4 w-4" aria-hidden="true" />
                {t('resolveTest.filterInLogs')}
              </Link>
            </div>

            <div className="border-t border-border px-5 py-5 sm:px-6">
              <SectionLabel className="mb-4">{t('resolveTest.decisionPath')}</SectionLabel>
              {/* A single step is not a path. The rail's connector width goes to
                  zero at one node while the element still draws, so a lone
                  generic step rendered as a track with nothing on it. */}
              {decision.steps.length > 1 ? (
                <div
                  className="zds-trace-rail"
                  style={{ '--trace-steps': decision.steps.length } as CSSProperties}
                >
                  {decision.steps.map((step, index) => (
                    <div key={`${step}-${index}`} className="zds-trace-node">
                      <span className="zds-trace-dot font-mono text-meta font-semibold">{index + 1}</span>
                      <span className="max-w-[240px] text-label leading-5 text-text-mid">{step}</span>
                    </div>
                  ))}
                </div>
              ) : (
                <p className="rounded-card bg-surface-container-low p-4 text-label leading-5 text-text-mid" data-testid="resolve-test-single-step">
                  {decision.steps[0]}
                </p>
              )}
            </div>

            {/* Policy attribution has no extension to introduce, so its
                evidence belongs inside the result card rather than in one of
                its own. */}
            {attributionOf(result) !== 'intercept' ? <AttributionSection result={result} /> : null}
          </Card>

          {attributionOf(result) === 'intercept' ? <AttributionSection result={result} /> : null}

          {result.probes?.length ? (
            <Card className="p-5 sm:p-6">
              <div className="mb-4 flex items-center justify-between gap-3">
                <h2 className="text-title font-medium text-text-strong">{t('resolveTest.probes')}</h2>
                <Badge tone="blue">{t('resolveTest.concurrent')}</Badge>
              </div>
              <div className="grid gap-3 md:grid-cols-2">
                {result.probes.map((probe, index) => (
                  // Colour is success or failure and nothing else. It used to
                  // read err→red / selected→blue / everything-else→green, so a
                  // probe that answered but was not adopted looked healthier
                  // than the one that was. Adoption is the filled border plus
                  // the badge already saying it.
                  <div
                    key={`${probe.group}-${probe.server}-${index}`}
                    className={cn(
                      'rounded-card p-4',
                      probe.selected
                        ? 'border-2 border-primary bg-card'
                        : 'border border-transparent bg-surface-container-low',
                    )}
                  >
                    <div className="flex items-center gap-2">
                      <StatusDot color={probe.err ? 'var(--color-red)' : 'var(--color-green)'} />
                      <span className="font-mono text-label font-medium text-text-strong">{probe.server}</span>
                      <span className="ml-auto font-mono text-meta text-text-faint">{probe.duration_ms.toFixed(1)}ms</span>
                    </div>
                    <div className="mt-2 flex flex-wrap items-center gap-2 text-meta text-text-faint">
                      <span>{probe.group}</span><span>·</span><span>{probe.proto.toUpperCase()}</span>
                      {probe.selected ? <Badge tone="blue" className="ml-auto">{t('resolveTest.selected')}</Badge> : null}
                    </div>
                    {probe.err ? <div className="mt-2 text-meta text-red">{probe.err}</div> : null}
                  </div>
                ))}
              </div>
            </Card>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
