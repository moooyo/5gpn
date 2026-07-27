import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { Modal } from '../components/ds'
import { RouteCombobox, useRouteResults } from './RouteCombobox'

/**
 * The same combobox as a dialog: the only route search below `lg`, and the
 * target of the global ⌘K / Ctrl-K chord at every width.
 *
 * Split into its own lazily-loaded module because it is the shell's only user
 * of the dialog primitive — pulling that into the initial chunk to serve a
 * panel that opens on a keystroke costs every first paint.
 */
export default function RouteSearchDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (open: boolean) => void }) {
  const navigate = useNavigate()
  const { t } = useTranslation()
  const [query, setQuery] = useState('')
  const [active, setActive] = useState(0)
  const results = useRouteResults(query)

  useEffect(() => {
    if (!open) return
    setQuery('')
    setActive(0)
  }, [open])

  const go = (path: string) => {
    onOpenChange(false)
    void navigate(path)
  }

  return (
    <Modal open={open} onOpenChange={onOpenChange} className="p-4" descriptionId="route-search-dialog-hint">
      <div className="relative">
        <RouteCombobox
          autoFocus
          query={query}
          onQueryChange={(value) => {
            setQuery(value)
            setActive(0)
          }}
          results={results}
          active={active}
          onActiveChange={setActive}
          onSelect={go}
          onDismiss={() => onOpenChange(false)}
          listId="route-search-dialog-results"
          expanded
        />
      </div>
      <p id="route-search-dialog-hint" className="mt-48 flex flex-wrap items-center gap-x-3 px-1 text-meta text-text-faint">
        <span>{t('topbar.searchHintSelect')}</span>
        <span>{t('topbar.searchHintOpen')}</span>
        <span>{t('topbar.searchHintClose')}</span>
      </p>
    </Modal>
  )
}
