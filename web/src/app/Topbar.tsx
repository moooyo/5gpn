import { useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Menu } from 'lucide-react'
import { ALL_NAV_ITEMS } from './navigation'
import { ProfileMenu } from './ProfileMenu'

/** Maps a route pathname to the nav item id whose title/subtitle the topbar
 *  should show (an exact match, or a prefix match for nested routes).
 *  Falls back to 'overview' for any path with no matching nav item. */
export function pageMeta(pathname: string): string {
  const match = ALL_NAV_ITEMS.find((item) => pathname === item.path || pathname.startsWith(`${item.path}/`))
  return match?.id ?? 'overview'
}

export function Topbar({ onOpenNavigation }: { onOpenNavigation?: () => void } = {}) {
  const { t } = useTranslation()
  const { pathname } = useLocation()

  const id = pageMeta(pathname)
  const item = ALL_NAV_ITEMS.find((i) => i.id === id) ?? ALL_NAV_ITEMS.find((i) => i.id === 'overview')!
  const subKey = `topbar.sub.${item.labelKey.replace(/^nav\./, '')}`

  return (
    <header className="flex h-[66px] shrink-0 items-center justify-between border-b border-border bg-card px-3 sm:px-6">
      <div className="flex min-w-0 items-center gap-2.5">
        {onOpenNavigation ? (
          <button
            type="button"
            onClick={onOpenNavigation}
            aria-label={t('nav.openMenu')}
            aria-controls="mobile-navigation"
            className="inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-[9px] text-text-soft hover:bg-primary/10 md:hidden"
            data-testid="mobile-nav-open"
          >
            <Menu className="h-5 w-5" aria-hidden="true" />
          </button>
        ) : null}
        <div className="flex min-w-0 flex-col gap-0.5">
        <span className="whitespace-nowrap text-[16px] font-bold text-text-strong">{t(item.labelKey)}</span>
          <span className="truncate text-[11.5px] text-text-faint">{t(subKey)}</span>
        </div>
      </div>
      <ProfileMenu />
    </header>
  )
}
