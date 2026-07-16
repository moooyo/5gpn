import type { ComponentType } from 'react'
import { NavLink } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import {
  LayoutGrid,
  BookOpenCheck,
  Split,
  ScrollText,
  Search,
  ListChecks,
  Settings,
  SlidersHorizontal,
  Shield,
  Gauge,
  FileCode2,
  X,
  type LucideProps,
} from 'lucide-react'
import { NAV_GROUPS } from './navigation'
import { useStatus } from '../lib/StatusContext'
import { StatusDot } from '../components/ds'
import { cn } from '../lib/cn'

// Resolves the string icon name carried by NAV_GROUPS (navigation.ts is kept
// lucide-free) to an actual component. Keep this map in sync with the icon
// names used in navigation.ts.
const ICONS: Record<string, ComponentType<LucideProps>> = {
  LayoutGrid,
  BookOpenCheck,
  Split,
  ScrollText,
  Search,
  ListChecks,
  Settings,
  SlidersHorizontal,
  Gauge,
  FileCode2,
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
      className={cn('flex w-[236px] shrink-0 flex-col border-r border-border bg-card p-[18px_14px]', className)}
      data-testid={testId}
    >
      <div className="flex items-center gap-2.5 px-1 pb-5">
        <div
          className="flex h-[34px] w-[34px] shrink-0 items-center justify-center rounded-[9px]"
          style={{ background: 'linear-gradient(135deg,#3b82f6,#2563eb)' }}
        >
          <Shield className="h-[18px] w-[18px] text-white" strokeWidth={2} />
        </div>
        <div className="flex flex-col leading-none">
          <span className="text-[16px] font-extrabold text-text-strong">5GPN</span>
          <span className="text-[8.5px] font-semibold uppercase tracking-[2.5px] text-text-faint">
            {t('topbar.consoleTag')}
          </span>
        </div>
        {onClose ? (
          <button
            type="button"
            onClick={onClose}
            aria-label={t('nav.closeMenu')}
            className="ml-auto inline-flex h-9 w-9 items-center justify-center rounded-[9px] text-text-soft hover:bg-primary/10"
          >
            <X className="h-5 w-5" aria-hidden="true" />
          </button>
        ) : null}
      </div>

      {/* overflow-x-hidden: the active tab's `translateX(3px)` micro-shift
          pushes it a few px past the nav's content box, and `overflow-y-auto`
          makes the x-axis compute to `auto` (CSS overflow rule) — which paints
          a stray horizontal scrollbar right above the kernel-status card.
          Clipping x kills it; the 3px is empty tint, invisible when trimmed. */}
      <nav className="flex flex-1 flex-col overflow-y-auto overflow-x-hidden" aria-label={t('nav.primary')}>
        {NAV_GROUPS.map((group, gi) => (
          <div key={group.id}>
            {gi > 0 ? <div className="my-3 h-px bg-divider" /> : null}
            <div className="px-3 pb-1.5 text-[9.5px] font-bold uppercase tracking-[1.5px] text-text-faint">
              {t(group.labelKey)}
            </div>
            <div className="flex flex-col gap-0.5">
              {group.items.map((item) => {
                const Icon = ICONS[item.icon]
                return (
                  <NavLink
                    key={item.id}
                    to={item.path}
                    onClick={onNavigate}
                    className={({ isActive }) =>
                      cn(
                        'sidebar-tab flex items-center gap-2.5 rounded-[9px] px-3 py-2.5 text-[13px] font-semibold',
                        isActive
                          ? 'sidebar-tab-active bg-primary/[.09] text-primary shadow-[inset_3px_0_0_var(--color-primary)]'
                          : 'text-text-soft hover:brightness-[.98]',
                      )
                    }
                  >
                    {Icon ? <Icon className="h-[18px] w-[18px] shrink-0" strokeWidth={1.9} /> : null}
                    <span>{t(item.labelKey)}</span>
                  </NavLink>
                )
              })}
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
  const { dnsOk, mihomoOk } = useStatus()

  return (
    <div className="mt-auto flex flex-col gap-[9px] rounded-[11px] border border-border bg-bg p-3">
      <KernelRow title={t('topbar.kernelDns')} sub="5gpn-dns · :853 DoT" up={dnsOk} />
      <div className="h-px bg-divider" />
      <KernelRow title="mihomo" sub="gateway · :443" up={mihomoOk} />
    </div>
  )
}

function KernelRow({ title, sub, up }: { title: string; sub: string; up: boolean }) {
  const { t } = useTranslation()
  return (
    <div className="flex items-center gap-2">
      <StatusDot color={up ? '#22c55e' : '#dc2626'} pulse={up} />
      <div className="flex flex-1 flex-col">
        <span className="text-[11.5px] font-bold text-text-strong">{title}</span>
        <span className="text-[9.5px] text-text-faint">{sub}</span>
      </div>
      <span className={cn('text-[10px] font-bold', up ? 'text-green' : 'text-red')}>
        {up ? t('common.running') : t('settings.tgbotStateStopped')}
      </span>
    </div>
  )
}
