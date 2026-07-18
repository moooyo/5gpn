import { useState, type CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import { ArrowRightIcon, LanguageIcon, NetworkCheckIcon } from '../../components/icons'
import { Badge, Button, Card, Input, SectionLabel, StatusDot, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { ResolveTestResult } from '../../lib/api/types'
import { decideResolveTest, EXAMPLE_DOMAINS, resolveSourceText } from './resolve-test-decision'

export default function ResolveTestPage() {
  const { t } = useTranslation()
  const [domain, setDomain] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [result, setResult] = useState<ResolveTestResult | null>(null)
  const [runSeq, setRunSeq] = useState(0)

  async function run(target: string) {
    const name = target.trim()
    if (!name || submitting) return
    setSubmitting(true)
    try {
      setResult(await api.resolveTest(name))
      setRunSeq((value) => value + 1)
    } catch (error) {
      toast.error(error instanceof Error ? error.message : t('errors.network'))
    } finally {
      setSubmitting(false)
    }
  }

  const decision = result ? decideResolveTest(result, t) : null

  return (
    <div className="flex flex-col gap-4" data-testid="page-resolve-test">
      <Card variant="tonal" className="p-5 sm:p-6">
        <div className="mb-3 flex items-center gap-3">
          <div className="grid h-11 w-11 place-items-center rounded-full bg-primary-container text-on-primary-container">
            <NetworkCheckIcon className="h-6 w-6" aria-hidden="true" />
          </div>
          <div>
            <h1 className="text-[16px] font-medium text-text-strong">{t('resolveTest.domainLabel')}</h1>
            <p className="mt-0.5 text-[11.5px] text-text-faint">{t('resolveTest.description')}</p>
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
              className="h-14 rounded-full bg-card pl-12 text-[15px]"
            />
          </div>
          <Button onClick={() => void run(domain)} disabled={submitting || !domain.trim()} className="h-14 px-7">
            {submitting ? t('resolveTest.running') : t('resolveTest.run')}
          </Button>
        </div>
        <div className="mt-4 flex flex-wrap items-center gap-2">
          <span className="text-[11px] text-text-faint">{t('resolveTest.examples')}</span>
          {EXAMPLE_DOMAINS.map((example) => (
            <button
              key={example}
              type="button"
              onClick={() => {
                setDomain(example)
                void run(example)
              }}
              className="zds-state-layer rounded-[8px] border border-border bg-transparent px-2.5 py-1.5 font-mono text-[10.5px] text-text-mid"
            >
              {example}
            </button>
          ))}
        </div>
      </Card>

      {result && decision ? (
        <div key={runSeq} className="ds-rows-in flex flex-col gap-4">
          <Card className="overflow-hidden">
            <div className="flex flex-wrap items-center gap-3 border-b border-border px-5 py-4 sm:px-6">
              <span className="min-w-0 truncate font-mono text-[15px] font-medium text-text-strong">{result.name}</span>
              <ArrowRightIcon className="h-5 w-5 text-text-faint" aria-hidden="true" />
              <span className="inline-flex items-center gap-2 rounded-full bg-secondary-container px-4 py-2 text-[13px] font-medium text-on-secondary-container">
                <StatusDot color={decision.color} />
                {decision.label}
              </span>
            </div>

            <div className="grid gap-3 p-5 sm:grid-cols-3 sm:p-6">
              {[
                [t('resolveTest.ruleLabel'), result.reason || '—', false],
                [t('resolveTest.sourceLabel'), resolveSourceText(result, t), false],
                [t('resolveTest.answerLabel'), result.client_ips?.length ? result.client_ips.join(', ') : t('resolveTest.blocked'), true],
              ].map(([label, value, mono]) => (
                <div key={String(label)} className="rounded-[14px] bg-surface-container-low p-4">
                  <div className="mb-2 text-[11px] font-medium text-text-faint">{label}</div>
                  <div className={mono ? 'break-all font-mono text-[12px] font-medium text-text-strong' : 'text-[13px] font-medium text-text-strong'}>{value}</div>
                </div>
              ))}
            </div>

            <div className="border-t border-border px-5 py-5 sm:px-6">
              <SectionLabel className="mb-4">{t('resolveTest.decisionPath')}</SectionLabel>
              <div
                className="zds-trace-rail"
                style={{ '--trace-steps': decision.steps.length } as CSSProperties}
              >
                {decision.steps.map((step, index) => (
                  <div key={`${step}-${index}`} className="zds-trace-node">
                    <span className="zds-trace-dot font-mono text-[11px] font-semibold">{index + 1}</span>
                    <span className="max-w-[240px] text-[11.5px] leading-5 text-text-mid">{step}</span>
                  </div>
                ))}
              </div>
            </div>
          </Card>

          {result.probes?.length ? (
            <Card className="p-5 sm:p-6">
              <div className="mb-4 flex items-center justify-between gap-3">
                <h2 className="text-[15px] font-medium text-text-strong">{t('resolveTest.probes')}</h2>
                <Badge tone="blue">{t('resolveTest.concurrent')}</Badge>
              </div>
              <div className="grid gap-3 md:grid-cols-2">
                {result.probes.map((probe, index) => (
                  <div key={`${probe.group}-${probe.server}-${index}`} className="rounded-[14px] bg-surface-container-low p-4">
                    <div className="flex items-center gap-2">
                      <StatusDot color={probe.err ? 'var(--color-red)' : probe.selected ? 'var(--color-primary)' : 'var(--color-green)'} />
                      <span className="font-mono text-[12px] font-medium text-text-strong">{probe.server}</span>
                      <span className="ml-auto font-mono text-[10.5px] text-text-faint">{probe.duration_ms.toFixed(1)}ms</span>
                    </div>
                    <div className="mt-2 flex flex-wrap items-center gap-2 text-[10.5px] text-text-faint">
                      <span>{probe.group}</span><span>·</span><span>{probe.proto.toUpperCase()}</span>
                      {probe.selected ? <Badge tone="blue" className="ml-auto">{t('resolveTest.selected')}</Badge> : null}
                    </div>
                    {probe.err ? <div className="mt-2 text-[11px] text-red">{probe.err}</div> : null}
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
