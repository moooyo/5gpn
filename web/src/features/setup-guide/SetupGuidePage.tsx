import { useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import { CheckCircleIcon, DownloadIcon, ExternalLinkIcon, IosIcon, KeyIcon, QrCodeIcon, ShieldLockIcon, SmartphoneIcon, VerifiedIcon } from '../../components/icons'
import { encode } from 'uqr'
import { Badge, Button, Card, CardBody, CardHeader } from '../../components/ds'
import { useStatus } from '../../lib/StatusContext'
import { api } from '../../lib/api/client'
import type { MITMSettingsView } from '../../lib/api/types'
import { useMITMTrustAcknowledgement } from '../../lib/mitmTrust'

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
          <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-secondary-container font-mono text-[11px] font-medium text-on-secondary-container">
            {index + 1}
          </span>
          <div className="min-w-0 pt-0.5">
            <div className="text-[12.5px] font-medium text-text-strong">{step.title}</div>
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
  const [mitmSettings, setMITMSettings] = useState<MITMSettingsView | null>(null)
  const { acknowledged, setAcknowledged } = useMITMTrustAcknowledgement()
  const downloadURL = profileURL()
  const caDownloadURL = interceptCAProfileURL()
  const dotDomain = status?.dot_domain

  useEffect(() => {
    let cancelled = false
    void api.getMITMSettings().then((value) => {
      if (!cancelled) setMITMSettings(value)
    }).catch(() => undefined)
    return () => { cancelled = true }
  }, [])

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
    { title: t('setupGuide.interceptCA.step5Title'), body: t('setupGuide.interceptCA.step5Body') },
  ]

  return (
    <div className="flex flex-col gap-4" data-testid="page-setup-guide">
      <Card variant="hero" className="overflow-hidden p-0">
        <div className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between sm:p-6">
          <div className="flex items-start gap-3.5">
            <span className="grid h-12 w-12 shrink-0 place-items-center rounded-full bg-[rgb(255_255_255_/_36%)]">
              <ShieldLockIcon className="h-6 w-6" aria-hidden="true" />
            </span>
            <div>
              <h1 className="text-[20px] font-medium">{t('setupGuide.title')}</h1>
              <p className="mt-1 max-w-[700px] text-[12.5px] leading-relaxed opacity-80">{t('setupGuide.intro')}</p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2 rounded-full bg-[rgb(255_255_255_/_30%)] px-4 py-2 text-[11.5px] font-medium">
            <CheckCircleIcon className="h-4 w-4" aria-hidden="true" />
            {t('setupGuide.dotBadge')}
          </div>
        </div>
      </Card>

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1.2fr)_minmax(340px,.8fr)]">
        <Card className="overflow-hidden p-0">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <IosIcon className="h-[20px] w-[20px] text-text-soft" aria-hidden="true" />
                {t('setupGuide.ios.title')}
              </span>
            }
          >
            <span className="rounded-full bg-[var(--md-sys-color-success-container)] px-3 py-1 text-[10.5px] font-medium text-[var(--md-sys-color-on-success-container)]">
              {t('setupGuide.ios.signed')}
            </span>
          </CardHeader>
          <CardBody className="grid gap-6 sm:grid-cols-[190px_minmax(0,1fr)]">
            <div className="flex flex-col gap-3">
              <a
                href={downloadURL}
                aria-label={t('setupGuide.ios.scanLabel')}
                className="rounded-[18px] bg-white p-3 shadow-[var(--md-sys-elevation-1)] transition-transform hover:scale-[1.01]"
              >
                <QRCode value={downloadURL} label={t('setupGuide.ios.qrAlt')} />
              </a>
              <div className="flex items-start gap-2 text-[11px] leading-relaxed text-text-soft">
                <QrCodeIcon className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
                {t('setupGuide.ios.scanHint')}
              </div>
            </div>

            <div className="flex min-w-0 flex-col gap-5">
              <div>
                <p className="text-[12px] leading-relaxed text-text-soft">{t('setupGuide.ios.description')}</p>
                <a
                  href={downloadURL}
                  className="zds-state-layer mt-3 inline-flex h-10 w-full items-center justify-center gap-2 rounded-full bg-primary px-5 text-[13px] font-medium text-[var(--md-sys-color-on-primary)] sm:w-auto"
                >
                  <DownloadIcon className="h-4 w-4" aria-hidden="true" />
                  {t('setupGuide.ios.download')}
                </a>
                <div className="mt-2 break-all font-mono text-[10px] leading-relaxed text-text-faint">{downloadURL}</div>
              </div>
              <StepList steps={iosSteps} />
              <div className="rounded-[14px] bg-[var(--md-sys-color-warning-container)] p-3.5 text-[11px] leading-relaxed text-[var(--md-sys-color-on-warning-container)]">
                {t('setupGuide.ios.note')}
              </div>
            </div>
          </CardBody>
        </Card>

        <Card className="overflow-hidden p-0">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <SmartphoneIcon className="h-[20px] w-[20px] text-text-soft" aria-hidden="true" />
                {t('setupGuide.android.title')}
              </span>
            }
          >
            <span className="rounded-full bg-primary-container px-3 py-1 text-[10.5px] font-medium text-on-primary-container">Android 9+</span>
          </CardHeader>
          <CardBody className="flex flex-col gap-5">
            <p className="text-[12px] leading-relaxed text-text-soft">{t('setupGuide.android.description')}</p>
            <div>
              <div className="mb-2 flex items-center gap-1.5 text-[10.5px] font-semibold text-text-faint">
                <KeyIcon className="h-4 w-4" aria-hidden="true" />
                {t('setupGuide.android.hostnameLabel')}
              </div>
              <div className="min-h-11 break-all rounded-[14px] bg-surface-container-low px-4 py-3 font-mono text-[12.5px] font-medium text-text-strong" data-testid="dot-domain">
                {dotDomain ?? (loading ? t('common.loading') : t('setupGuide.android.hostnameMissing'))}
              </div>
              <div className="mt-2 text-[10.5px] leading-relaxed text-text-faint">{t('setupGuide.android.hostnameHint')}</div>
            </div>
            <StepList steps={androidSteps} />
            <div className="flex items-start gap-2 rounded-[14px] bg-surface-container-low p-3.5 text-[11px] leading-relaxed text-text-mid">
              <ExternalLinkIcon className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
              {t('setupGuide.android.vendorNote')}
            </div>
          </CardBody>
        </Card>
      </div>

      <Card className="overflow-hidden p-0" data-testid="intercept-ca-guide">
        <CardHeader
          title={
            <span className="flex items-center gap-2">
              <VerifiedIcon className="h-[20px] w-[20px] text-primary" aria-hidden="true" />
              {t('setupGuide.interceptCA.title')}
            </span>
          }
        >
          <span className="rounded-full bg-primary-container px-3 py-1 text-[10.5px] font-medium text-on-primary-container">
            {t('setupGuide.interceptCA.shared')}
          </span>
        </CardHeader>
        <div className="grid gap-3 border-b border-divider px-5 py-3.5 sm:grid-cols-2">
          <div className="flex min-w-0 items-center gap-3 rounded-[16px] bg-surface-container-low px-4 py-3.5">
            <span className={acknowledged ? 'grid h-9 w-9 shrink-0 place-items-center rounded-full bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : 'grid h-9 w-9 shrink-0 place-items-center rounded-full bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]'}>
              {acknowledged ? <CheckCircleIcon className="h-5 w-5" aria-hidden="true" /> : <ShieldLockIcon className="h-5 w-5" aria-hidden="true" />}
            </span>
            <div className="min-w-0 flex-1">
              <div className="text-[12px] font-medium text-text-strong">{t('setupGuide.interceptCA.clientTrust')}</div>
              <div className="mt-0.5 text-[10.5px] leading-4 text-text-faint">{t(acknowledged ? 'setupGuide.interceptCA.locallyConfirmed' : 'setupGuide.interceptCA.notConfirmed')}</div>
            </div>
            <Badge className="shrink-0" tone={acknowledged ? 'green' : 'amber'}>{acknowledged ? t('setupGuide.interceptCA.complete') : t('setupGuide.interceptCA.required')}</Badge>
          </div>
          <div className="flex min-w-0 items-center gap-3 rounded-[16px] bg-surface-container-low px-4 py-3.5">
            <span className={mitmSettings?.enabled ? 'grid h-9 w-9 shrink-0 place-items-center rounded-full bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]' : 'grid h-9 w-9 shrink-0 place-items-center rounded-full bg-[var(--md-sys-color-warning-container)] text-[var(--md-sys-color-on-warning-container)]'}>
              <ShieldLockIcon className="h-5 w-5" aria-hidden="true" />
            </span>
            <div className="min-w-0 flex-1">
              <div className="text-[12px] font-medium text-text-strong">{t('setupGuide.interceptCA.gatewayMaster')}</div>
              <div className="mt-0.5 text-[10.5px] leading-4 text-text-faint">{t(mitmSettings?.enabled ? 'setupGuide.interceptCA.masterEnabled' : 'setupGuide.interceptCA.masterDisabled')}</div>
            </div>
            <div className="flex shrink-0 flex-col items-end gap-1.5">
              <Badge tone={mitmSettings?.enabled ? 'green' : 'amber'}>{mitmSettings?.enabled ? t('settings.mitmRunning') : t('settings.mitmStopped')}</Badge>
              {!mitmSettings?.enabled ? (
                <Link to="/settings" className="zds-state-layer rounded-full px-2.5 py-1 text-[10.5px] font-medium text-primary">
                  {t('setupGuide.interceptCA.openMITMSettings')}
                </Link>
              ) : null}
            </div>
          </div>
        </div>
        <CardBody className="grid gap-6 sm:grid-cols-[190px_minmax(0,1fr)] lg:grid-cols-[190px_minmax(0,1fr)_minmax(280px,.72fr)]">
          <div className="flex flex-col gap-3">
            <a
              href={caDownloadURL}
              aria-label={t('setupGuide.interceptCA.scanLabel')}
              className="rounded-[18px] bg-white p-3 shadow-[var(--md-sys-elevation-1)] transition-transform hover:scale-[1.01]"
            >
              <QRCode value={caDownloadURL} label={t('setupGuide.interceptCA.qrAlt')} />
            </a>
            <div className="flex items-start gap-2 text-[11px] leading-relaxed text-text-soft">
              <QrCodeIcon className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
              {t('setupGuide.interceptCA.scanHint')}
            </div>
          </div>

          <div className="flex min-w-0 flex-col gap-5">
            <div>
              <p className="text-[12px] leading-relaxed text-text-soft">{t('setupGuide.interceptCA.description')}</p>
              <a
                href={caDownloadURL}
                className="zds-state-layer mt-3 inline-flex h-10 w-full items-center justify-center gap-2 rounded-full bg-primary px-5 text-[13px] font-medium text-[var(--md-sys-color-on-primary)] sm:w-auto"
              >
                <DownloadIcon className="h-4 w-4" aria-hidden="true" />
                {t('setupGuide.interceptCA.download')}
              </a>
              <div className="mt-2 break-all font-mono text-[10px] leading-relaxed text-text-faint">{caDownloadURL}</div>
            </div>
            <div className="rounded-[14px] bg-primary-container p-3.5 text-[11px] leading-relaxed text-on-primary-container">
              {t('setupGuide.interceptCA.sharedHint')}
            </div>
          </div>

          <div className="flex flex-col gap-4 border-divider lg:border-l lg:pl-6">
            <StepList steps={caSteps} />
            <div className="rounded-[14px] bg-[var(--md-sys-color-warning-container)] p-3.5 text-[11px] leading-relaxed text-[var(--md-sys-color-on-warning-container)]">
              {t('setupGuide.interceptCA.note')}
            </div>
          </div>
        </CardBody>
        <div className="mx-5 mb-5 flex flex-col gap-3 rounded-[14px] bg-[var(--md-sys-color-warning-container)] p-4 text-[11px] leading-5 text-[var(--md-sys-color-on-warning-container)] sm:flex-row sm:items-center">
          <SmartphoneIcon className="h-5 w-5 shrink-0" aria-hidden="true" />
          <div className="min-w-0 flex-1">
            <div className="font-medium">{t('setupGuide.interceptCA.androidUnsupportedTitle')}</div>
            <div className="mt-0.5 opacity-85">{t('setupGuide.interceptCA.androidUnsupportedBody')}</div>
          </div>
        </div>
        <div className="flex flex-col gap-3 border-t border-divider px-5 py-4 sm:flex-row sm:items-center">
          <div className="min-w-0 flex-1 text-[10.5px] leading-5 text-text-faint">{t('setupGuide.interceptCA.acknowledgementHint')}</div>
          <Button type="button" variant={acknowledged ? 'secondary' : 'primary'} size="sm" onClick={() => setAcknowledged(!acknowledged)}>
            {acknowledged ? t('setupGuide.interceptCA.clearAcknowledgement') : t('setupGuide.interceptCA.confirmAcknowledgement')}
          </Button>
        </div>
      </Card>

      <Card variant="tonal" className="p-5">
        <div className="flex items-start gap-3">
          <SmartphoneIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" />
          <div>
            <div className="text-[13px] font-medium text-text-strong">{t('setupGuide.requirementsTitle')}</div>
            <div className="mt-1 text-[11.5px] leading-relaxed text-text-soft">{t('setupGuide.requirementsBody')}</div>
          </div>
        </div>
      </Card>
    </div>
  )
}
