import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { ArrowRight, Globe } from 'lucide-react'
import { Button, Card, Input, SectionLabel, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { ResolveTestResult } from '../../lib/api/types'
import { decideResolveTest, EXAMPLE_DOMAINS, resolveSourceText } from './resolve-test-decision'

export default function ResolveTestPage() {
  const { t } = useTranslation()
  const [domain, setDomain] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [result, setResult] = useState<ResolveTestResult | null>(null)
  // Bumped on every completed test so the result card can be keyed by it and
  // re-play its enter animation — even when the same domain is re-run.
  const [runSeq, setRunSeq] = useState(0)

  async function run(target: string) {
    const name = target.trim()
    if (!name || submitting) return
    setSubmitting(true)
    try {
      const res = await api.resolveTest(name)
      setResult(res)
      setRunSeq((n) => n + 1)
    } catch (err) {
      toast.error(err instanceof Error ? err.message : t('errors.network'))
    } finally {
      setSubmitting(false)
    }
  }

  function handleExampleClick(example: string) {
    setDomain(example)
    void run(example)
  }

  const decision = result ? decideResolveTest(result, t) : null

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-resolve-test">
      <Card className="p-[18px]">
        <div className="mb-2 text-[11px] font-semibold text-text-mid">{t('resolveTest.domainLabel')}</div>
        <div className="flex gap-2.5">
          <div className="relative flex-1">
            <Globe
              className="pointer-events-none absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2 text-text-faint"
              aria-hidden="true"
            />
            <Input
              mono
              value={domain}
              onChange={(e) => setDomain(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === 'Enter') void run(domain)
              }}
              placeholder="example.com"
              className="w-full pl-9"
            />
          </div>
          <Button onClick={() => void run(domain)} disabled={submitting || !domain.trim()}>
            {submitting ? t('resolveTest.running') : t('resolveTest.run')}
          </Button>
        </div>
        <div className="mt-3 flex flex-wrap items-center gap-2">
          <span className="text-[11px] text-text-faint">{t('resolveTest.examples')}</span>
          {EXAMPLE_DOMAINS.map((example) => (
            <button
              key={example}
              type="button"
              onClick={() => handleExampleClick(example)}
              className="rounded-[7px] border border-border bg-input px-2.5 py-1 font-mono text-[11px] text-text-mid transition-colors hover:bg-input-border"
            >
              {example}
            </button>
          ))}
        </div>
      </Card>

      {result && decision ? (
        <Card key={runSeq} className="ds-rows-in p-[18px]">
          <div className="flex flex-wrap items-center gap-3 border-b border-divider pb-4">
            <span className="font-mono text-[14px] font-semibold text-text-strong">{result.name}</span>
            <ArrowRight className="h-4 w-4 text-text-faint" aria-hidden="true" />
            <span
              className="inline-flex items-center gap-1.5 rounded-[8px] border border-border bg-thead px-3.5 py-1.5 text-[13px] font-bold"
              style={{ color: decision.color }}
            >
              <span className="inline-block h-2 w-2 rounded-full" style={{ background: decision.color }} />
              {decision.label}
            </span>
          </div>

          <div className="my-4 grid grid-cols-3 gap-3">
            <div className="rounded-[10px] bg-input p-3">
              <div className="mb-1.5 text-[10.5px] font-semibold text-text-faint">{t('resolveTest.ruleLabel')}</div>
              <div className="text-[12.5px] font-bold text-text-strong">{result.reason || '—'}</div>
            </div>
            <div className="rounded-[10px] bg-input p-3">
              <div className="mb-1.5 text-[10.5px] font-semibold text-text-faint">{t('resolveTest.sourceLabel')}</div>
              <div className="text-[12.5px] font-bold text-text-strong">{resolveSourceText(result, t)}</div>
            </div>
            <div className="rounded-[10px] bg-input p-3">
              <div className="mb-1.5 text-[10.5px] font-semibold text-text-faint">{t('resolveTest.answerLabel')}</div>
              <div className="font-mono text-[12.5px] font-bold text-text-strong">
                {result.client_ips && result.client_ips.length > 0 ? result.client_ips.join(', ') : t('resolveTest.blocked')}
              </div>
            </div>
          </div>

          <SectionLabel className="mb-2.5">{t('resolveTest.decisionPath')}</SectionLabel>
          <div className="flex flex-col">
            {decision.steps.map((step, i) => (
              <div key={i} className="flex items-start gap-2.5 pb-3.5 last:pb-0">
                <span
                  className="flex h-[22px] w-[22px] shrink-0 items-center justify-center rounded-full font-mono text-[11px] font-bold text-white"
                  style={{ background: decision.color }}
                >
                  {i + 1}
                </span>
                <div className="pt-0.5 text-[12.5px] leading-relaxed text-text-mid">{step}</div>
              </div>
            ))}
          </div>
        </Card>
      ) : null}
    </div>
  )
}
