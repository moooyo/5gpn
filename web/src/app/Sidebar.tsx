import type { ComponentType, SVGProps } from 'react'
import { NavLink } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  CloseIcon,
  CodeIcon,
  DashboardFilledIcon,
  DashboardIcon,
  DevicesFilledIcon,
  DevicesIcon,
  ExtensionFilledIcon,
  ExtensionIcon,
  MemoryIcon,
  NetworkCheckFilledIcon,
  NetworkCheckIcon,
  ReceiptFilledIcon,
  ReceiptIcon,
  RuleFilledIcon,
  RuleIcon,
  SettingsFilledIcon,
  SettingsIcon,
  ShieldFilledIcon,
  SpeedFilledIcon,
  SpeedIcon,
  StorefrontFilledIcon,
  StorefrontIcon,
} from '../components/icons'
import { NAV_GROUPS, type NavIcon } from './navigation'
import { useStatus, type HealthState } from '../lib/StatusContext'
import { StatusDot } from '../components/ds'
import { cn } from '../lib/cn'

type Icon = ComponentType<SVGProps<SVGSVGElement>>

const ICONS: Record<NavIcon, { outline: Icon; filled: Icon }> = {
  dashboard: { outline: DashboardIcon, filled: DashboardFilledIcon },
  setup: { outline: DevicesIcon, filled: DevicesFilledIcon },
  logs: { outline: ReceiptIcon, filled: ReceiptFilledIcon },
  resolve: { outline: NetworkCheckIcon, filled: NetworkCheckFilledIcon },
  policy: { outline: RuleIcon, filled: RuleFilledIcon },
  extensions: { outline: ExtensionIcon, filled: ExtensionFilledIcon },
  marketplace: { outline: StorefrontIcon, filled: StorefrontFilledIcon },
  mihomo: { outline: SpeedIcon, filled: SpeedFilledIcon },
  config: { outline: CodeIcon, filled: CodeIcon },
  settings: { outline: SettingsIcon, filled: SettingsFilledIcon },
}

export interface SidebarProps {
  className?: string
  onNavigate?: () => void
  onClose?: () => void
  testId?: string
}

export function Sidebar({ className, onNavigate, onClose, testId }: SidebarProps = {}) {
  const { t } = useTranslation()

  return (
    <aside
      className={cn('flex w-[252px] shrink-0 flex-col bg-bg px-3 pb-4 pt-4', className)}
      data-testid={testId}
    >
      <div className="flex items-center gap-3 px-2 pb-5">
        <div className="grid h-11 w-11 shrink-0 place-items-center rounded-full bg-primary-container text-on-primary-container">
          <ShieldFilledIcon className="h-6 w-6" aria-hidden="true" />
        </div>
        <div className="flex min-w-0 flex-col leading-tight">
          <span className="text-[18px] font-semibold tracking-[.02em] text-text-strong">5GPN</span>
          <span className="text-[10px] font-medium tracking-[.14em] text-text-faint">{t('topbar.consoleTag')}</span>
        </div>
        {onClose ? (
          <button
            type="button"
            onClick={onClose}
            aria-label={t('nav.closeMenu')}
            className="zds-state-layer ml-auto grid h-10 w-10 place-items-center rounded-full text-text-soft"
          >
            <CloseIcon className="h-5 w-5" aria-hidden="true" />
          </button>
        ) : null}
      </div>

      <nav className="flex flex-1 flex-col overflow-x-hidden overflow-y-auto" aria-label={t('nav.primary')}>
        {NAV_GROUPS.map((group) => (
          <div key={group.id} className="mb-2">
            <div className="px-[18px] pb-1 pt-3 text-[11px] font-medium tracking-[.06em] text-text-faint">
              {t(group.labelKey)}
            </div>
            <div className="flex flex-col gap-0.5">
              {group.items.map((item) => (
                <NavLink
                  key={item.id}
                  to={item.path}
                  onClick={onNavigate}
                  className={({ isActive }) => cn(
                    'sidebar-tab zds-state-layer flex h-11 items-center gap-3 rounded-full px-[18px] text-[13.5px] font-medium',
                    isActive
                      ? 'sidebar-tab-active bg-secondary-container text-on-secondary-container'
                      : 'text-text-mid',
                  )}
                >
                  {({ isActive }) => {
                    const IconComponent = isActive ? ICONS[item.icon].filled : ICONS[item.icon].outline
                    return (
                      <>
                        <IconComponent className="h-[21px] w-[21px] shrink-0" aria-hidden="true" />
                        <span>{t(item.labelKey)}</span>
                      </>
                    )
                  }}
                </NavLink>
              ))}
            </div>
          </div>
        ))}
      </nav>

      <KernelStatusCard />
    </aside>
  )
}

function KernelStatusCard() {
  const { t } = useTranslation()
  const { dnsState, mihomoState } = useStatus()

  return (
    <div className="mt-3 flex flex-col gap-2 rounded-[16px] bg-surface-container-low p-3.5">
      <div className="mb-1 flex items-center gap-2 text-[11px] font-medium text-text-faint">
        <MemoryIcon className="h-4 w-4" aria-hidden="true" />
        {t('topbar.runtimeState')}
      </div>
      <KernelRow title={t('topbar.kernelDns')} sub="5gpn-dns · :853 DoT" state={dnsState} />
      <KernelRow title="mihomo" sub="gateway · :443" state={mihomoState} />
    </div>
  )
}

const HEALTH_PRESENTATION: Record<HealthState, { color: string; className: string; labelKey: string }> = {
  checking: { color: 'var(--color-amber)', className: 'text-amber', labelKey: 'common.healthChecking' },
  healthy: { color: 'var(--color-green)', className: 'text-green', labelKey: 'common.healthHealthy' },
  unknown: { color: 'var(--color-text-faint)', className: 'text-text-faint', labelKey: 'common.healthUnknown' },
  down: { color: 'var(--color-red)', className: 'text-red', labelKey: 'common.healthDown' },
}

function KernelRow({ title, sub, state }: { title: string; sub: string; state: HealthState }) {
  const { t } = useTranslation()
  const presentation = HEALTH_PRESENTATION[state]
  return (
    <div className="flex items-center gap-2.5 rounded-[10px] px-1 py-1">
      <StatusDot color={presentation.color} pulse={state === 'checking'} />
      <div className="flex min-w-0 flex-1 flex-col">
        <span className="text-[12px] font-medium text-text-strong">{title}</span>
        <span className="truncate font-mono text-[9.5px] text-text-faint">{sub}</span>
      </div>
      <span className={cn('text-[10px] font-medium', presentation.className)}>{t(presentation.labelKey)}</span>
    </div>
  )
}
