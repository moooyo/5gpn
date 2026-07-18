import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { Apple, CheckCircle2, Download, ExternalLink, KeyRound, ScanLine, ShieldCheck, Smartphone } from 'lucide-react'
import { encode } from 'uqr'
import { Card, CardBody, CardHeader } from '../../components/ds'
import { useStatus } from '../../lib/StatusContext'

export const IOS_PROFILE_PATH = '/ios/ios-dot.mobileconfig'
export const INTERCEPT_CA_PROFILE_PATH = '/ios/ios-intercept-ca.mobileconfig'

export function profileURL(origin = window.location.origin): string {
  return new URL(IOS_PROFILE_PATH, origin).toString()
}

export function interceptCAProfileURL(origin = window.location.origin): string {
  return new URL(INTERCEPT_CA_PROFILE_PATH, origin).toString()
}

function QRCode({ value, label }: { value: string; label: string }) {
  const { data, size } = useMemo(() => encode(value, { ecc: 'M' }), [value])
  const border = 4
  const path = useMemo(() => {
    const cells: string[] = []
    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        if (data[y]?.[x]) cells.push(`M${x + border} ${y + border}h1v1h-1z`)
      }
    }
    return cells.join('')
  }, [data, size])

  return (
    <svg
      viewBox={`0 0 ${size + border * 2} ${size + border * 2}`}
      role="img"
      aria-label={label}
      className="h-auto w-full rounded-[12px] bg-white"
      shapeRendering="crispEdges"
    >
      <rect width="100%" height="100%" fill="#fff" />
      <path d={path} fill="#101828" />
    </svg>
  )
}

function StepList({ steps }: { steps: Array<{ title: string; body: string }> }) {
  return (
    <ol className="flex flex-col gap-3.5">
      {steps.map((step, index) => (
        <li key={step.title} className="flex items-start gap-3">
          <span className="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-primary/10 font-mono text-[11px] font-bold text-primary">
            {index + 1}
          </span>
          <div className="min-w-0 pt-0.5">
            <div className="text-[12.5px] font-bold text-text-strong">{step.title}</div>
            <div className="mt-0.5 text-[11.5px] leading-relaxed text-text-soft">{step.body}</div>
          </div>
        </li>
      ))}
    </ol>
  )
}

