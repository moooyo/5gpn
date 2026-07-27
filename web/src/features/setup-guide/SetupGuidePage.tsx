import { useCallback, useEffect, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import {
  AndroidIcon,
  ArrowRightIcon,
  CheckCircleIcon,
  CopyIcon,
  DownloadIcon,
  ExternalLinkIcon,
  IosIcon,
  KeyIcon,
  QrCodeIcon,
  ShieldLockIcon,
  SmartphoneIcon,
  VerifiedIcon,
} from '../../components/icons'
import { encode } from 'uqr'
import { Badge, Button, Card, CardBody, CardHeader, SegmentedControl, toast } from '../../components/ds'
import { useStatus } from '../../lib/StatusContext'
import { api } from '../../lib/api/client'
import type { MITMSettingsView } from '../../lib/api/types'
import { useMITMTrustAcknowledgement } from '../../lib/mitmTrust'
import { useMediaQuery } from '../../lib/useMediaQuery'

export const IOS_PROFILE_PATH = '/ios/ios-dot.mobileconfig'
export const INTERCEPT_CA_PROFILE_PATH = '/ios/ios-intercept-ca.mobileconfig'

const DEVICE_STORAGE_KEY = '5gpn_setup_device'

export type SetupDevice = 'ios' | 'android'

export function profileURL(origin = window.location.origin): string {
  return new URL(IOS_PROFILE_PATH, origin).toString()
}

export function interceptCAProfileURL(origin = window.location.origin): string {
  return new URL(INTERCEPT_CA_PROFILE_PATH, origin).toString()
}

/** Which platform's branch to expand. The page used to lay all thirteen
 *  numbered steps out at once and never ask — an operator with only an iPhone
 *  had to pick their four out of the pile. Remembered per browser so the next
 *  visit lands on the same branch. */
function useSetupDevice(): [SetupDevice, (next: SetupDevice) => void] {
  const [device, setDeviceState] = useState<SetupDevice>(() => {
    try {
      return localStorage.getItem(DEVICE_STORAGE_KEY) === 'android' ? 'android' : 'ios'
    } catch {
      return 'ios'
    }
  })
  const setDevice = useCallback((next: SetupDevice) => {
    setDeviceState(next)
    try {
      localStorage.setItem(DEVICE_STORAGE_KEY, next)
    } catch {
      // The choice still holds for this page session.
    }
  }, [])
  return [device, setDevice]
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
      className="h-auto w-full rounded-ctl bg-white"
      shapeRendering="crispEdges"
    >
      <rect width="100%" height="100%" fill="#fff" />
      <path d={path} fill="#101828" />
    </svg>
  )
}

/**
 * The profile link, sized to be read. It was `text-meta break-all` — the
 * smallest type on the page — even though its whole reason to exist is being
 * typed by hand on a device that cannot scan. Copy sits next to it.
 */
function ProfileLink({ url, label }: { url: string; label: string }) {
  const { t } = useTranslation()
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url)
      toast.success(t('setupGuide.urlCopied'))
    } catch {
      toast.error(t('setupGuide.urlCopyFailed'))
    }
  }
  return (
    <div className="mt-2 flex items-center gap-2">
      <code className="min-w-0 flex-1 break-all font-mono text-label leading-relaxed text-text-faint">{url}</code>
      <button
        type="button"
        onClick={() => void copy()}
        aria-label={label}
        className="zds-state-layer grid h-ctl w-ctl shrink-0 place-items-center rounded-pill text-text-soft"
      >
        <CopyIcon className="h-4 w-4" aria-hidden="true" />
      </button>
    </div>
  )
}

/** QR + hint on desktop; on a phone the operator is already holding the
 *  device, so a code for it to scan itself is dead weight — the download
 *  button takes the whole width instead. The desktop code is also no longer a
 *  link: clicking it downloaded a `.mobileconfig` onto a machine that has no
 *  use for one. */
function ProfileScan({ url, alt, hint, mobile }: { url: string; alt: string; hint: string; mobile: boolean }) {
  if (mobile) return null
  return (
    <div className="flex flex-col gap-3">
      <div className="rounded-card bg-white p-3 shadow-[var(--md-sys-elevation-1)]">
        <QRCode value={url} label={alt} />
      </div>
      <div className="flex items-start gap-2 text-meta leading-relaxed text-text-soft">
        <QrCodeIcon className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
        {hint}
      </div>
    </div>
  )
}

