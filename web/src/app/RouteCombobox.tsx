import { useMemo, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { SearchIcon } from '../components/icons'
import { cn } from '../lib/cn'
import { ALL_NAV_ITEMS, type NavItem } from './navigation'

const MAX_RESULTS = 6

export function useRouteResults(query: string): NavItem[] {
  const { t } = useTranslation()
  return useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase()
    const items = normalized
      ? ALL_NAV_ITEMS.filter((item) => {
          const title = t(item.labelKey).toLocaleLowerCase()
          const subtitle = t(`topbar.sub.${item.labelKey.replace(/^nav\./, '')}`).toLocaleLowerCase()
          return `${title} ${subtitle}`.includes(normalized)
        })
      : ALL_NAV_ITEMS
    return items.slice(0, MAX_RESULTS)
  }, [query, t])
}

export interface RouteComboboxProps {
  query: string
  onQueryChange: (value: string) => void
  results: NavItem[]
  active: number
  onActiveChange: (index: number) => void
  onSelect: (path: string) => void
  onDismiss: () => void
  listId: string
  expanded: boolean
  autoFocus?: boolean
  className?: string
}

/**
 * The one combobox behind both entry points. The inline field and the ⌘K
 * dialog are the same list, the same matcher and the same keys — the dialog
 * exists because below `lg` there was no route search at all, not because the
 * two should behave differently.
 */
export function RouteCombobox({
  query,
  onQueryChange,
  results,
  active,
  onActiveChange,
  onSelect,
  onDismiss,
  listId,
  expanded,
  autoFocus,
  className,
}: RouteComboboxProps) {
  const { t } = useTranslation()

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key === 'Escape') {
      onDismiss()
      return
    }
    if (event.key === 'ArrowDown') {
      event.preventDefault()
      onActiveChange(results.length === 0 ? 0 : (active + 1) % results.length)
      return
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault()
      onActiveChange(results.length === 0 ? 0 : (active - 1 + results.length) % results.length)
      return
    }
    if (event.key === 'Enter' && results[active]) {
      event.preventDefault()
      onSelect(results[active].path)
    }
  }

  return (
    <div className={className}>
      <div className="flex h-field items-center gap-2.5 rounded-pill bg-surface-container px-4 text-text-mid">
        <SearchIcon className="h-5 w-5 shrink-0" aria-hidden="true" />
        <input
          // The dialog exists to receive typing; anything else would cost a
          // second keystroke to reach the field the chord just opened.
          autoFocus={autoFocus}
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          onKeyDown={onKeyDown}
          aria-label={t('topbar.search')}
          aria-expanded={expanded}
          // Both only while the list is actually rendered: the listbox and its
          // options do not exist in the DOM when the inline field is
          // collapsed, and pointing at a missing id is an invalid ARIA value,
          // not a harmless one.
          aria-controls={expanded ? listId : undefined}
          aria-activedescendant={expanded && results[active] ? `${listId}-${results[active].id}` : undefined}
          aria-autocomplete="list"
          role="combobox"
          placeholder={t('topbar.searchPlaceholder')}
          className="min-w-0 flex-1 border-0 bg-transparent text-body text-text-strong outline-none placeholder:text-text-faint"
        />
      </div>
      {expanded ? (
        <div id={listId} role="listbox" className="zds-menu-popup absolute left-0 right-0 top-[50px] p-1.5">
          {results.length > 0 ? results.map((item, index) => (
            <button
              key={item.id}
              id={`${listId}-${item.id}`}
              type="button"
              role="option"
              aria-selected={index === active}
              onMouseEnter={() => onActiveChange(index)}
              onClick={() => onSelect(item.path)}
              className={cn(
                'zds-state-layer flex w-full flex-col rounded-ctl px-3 py-2 text-left outline-none',
                index === active && 'bg-secondary-container text-on-secondary-container',
              )}
            >
              <span className="text-label font-medium text-text-strong">{t(item.labelKey)}</span>
              <span className="truncate text-meta text-text-faint">{t(`topbar.sub.${item.labelKey.replace(/^nav\./, '')}`)}</span>
            </button>
          )) : (
            <div className="px-3 py-4 text-center text-label text-text-faint">{t('topbar.searchEmpty')}</div>
          )}
        </div>
      ) : null}
    </div>
  )
}
