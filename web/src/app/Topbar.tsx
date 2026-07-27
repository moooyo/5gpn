import { lazy, Suspense, useEffect, useRef, useState, type FocusEvent } from 'react'
import { useLocation } from 'react-router-dom'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { MenuIcon, SearchIcon, StorefrontFilledIcon } from '../components/icons'
import { ALL_NAV_ITEMS } from './navigation'
import { RouteCombobox, useRouteResults } from './RouteCombobox'

const ProfileMenu = lazy(() => import('./ProfileMenu').then((module) => ({ default: module.ProfileMenu })))
const RouteSearchDialog = lazy(() => import('./RouteSearchDialog'))

export function pageMeta(pathname: string): string {
  const match = ALL_NAV_ITEMS.find((item) => pathname === item.path || pathname.startsWith(`${item.path}/`))
  return match?.id ?? 'overview'
}

/** True on the platforms whose users expect ⌘ rather than Ctrl. Only affects
 *  the hint text; both chords are accepted either way. */
function isAppleShortcutPlatform(): boolean {
  if (typeof navigator === 'undefined') return false
  return /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent || '')
}

/** Inline field, `lg` and up. */
function RouteSearchInline() {
  const navigate = useNavigate()
  const [query, setQuery] = useState('')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const results = useRouteResults(query)

  const go = (path: string) => {
    setOpen(false)
    setQuery('')
    setActive(0)
    void navigate(path)
  }

  const onBlur = (event: FocusEvent<HTMLDivElement>) => {
    if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false)
  }

  return (
    <div className="relative hidden w-[min(30vw,340px)] lg:block" onBlur={onBlur} onFocusCapture={() => setOpen(true)}>
      <RouteCombobox
        query={query}
        onQueryChange={(value) => {
          setQuery(value)
          setActive(0)
        }}
        results={results}
        active={active}
        onActiveChange={setActive}
        onSelect={go}
        onDismiss={() => setOpen(false)}
        listId="route-search-results"
        expanded={open}
      />
    </div>
  )
}

export function Topbar({ onOpenNavigation }: { onOpenNavigation?: () => void } = {}) {
  const { t } = useTranslation()
  const { pathname } = useLocation()
  const id = pageMeta(pathname)
  const item = ALL_NAV_ITEMS.find((candidate) => candidate.id === id) ?? ALL_NAV_ITEMS[0]
  const subKey = `topbar.sub.${item.labelKey.replace(/^nav\./, '')}`
  const [paletteOpen, setPaletteOpen] = useState(false)
  // Mounted on first open and kept mounted after, so the dialog module is
  // fetched on demand rather than in the shell's initial chunk.
  const [paletteMounted, setPaletteMounted] = useState(false)
  const appleRef = useRef<boolean | null>(null)
  if (appleRef.current === null) appleRef.current = isAppleShortcutPlatform()

  const openPalette = () => {
    setPaletteMounted(true)
    setPaletteOpen(true)
  }

  // Registered globally. The desktop sidebar expands at `md` while search only
  // appeared at `lg`, so a portrait iPad had a topbar with nothing in it but an
  // avatar — and no width had a keyboard route in at all.
  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key.toLowerCase() !== 'k' || !(event.metaKey || event.ctrlKey)) return
      event.preventDefault()
      setPaletteMounted(true)
      setPaletteOpen((open) => !open)
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  return (
    <header className="flex h-[72px] shrink-0 items-center gap-3 bg-bg px-3 sm:px-5 lg:px-7">
      {onOpenNavigation ? (
        <button
          type="button"
          onClick={onOpenNavigation}
          aria-label={t('nav.openMenu')}
          aria-controls="mobile-navigation"
          className="zds-state-layer grid h-field w-field shrink-0 place-items-center rounded-pill text-text-mid md:hidden"
          data-testid="mobile-nav-open"
        >
          <MenuIcon className="h-6 w-6" aria-hidden="true" />
        </button>
      ) : null}

      <div className="flex min-w-0 flex-col gap-0.5">
        <span className="flex min-w-0 items-center gap-2 truncate text-headline font-medium tracking-[-.01em] text-text-strong">
          {id === 'marketplace' ? <StorefrontFilledIcon className="h-[22px] w-[22px] shrink-0 text-primary" aria-hidden="true" /> : null}
          <span className="truncate">{t(item.labelKey)}</span>
        </span>
        <span className="hidden max-w-[52vw] truncate text-label text-text-faint sm:block">{t(subKey)}</span>
      </div>
      <div className="flex-1" />
      <RouteSearchInline />
      {/* Icon on a phone, labelled pill with its chord between `md` and `lg`. */}
      <button
        type="button"
        onClick={openPalette}
        aria-label={t('topbar.search')}
        data-testid="route-search-trigger"
        className="zds-state-layer flex h-field shrink-0 items-center gap-2 rounded-pill px-2.5 text-text-mid md:h-ctl md:bg-surface-container md:px-4 lg:hidden"
      >
        <SearchIcon className="h-5 w-5 shrink-0" aria-hidden="true" />
        <span className="hidden text-body md:inline">{t('topbar.searchPlaceholder')}</span>
        <span className="hidden rounded-chip bg-card px-1.5 py-0.5 font-mono text-meta text-text-faint md:inline">
          {appleRef.current ? '⌘K' : 'Ctrl K'}
        </span>
      </button>
      {paletteMounted ? (
        <Suspense fallback={null}>
          <RouteSearchDialog open={paletteOpen} onOpenChange={setPaletteOpen} />
        </Suspense>
      ) : null}
      <Suspense fallback={<div className="h-[34px] w-[34px] rounded-pill bg-primary-container" aria-hidden="true" />}>
        <ProfileMenu />
      </Suspense>
    </header>
  )
}