export default function SetupGuidePage() {
  const { t } = useTranslation()
  const { status, loading } = useStatus()
  const downloadURL = profileURL()
  const caDownloadURL = interceptCAProfileURL()
  const dotDomain = status?.dot_domain

  const iosSteps = [
    { title: t('setupGuide.ios.step1Title'), body: t('setupGuide.ios.step1Body') },
    { title: t('setupGuide.ios.step2Title'), body: t('setupGuide.ios.step2Body') },
    { title: t('setupGuide.ios.step3Title'), body: t('setupGuide.ios.step3Body') },
    { title: t('setupGuide.ios.step4Title'), body: t('setupGuide.ios.step4Body') },
  ]
  const androidSteps = [
    { title: t('setupGuide.android.step1Title'), body: t('setupGuide.android.step1Body') },
    { title: t('setupGuide.android.step2Title'), body: t('setupGuide.android.step2Body') },
    { title: t('setupGuide.android.step3Title'), body: t('setupGuide.android.step3Body') },
    { title: t('setupGuide.android.step4Title'), body: t('setupGuide.android.step4Body') },
  ]
  const caSteps = [
    { title: t('setupGuide.interceptCA.step1Title'), body: t('setupGuide.interceptCA.step1Body') },
    { title: t('setupGuide.interceptCA.step2Title'), body: t('setupGuide.interceptCA.step2Body') },
    { title: t('setupGuide.interceptCA.step3Title'), body: t('setupGuide.interceptCA.step3Body') },
    { title: t('setupGuide.interceptCA.step4Title'), body: t('setupGuide.interceptCA.step4Body') },
  ]

  return (
    <div className="flex max-w-[1180px] flex-col gap-4" data-testid="page-setup-guide">
      <Card className="overflow-hidden p-0">
        <div className="flex flex-col gap-4 bg-[linear-gradient(135deg,var(--color-primary),var(--color-primary-2))] p-5 text-white sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-3.5">
            <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-[11px] bg-white/15">
              <ShieldCheck className="h-5 w-5" aria-hidden="true" />
            </span>
            <div>
              <h1 className="text-[17px] font-extrabold">{t('setupGuide.title')}</h1>
              <p className="mt-1 max-w-[700px] text-[12px] leading-relaxed text-white/80">{t('setupGuide.intro')}</p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2 rounded-[9px] border border-white/20 bg-white/10 px-3 py-2 text-[11px] font-semibold">
            <CheckCircle2 className="h-4 w-4" aria-hidden="true" />
            {t('setupGuide.dotBadge')}
          </div>
        </div>
      </Card>

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1.2fr)_minmax(340px,.8fr)]">
        <Card className="overflow-hidden p-0">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <Apple className="h-[18px] w-[18px] text-text-soft" aria-hidden="true" />
                {t('setupGuide.ios.title')}
              </span>
            }
          >
            <span className="rounded-full bg-green/10 px-2.5 py-1 text-[10.5px] font-bold text-green">
              {t('setupGuide.ios.signed')}
            </span>
          </CardHeader>
          <CardBody className="grid gap-6 sm:grid-cols-[190px_minmax(0,1fr)]">
            <div className="flex flex-col gap-3">
              <a
                href={downloadURL}
                aria-label={t('setupGuide.ios.scanLabel')}
                className="rounded-[14px] border border-border bg-white p-2.5 shadow-sm transition-transform hover:scale-[1.01]"
              >
                <QRCode value={downloadURL} label={t('setupGuide.ios.qrAlt')} />
              </a>
              <div className="flex items-start gap-2 text-[11px] leading-relaxed text-text-soft">
                <ScanLine className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
                {t('setupGuide.ios.scanHint')}
              </div>
            </div>

            <div className="flex min-w-0 flex-col gap-5">
              <div>
                <p className="text-[12px] leading-relaxed text-text-soft">{t('setupGuide.ios.description')}</p>
                <a
                  href={downloadURL}
                  className="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-[10px] bg-[linear-gradient(135deg,var(--color-primary-2),var(--color-primary))] px-4 py-2.5 text-[13px] font-bold text-white shadow-[0_8px_18px_-8px_rgba(37,99,235,.6)] sm:w-auto"
                >
                  <Download className="h-4 w-4" aria-hidden="true" />
                  {t('setupGuide.ios.download')}
                </a>
                <div className="mt-2 break-all font-mono text-[10px] leading-relaxed text-text-faint">{downloadURL}</div>
              </div>
              <StepList steps={iosSteps} />
              <div className="rounded-[10px] border border-amber-400/30 bg-amber-400/10 p-3 text-[11px] leading-relaxed text-text-mid">
                {t('setupGuide.ios.note')}
              </div>
            </div>
          </CardBody>
        </Card>

        <Card className="overflow-hidden p-0">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <Smartphone className="h-[18px] w-[18px] text-text-soft" aria-hidden="true" />
                {t('setupGuide.android.title')}
              </span>
            }
          >
            <span className="rounded-full bg-primary/10 px-2.5 py-1 text-[10.5px] font-bold text-primary">Android 9+</span>
          </CardHeader>
          <CardBody className="flex flex-col gap-5">
            <p className="text-[12px] leading-relaxed text-text-soft">{t('setupGuide.android.description')}</p>
            <div>
              <div className="mb-2 flex items-center gap-1.5 text-[10.5px] font-semibold text-text-faint">
                <KeyRound className="h-3.5 w-3.5" aria-hidden="true" />
                {t('setupGuide.android.hostnameLabel')}
              </div>
              <div className="min-h-11 break-all rounded-[10px] border border-input-border bg-input px-3.5 py-3 font-mono text-[12.5px] font-semibold text-text-strong" data-testid="dot-domain">
                {dotDomain ?? (loading ? t('common.loading') : t('setupGuide.android.hostnameMissing'))}
              </div>
              <div className="mt-2 text-[10.5px] leading-relaxed text-text-faint">{t('setupGuide.android.hostnameHint')}</div>
            </div>
            <StepList steps={androidSteps} />
            <div className="flex items-start gap-2 rounded-[10px] border border-border bg-input p-3 text-[11px] leading-relaxed text-text-mid">
              <ExternalLink className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary" aria-hidden="true" />
              {t('setupGuide.android.vendorNote')}
            </div>
          </CardBody>
        </Card>
      </div>

      <Card className="overflow-hidden p-0" data-testid="intercept-ca-guide">
        <CardHeader
          title={
            <span className="flex items-center gap-2">
              <ShieldCheck className="h-[18px] w-[18px] text-primary" aria-hidden="true" />
              {t('setupGuide.interceptCA.title')}
            </span>
          }
        >
          <span className="rounded-full bg-primary/10 px-2.5 py-1 text-[10.5px] font-bold text-primary">
            {t('setupGuide.interceptCA.shared')}
          </span>
        </CardHeader>
        <CardBody className="grid gap-6 sm:grid-cols-[190px_minmax(0,1fr)] lg:grid-cols-[190px_minmax(0,1fr)_minmax(280px,.72fr)]">
          <div className="flex flex-col gap-3">
            <a
              href={caDownloadURL}
              aria-label={t('setupGuide.interceptCA.scanLabel')}
              className="rounded-[14px] border border-border bg-white p-2.5 shadow-sm transition-transform hover:scale-[1.01]"
            >
              <QRCode value={caDownloadURL} label={t('setupGuide.interceptCA.qrAlt')} />
            </a>
            <div className="flex items-start gap-2 text-[11px] leading-relaxed text-text-soft">
              <ScanLine className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
              {t('setupGuide.interceptCA.scanHint')}
            </div>
          </div>

          <div className="flex min-w-0 flex-col gap-5">
            <div>
              <p className="text-[12px] leading-relaxed text-text-soft">{t('setupGuide.interceptCA.description')}</p>
              <a
                href={caDownloadURL}
                className="mt-3 inline-flex w-full items-center justify-center gap-2 rounded-[10px] bg-[linear-gradient(135deg,var(--color-primary-2),var(--color-primary))] px-4 py-2.5 text-[13px] font-bold text-white shadow-[0_8px_18px_-8px_rgba(37,99,235,.6)] sm:w-auto"
              >
                <Download className="h-4 w-4" aria-hidden="true" />
                {t('setupGuide.interceptCA.download')}
              </a>
              <div className="mt-2 break-all font-mono text-[10px] leading-relaxed text-text-faint">{caDownloadURL}</div>
            </div>
            <div className="rounded-[10px] border border-primary/20 bg-primary/5 p-3 text-[11px] leading-relaxed text-text-mid">
              {t('setupGuide.interceptCA.sharedHint')}
            </div>
          </div>

          <div className="flex flex-col gap-4 border-divider lg:border-l lg:pl-6">
            <StepList steps={caSteps} />
            <div className="rounded-[10px] border border-amber-400/30 bg-amber-400/10 p-3 text-[11px] leading-relaxed text-text-mid">
              {t('setupGuide.interceptCA.note')}
            </div>
          </div>
        </CardBody>
      </Card>

      <Card className="p-4">
        <div className="flex items-start gap-3">
          <Smartphone className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" />
          <div>
            <div className="text-[12.5px] font-bold text-text-strong">{t('setupGuide.requirementsTitle')}</div>
            <div className="mt-1 text-[11.5px] leading-relaxed text-text-soft">{t('setupGuide.requirementsBody')}</div>
          </div>
        </div>
      </Card>
    </div>
  )
}