function StepList({ steps }: { steps: Array<{ title: string; body: string }> }) {
  return (
    <ol className="flex flex-col gap-3.5">
      {steps.map((step, index) => (
        <li key={step.title} className="flex items-start gap-3">
          <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-pill bg-secondary-container font-mono text-meta font-medium text-on-secondary-container">
            {index + 1}
          </span>
          <div className="min-w-0 pt-0.5">
            <div className="text-label font-medium text-text-strong">{step.title}</div>
            <div className="mt-0.5 text-label leading-relaxed text-text-soft">{step.body}</div>
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
  const [device, setDevice] = useSetupDevice()
  const isMobile = useMediaQuery('(max-width: 767px)')
  const downloadURL = profileURL()
  const caDownloadURL = interceptCAProfileURL()
  const dotDomain = status?.dot_domain
  // One condition for the whole CA story. The warning banner already gated on
  // it; the five-step install card below did not, so with the master switch
  // off the page still walked the operator through installing a root
  // certificate that cannot do anything.
  const mitmEnabled = Boolean(mitmSettings?.enabled)

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
            <span className="grid h-12 w-12 shrink-0 place-items-center rounded-pill bg-[rgb(255_255_255_/_36%)]">
              <ShieldLockIcon className="h-6 w-6" aria-hidden="true" />
            </span>
            <div>
              <h1 className="text-headline font-medium">{t('setupGuide.title')}</h1>
              <p className="mt-1 max-w-[700px] text-label leading-relaxed opacity-80">{t('setupGuide.intro')}</p>
            </div>
          </div>
          <div className="flex shrink-0 items-center gap-2 rounded-pill bg-[rgb(255_255_255_/_30%)] px-4 py-2 text-label font-medium">
            <CheckCircleIcon className="h-4 w-4" aria-hidden="true" />
            {t('setupGuide.dotBadge')}
          </div>
        </div>
      </Card>

      <Card variant="tonal" className="flex flex-col gap-2 p-4">
        <div className="text-label font-medium text-text-soft">{t('setupGuide.devicePrompt')}</div>
        <SegmentedControl
          value={device}
          onChange={(next) => setDevice(next === 'android' ? 'android' : 'ios')}
          ariaLabel={t('setupGuide.devicePrompt')}
          className="max-w-[420px]"
          options={[
            { value: 'ios', label: t('setupGuide.deviceIos') },
            { value: 'android', label: t('setupGuide.deviceAndroid') },
          ]}
        />
      </Card>

      {mitmEnabled && !acknowledged ? (
        <div
          role="alert"
          data-testid="intercept-ca-trust-warning"
          className="flex flex-col gap-3 rounded-card bg-[var(--md-sys-color-warning-container)] p-4 text-[var(--md-sys-color-on-warning-container)] sm:flex-row sm:items-center"
        >
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-pill bg-[rgb(255_255_255_/_34%)]">
            <ShieldLockIcon className="h-5 w-5" aria-hidden="true" />
          </span>
          <div className="min-w-0 flex-1">
            <div className="text-body font-medium">{t('setupGuide.interceptCA.trustWarningTitle')}</div>
            <div className="mt-1 text-label leading-relaxed opacity-90">{t('setupGuide.interceptCA.trustWarningBody')}</div>
          </div>
          <a
            href={caDownloadURL}
            className="zds-state-layer inline-flex h-ctl shrink-0 items-center justify-center gap-2 rounded-pill bg-primary px-4 text-label font-medium text-[var(--md-sys-color-on-primary)]"
          >
            <DownloadIcon className="h-4 w-4" aria-hidden="true" />
            {t('setupGuide.interceptCA.trustWarningAction')}
          </a>
        </div>
      ) : null}

      {device === 'ios' ? (
        <Card className="overflow-hidden p-0" data-testid="ios-guide">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <IosIcon className="h-[20px] w-[20px] text-text-soft" aria-hidden="true" />
                {t('setupGuide.ios.title')}
              </span>
            }
          >
            <span className="rounded-pill bg-[var(--md-sys-color-success-container)] px-3 py-1 text-meta font-medium text-[var(--md-sys-color-on-success-container)]">
              {t('setupGuide.ios.signed')}
            </span>
          </CardHeader>
          {/* Left QR, right copy + steps — the same reading path the CA card
              below uses. The two used to disagree (two columns vs three). */}
          <CardBody className="grid gap-6 sm:grid-cols-[190px_minmax(0,1fr)]">
            <ProfileScan url={downloadURL} alt={t('setupGuide.ios.qrAlt')} hint={t('setupGuide.ios.scanHint')} mobile={isMobile} />
            <div className="flex min-w-0 flex-col gap-5">
              <div>
                <p className="text-label leading-relaxed text-text-soft">{t('setupGuide.ios.description')}</p>
                <a
                  href={downloadURL}
                  className="zds-state-layer mt-3 inline-flex h-action w-full items-center justify-center gap-2 rounded-pill bg-primary px-5 text-body font-medium text-[var(--md-sys-color-on-primary)] md:h-ctl md:w-auto"
                >
                  <DownloadIcon className="h-4 w-4" aria-hidden="true" />
                  {t('setupGuide.ios.download')}
                </a>
                <ProfileLink url={downloadURL} label={t('setupGuide.copyUrl')} />
              </div>
              <StepList steps={iosSteps} />
              <div className="rounded-card bg-[var(--md-sys-color-warning-container)] p-3.5 text-label leading-relaxed text-[var(--md-sys-color-on-warning-container)]">
                {t('setupGuide.ios.note')}
              </div>
            </div>
          </CardBody>
        </Card>
      ) : (
        <Card className="overflow-hidden p-0" data-testid="android-guide">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <SmartphoneIcon className="h-[20px] w-[20px] text-text-soft" aria-hidden="true" />
                {t('setupGuide.android.title')}
              </span>
            }
          >
            <span className="rounded-pill bg-primary-container px-3 py-1 text-meta font-medium text-on-primary-container">Android 9+</span>
          </CardHeader>
          <CardBody className="flex flex-col gap-5">
            <p className="text-label leading-relaxed text-text-soft">{t('setupGuide.android.description')}</p>
            <div>
              <div className="mb-2 flex items-center gap-1.5 text-meta font-semibold text-text-faint">
                <KeyIcon className="h-4 w-4" aria-hidden="true" />
                {t('setupGuide.android.hostnameLabel')}
              </div>
              <div className="min-h-field break-all rounded-card bg-surface-container-low px-4 py-3 font-mono text-body font-medium text-text-strong" data-testid="dot-domain">
                {dotDomain ?? (loading ? t('common.loading') : t('setupGuide.android.hostnameMissing'))}
              </div>
              <div className="mt-2 text-meta leading-relaxed text-text-faint">{t('setupGuide.android.hostnameHint')}</div>
            </div>
            <StepList steps={androidSteps} />
            <div className="flex items-start gap-2 rounded-card bg-surface-container-low p-3.5 text-label leading-relaxed text-text-mid">
              <ExternalLinkIcon className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
              {t('setupGuide.android.vendorNote')}
            </div>
          </CardBody>
        </Card>
      )}

      {!mitmEnabled ? (
        // Same `enabled` condition as the banner above: collapsed to one row
        // that says why it is not needed and offers the switch that would make
        // it needed, instead of five steps for a certificate with no effect.
        <Card className="flex flex-col gap-3 p-4 sm:flex-row sm:items-center" data-testid="intercept-ca-collapsed">
          <span className="grid h-10 w-10 shrink-0 place-items-center rounded-pill bg-surface-container text-text-soft">
            <VerifiedIcon className="h-5 w-5" aria-hidden="true" />
          </span>
          <div className="min-w-0 flex-1">
            <div className="text-body font-medium text-text-strong">{t('setupGuide.interceptCA.title')}</div>
            <div className="mt-0.5 text-label leading-relaxed text-text-faint">{t('setupGuide.interceptCA.collapsedBody')}</div>
          </div>
          <Link
            to="/settings"
            className="zds-state-layer inline-flex h-ctl shrink-0 items-center justify-center gap-1.5 rounded-pill bg-primary-container px-4 text-label font-medium text-on-primary-container"
          >
            {t('setupGuide.interceptCA.enableMITM')}
            <ArrowRightIcon className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Card>
      ) : device === 'android' ? (
        <Card className="flex flex-col gap-3 p-4 sm:flex-row sm:items-start" data-testid="intercept-ca-android">
          <AndroidIcon className="mt-0.5 h-5 w-5 shrink-0 text-text-soft" aria-hidden="true" />
          <div className="min-w-0 flex-1">
            <div className="text-body font-medium text-text-strong">{t('setupGuide.interceptCA.androidUnsupportedTitle')}</div>
            <div className="mt-0.5 text-label leading-relaxed text-text-faint">{t('setupGuide.interceptCA.androidUnsupportedBody')}</div>
          </div>
        </Card>
      ) : (
        <Card className="overflow-hidden p-0" data-testid="intercept-ca-guide">
          <CardHeader
            title={
              <span className="flex items-center gap-2">
                <VerifiedIcon className="h-[20px] w-[20px] text-primary" aria-hidden="true" />
                {t('setupGuide.interceptCA.title')}
              </span>
            }
          >
            <span className="rounded-pill bg-primary-container px-3 py-1 text-meta font-medium text-on-primary-container">
              {t('setupGuide.interceptCA.shared')}
            </span>
          </CardHeader>
          {/* Two facts of different kinds. The left one is a note this browser
              wrote to itself; the right one is the gateway's actual state. They
              used to be rendered identically — same size, same filled status
              circle, same green/amber badge — so opening the console on
              another machine turned the left one amber with nothing saying
              why. Outline vs fill now carries that difference. */}
          <div className="grid gap-3 border-b border-divider px-5 py-3.5 sm:grid-cols-2">
            <div className="flex min-w-0 items-center gap-3 rounded-card border border-dashed border-outline-variant px-4 py-3.5">
              <span className={acknowledged
                ? 'grid h-9 w-9 shrink-0 place-items-center rounded-pill border-2 border-[var(--md-sys-color-success)] text-[var(--md-sys-color-success)]'
                : 'grid h-9 w-9 shrink-0 place-items-center rounded-pill border-2 border-outline text-text-soft'}
              >
                {acknowledged ? <CheckCircleIcon className="h-5 w-5" aria-hidden="true" /> : <ShieldLockIcon className="h-5 w-5" aria-hidden="true" />}
              </span>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-1.5">
                  <span className="text-label font-medium text-text-strong">{t('setupGuide.interceptCA.clientTrust')}</span>
                  <span className="rounded-chip border border-outline-variant px-1.5 py-px font-mono text-meta text-text-faint">
                    {t('setupGuide.interceptCA.localOnlyTag')}
                  </span>
                </div>
                <div className="mt-0.5 text-meta leading-4 text-text-faint">{t(acknowledged ? 'setupGuide.interceptCA.locallyConfirmed' : 'setupGuide.interceptCA.notConfirmed')}</div>
              </div>
            </div>
            <div className="flex min-w-0 items-center gap-3 rounded-card bg-surface-container-low px-4 py-3.5">
              <span className="grid h-9 w-9 shrink-0 place-items-center rounded-pill bg-[var(--md-sys-color-success-container)] text-[var(--md-sys-color-on-success-container)]">
                <ShieldLockIcon className="h-5 w-5" aria-hidden="true" />
              </span>
              <div className="min-w-0 flex-1">
                <div className="text-label font-medium text-text-strong">{t('setupGuide.interceptCA.gatewayMaster')}</div>
                <div className="mt-0.5 text-meta leading-4 text-text-faint">{t('setupGuide.interceptCA.masterEnabled')}</div>
              </div>
              <Badge className="shrink-0" tone="green">{t('settings.mitmRunning')}</Badge>
            </div>
          </div>
          <CardBody className="grid gap-6 sm:grid-cols-[190px_minmax(0,1fr)]">
            <ProfileScan url={caDownloadURL} alt={t('setupGuide.interceptCA.qrAlt')} hint={t('setupGuide.interceptCA.scanHint')} mobile={isMobile} />
            <div className="flex min-w-0 flex-col gap-5">
              <div>
                <p className="text-label leading-relaxed text-text-soft">{t('setupGuide.interceptCA.description')}</p>
                <a
                  href={caDownloadURL}
                  className="zds-state-layer mt-3 inline-flex h-action w-full items-center justify-center gap-2 rounded-pill bg-primary px-5 text-body font-medium text-[var(--md-sys-color-on-primary)] md:h-ctl md:w-auto"
                >
                  <DownloadIcon className="h-4 w-4" aria-hidden="true" />
                  {t('setupGuide.interceptCA.download')}
                </a>
                <ProfileLink url={caDownloadURL} label={t('setupGuide.copyUrl')} />
              </div>
              <StepList steps={caSteps} />
              <div className="rounded-card bg-primary-container p-3.5 text-label leading-relaxed text-on-primary-container">
                {t('setupGuide.interceptCA.sharedHint')}
              </div>
              <div className="rounded-card bg-[var(--md-sys-color-warning-container)] p-3.5 text-label leading-relaxed text-[var(--md-sys-color-on-warning-container)]">
                {t('setupGuide.interceptCA.note')}
              </div>
            </div>
          </CardBody>
          <div className="flex flex-col gap-3 border-t border-divider px-5 py-4 sm:flex-row sm:items-center">
            <div className="min-w-0 flex-1 text-meta leading-5 text-text-faint">{t('setupGuide.interceptCA.acknowledgementHint')}</div>
            <Button type="button" variant={acknowledged ? 'secondary' : 'primary'} size="sm" onClick={() => setAcknowledged(!acknowledged)}>
              {acknowledged ? t('setupGuide.interceptCA.clearAcknowledgement') : t('setupGuide.interceptCA.confirmAcknowledgement')}
            </Button>
          </div>
        </Card>
      )}

      <Card variant="tonal" className="p-5">
        <div className="flex items-start gap-3">
          <SmartphoneIcon className="mt-0.5 h-5 w-5 shrink-0 text-primary" aria-hidden="true" />
          <div>
            <div className="text-body font-medium text-text-strong">{t('setupGuide.requirementsTitle')}</div>
            <div className="mt-1 text-label leading-relaxed text-text-soft">{t('setupGuide.requirementsBody')}</div>
          </div>
        </div>
      </Card>
    </div>
  )
}
