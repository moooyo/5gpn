import { lazy, Suspense, useMemo, useState, type FocusEvent, type KeyboardEvent } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { MenuIcon, SearchIcon, StorefrontFilledIcon } from '../components/icons'
import { ALL_NAV_ITEMS } from './navigation'

const ProfileMenu = lazy(() => import('./ProfileMenu').then((module) => ({ default: module.ProfileMenu })))

export function pageMeta(pathname: string): string {
  const match = ALL_NAV_ITEMS.find((item) => pathname === item.path || pathname.startsWith(`${item.path}/`))
  return match?.id ?? 'overview'
}

function RouteSearch() {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)

  const results = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase()
    const items = normalized
      ? ALL_NAV_ITEMS.filter((item) => {
          const title = t(item.labelKey).toLocaleLowerCase()
          const subtitle = t(`topbar.sub.${item.labelKey.replace(/^nav\./, '')}`).toLocaleLowerCase()
          return `${title} ${subtitle}`.includes(normalized)
        })
      : ALL_NAV_ITEMS
    return items.slice(0, 6)
  }, [query, t])

  const go = (path: string) => {
    setOpen(false)
    setQuery('')
    void navigate(path)
  }

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Escape') setOpen(false)
    if (event.key === 'Enter' && results[0]) {
      event.preventDefault()
      go(results[0].path)
    }
  }

  const onBlur = (event: FocusEvent<HTMLDivElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false)
  }

  return (
    <div className="relative hidden w-[min(30vw,340px)] lg:block" onBlur={onBlur} onFocusCapture={() => setOpen(true)}>
      <div className="flex h-11 items-center gap-2.5 rounded-full bg-surface-container px-4 text-text-mid">
        <SearchIcon className="h-5 w-5 shrink-0" aria-hidden="true" />
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          onKeyDown={onKeyDown}
          aria-label={t('topbar.search')}
          aria-expanded={open}
          aria-controls="route-search-results"
          aria-autocomplete="list"
          role="combobox"
          placeholder={t('topbar.searchPlaceholder')}
          className="min-w-0 flex-1 border-0 bg-transparent text-[13px] text-text-strong outline-none placeholder:text-text-faint"
        />
      </div>
      {open ? (
        <div id="route-search-results" role="listbox" className="zds-menu-popup absolute left-0 right-0 top-[50px] p-1.5">
          {results.length > 0 ? results.map((item) => (
            <button
              key={item.id}
              type="button"
              role="option"
              aria-selected="false"
              onClick={() => go(item.path)}
              className="zds-state-layer flex w-full flex-col rounded-[10px] px-3 py-2 text-left outline-none"
            >
              <span className="text-[12.5px] font-medium text-text-strong">{t(item.labelKey)}</span>
              <span className="truncate text-[10.5px] text-text-faint">{t(`topbar.sub.${item.labelKey.replace(/^nav\./, '')}`)}</span>
            </button>
          )) : (
            <div className="px-3 py-4 text-center text-[12px] text-text-faint">{t('topbar.searchEmpty')}</div>
          )}
        </div>
      ) : null}
    </div>
  )
}

export function Topbar({ onOpenNavigation }: { onOpenNavigation?: () => void } = {}) {
  const { t } = useTranslation()
  const { pathname } = useLocation()
  const id = pageMeta(pathname)
  const item = ALL_NAV_ITEMS.find((candidate) => candidate.id === id) ?? ALL_NAV_ITEMS[0]
  const subKey = `topbar.sub.${item.labelKey.replace(/^nav\./, '')}`

  return (
    <header className="flex h-[72px] shrink-0 items-center gap-3 bg-bg px-3 sm:px-5 lg:px-7">
      {onOpenNavigation ? (
        <button
          type="button"
          onClick={onOpenNavigation}
          aria-label={t('nav.openMenu')}
          aria-controls="mobile-navigation"
          className="zds-state-layer grid h-10 w-10 shrink-0 place-items-center rounded-full text-text-mid md:hidden"
          data-testid="mobile-nav-open"
        >
          <MenuIcon className="h-6 w-6" aria-hidden="true" />
        </button>
      ) : null}

      <div className="flex min-w-0 flex-col gap-0.5">
        <span className="flex min-w-0 items-center gap-2 truncate text-[19px] font-medium tracking-[-.01em] text-text-strong">
          {id === 'marketplace' ? <StorefrontFilledIcon className="h-[22px] w-[22px] shrink-0 text-primary" aria-hidden="true" /> : null}
          <span className="truncate">{t(item.labelKey)}</span>
        </span>
        <span className="hidden max-w-[52vw] truncate text-[11.5px] text-text-faint sm:block">{t(subKey)}</span>
      </div>
      <div className="flex-1" />
      <RouteSearch />
      <Suspense fallback={<div className="h-[34px] w-[34px] rounded-full bg-primary-container" aria-hidden="true" />}>
        <ProfileMenu />
      </Suspense>
    </header>
  )
}
