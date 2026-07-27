import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import {
  ArrowDownIcon,
  ArrowUpIcon,
  DeleteIcon,
  EditIcon,
  MenuIcon,
  SearchIcon,
  SortIcon,
} from '../../components/icons'
import {
  Badge,
  type BadgeTone,
  Button,
  Card,
  DropdownItem,
  DropdownMenu,
  DropdownSeparator,
  Input,
  SegmentedControl,
  Toggle,
} from '../../components/ds'
import { DataGrid, type ColumnDef } from '../../components/data-grid'
import type { Intent, PolicyRule } from '../../lib/api/types'
import { cn } from '../../lib/cn'
import { useMediaQuery } from '../../lib/useMediaQuery'

const INTENT_TONE: Record<Intent, BadgeTone> = { block: 'red', direct: 'green', proxy: 'blue' }
type IntentFilter = 'all' | Intent
const INTENT_FILTERS: IntentFilter[] = ['all', 'block', 'direct', 'proxy']
const EMPTY_PENDING: ReadonlySet<string> = new Set()

export interface PolicyRulesTableProps {
  rules: PolicyRule[]
  /** Rules that differ from the last applied snapshot (see policy-dirty.ts). */
  pendingIds?: ReadonlySet<string>
  /** Rule arrived at from the resolve test's "view the matched rule" link:
   *  scrolled into view and briefly highlighted, then left alone. */
  highlightId?: string | null
  onEdit: (rule: PolicyRule) => void
  onDelete: (rule: PolicyRule) => void
  onToggle: (rule: PolicyRule) => void
  onReorder: (ids: string[]) => void
}

/** Swaps the ids at `index` and `index + dir` within the FULL (unfiltered)
 *  rule list and returns the complete reordered id list — the backend's
 *  Reorder endpoint replaces the whole order, so a move must always be
 *  computed against every rule, never just the filtered subset. */
function moveIds(rules: PolicyRule[], index: number, dir: -1 | 1): string[] {
  const ids = rules.map((r) => r.id)
  const j = index + dir
  if (j < 0 || j >= ids.length) return ids
  ;[ids[index], ids[j]] = [ids[j], ids[index]]
  return ids
}

/** Lifts one rule to the head or tail of the full order. Reorder replaces the
 *  whole table server-side, so moving rule 20 to the top is one request —
 *  stepping it up nineteen times was nineteen. */
function moveIdToEdge(rules: PolicyRule[], index: number, edge: 'top' | 'bottom'): string[] {
  const ids = rules.map((r) => r.id)
  if (index < 0 || index >= ids.length) return ids
  const [moved] = ids.splice(index, 1)
  if (edge === 'top') ids.unshift(moved)
  else ids.push(moved)
  return ids
}

interface ColArgs {
  t: TFunction
  filtering: boolean
  fullIndexOf: (id: string) => number
  count: number
  pendingIds: ReadonlySet<string>
  highlightId?: string | null
  onReorder: (ids: string[]) => void
  rules: PolicyRule[]
  onEdit: (r: PolicyRule) => void
  onDelete: (r: PolicyRule) => void
  onToggle: (r: PolicyRule) => void
}

/** Row overflow. Edit and delete used to be two filled buttons per row, so on
 *  a twenty-rule table the most destructive action in the page was painted in
 *  error-container twenty times. Danger colour now belongs to the confirmation
 *  dialog alone. */
function RowActions({ a, rule, index }: { a: ColArgs; rule: PolicyRule; index: number }) {
  return (
    <DropdownMenu
      align="end"
      className="w-[228px]"
      trigger={
        <button
          type="button"
          aria-label={a.t('policyRules.table.rowActions')}
          className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-text-soft md:h-ctl md:w-ctl"
        >
          <MenuIcon className="h-4 w-4" aria-hidden="true" />
        </button>
      }
    >
      <DropdownItem onSelect={() => a.onEdit(rule)}>
        <EditIcon className="h-4 w-4" aria-hidden="true" />
        {a.t('common.edit')}
      </DropdownItem>
      <DropdownItem onSelect={() => a.onReorder(moveIdToEdge(a.rules, index, 'top'))}>
        <ArrowUpIcon className="h-4 w-4" aria-hidden="true" />
        {a.t('policyRules.table.moveTop')}
      </DropdownItem>
      <DropdownItem onSelect={() => a.onReorder(moveIdToEdge(a.rules, index, 'bottom'))}>
        <ArrowDownIcon className="h-4 w-4" aria-hidden="true" />
        {a.t('policyRules.table.moveBottom')}
      </DropdownItem>
      <DropdownSeparator />
      <DropdownItem danger onSelect={() => a.onDelete(rule)}>
        <DeleteIcon className="h-4 w-4" aria-hidden="true" />
        {a.t('common.delete')}
      </DropdownItem>
    </DropdownMenu>
  )
}

function buildColumns(a: ColArgs): ColumnDef<PolicyRule, any>[] {
  return [
    {
      id: 'order',
      header: '#',
      enableSorting: false,
      meta: { width: 100 },
      cell: ({ row }) => {
        const idx = a.fullIndexOf(row.original.id)
        return (
          <div className="flex items-center gap-1">
            {/* 3px marker: which rows are behind the pending count. */}
            <span
              aria-hidden="true"
              className={cn('-ml-2 mr-1 h-6 w-[3px] rounded-pill', a.pendingIds.has(row.original.id) ? 'bg-[var(--md-sys-color-warning)]' : 'bg-transparent')}
            />
            <span className="w-5 font-mono text-meta text-text-faint">{idx + 1}</span>
            {/* Kept mounted and disabled while filtering. Removing the control
                outright left a bare row and an 11px line of grey text as the
                only explanation for where it went. */}
            <div className="flex items-center gap-0.5">
              <button
                type="button"
                aria-label={a.t('policyRules.table.moveUp')}
                disabled={a.filtering || idx <= 0}
                onClick={() => a.onReorder(moveIds(a.rules, idx, -1))}
                className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-text-faint disabled:cursor-not-allowed disabled:opacity-30 md:h-chip md:w-chip"
              >
                <ArrowUpIcon className="h-4 w-4" aria-hidden="true" />
              </button>
              <button
                type="button"
                aria-label={a.t('policyRules.table.moveDown')}
                disabled={a.filtering || idx < 0 || idx >= a.count - 1}
                onClick={() => a.onReorder(moveIds(a.rules, idx, 1))}
                className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-text-faint disabled:cursor-not-allowed disabled:opacity-30 md:h-chip md:w-chip"
              >
                <ArrowDownIcon className="h-4 w-4" aria-hidden="true" />
              </button>
            </div>
          </div>
        )
      },
    },
    {
      id: 'matcher',
      header: a.t('policyRules.table.colMatcher'),
      enableSorting: false,
      cell: ({ row }) => (
        <div className="flex items-center gap-2">
          <Badge tone="neutral">{a.t(`policyRules.kind.${row.original.matcher.kind}`)}</Badge>
          <span
            ref={(node) => {
              if (node && a.highlightId === row.original.id) node.scrollIntoView({ block: 'center' })
            }}
            className={cn(
              'min-w-0 truncate font-mono text-label text-text-strong',
              a.highlightId === row.original.id && 'rounded-chip bg-[var(--md-sys-color-secondary-container)] px-1.5 text-on-secondary-container',
            )}
            title={row.original.matcher.value}
            data-highlighted={a.highlightId === row.original.id ? 'true' : undefined}
          >
            {row.original.matcher.value}
          </span>
          {a.pendingIds.has(row.original.id) ? (
            <span className="shrink-0 rounded-chip bg-[var(--md-sys-color-warning-container)] px-1.5 py-px text-meta font-medium text-[var(--md-sys-color-on-warning-container)]">
              {a.t('policyRules.table.pendingTag')}
            </span>
          ) : null}
        </div>
      ),
    },
    {
      id: 'intent',
      header: a.t('policyRules.table.colIntent'),
      enableSorting: false,
      meta: { width: 120 },
      cell: ({ row }) => <Badge tone={INTENT_TONE[row.original.intent]}>{a.t(`policyRules.intent.${row.original.intent}`)}</Badge>,
    },
    {
      id: 'enabled',
      header: () => <span className="block text-right">{a.t('policyRules.table.colEnabled')}</span>,
      enableSorting: false,
      meta: { width: 64 },
      cell: ({ row }) => (
        <div className="flex justify-end">
          <Toggle
            checked={row.original.enabled}
            onCheckedChange={() => a.onToggle(row.original)}
            aria-label={a.t('policyRules.table.colEnabled')}
          />
        </div>
      ),
    },
    {
      id: 'actions',
      header: '',
      enableSorting: false,
      meta: { width: 72 },
      cell: ({ row }) => (
        <div className="flex items-center justify-end">
          <RowActions a={a} rule={row.original} index={a.fullIndexOf(row.original.id)} />
        </div>
      ),
    },
  ]
}

/** Pure presentational ordered-rule table. The caller owns all CRUD calls;
 *  the table computes which id list a reorder means and returns it through
 *  onReorder.
 *
 *  Reorder is disabled while filtering (search or intent) is active:
 *  "moving row N" is only unambiguous against the full, contiguous order —
 *  within a filtered subset the adjacent visual neighbor is not the adjacent
 *  GLOBAL neighbor, so up/down would silently jump rows past whatever the
 *  filter hid. The order-number column always shows the rule's global
 *  position (`rule.order` index in the full array + 1), even while
 *  filtered, so the operator can see where a filtered row actually sits. */
export function PolicyRulesTable({ rules, pendingIds, highlightId, onEdit, onDelete, onToggle, onReorder }: PolicyRulesTableProps) {
  const { t } = useTranslation()
  const [search, setSearch] = useState('')
  const [intent, setIntent] = useState<IntentFilter>('all')
  const isMobile = useMediaQuery('(max-width: 767px)')
  const filtering = search.trim() !== '' || intent !== 'all'
  const pending = pendingIds ?? EMPTY_PENDING

  const indexById = useMemo(() => new Map(rules.map((r, i) => [r.id, i])), [rules])
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return rules.filter(
      (r) => (intent === 'all' || r.intent === intent) && (q === '' || r.matcher.value.toLowerCase().includes(q)),
    )
  }, [rules, search, intent])

  const clearFilters = () => {
    setSearch('')
    setIntent('all')
  }

  const columns = buildColumns({
    t,
    filtering,
    fullIndexOf: (id) => indexById.get(id) ?? -1,
    count: rules.length,
    pendingIds: pending,
    highlightId,
    onReorder,
    rules,
    onEdit,
    onDelete,
    onToggle,
  })

  return (
    <Card className="overflow-hidden p-0 shadow-none">
      <div className="flex flex-wrap items-center justify-between gap-3 bg-surface-container-low px-4 py-3.5">
        <SegmentedControl
          value={intent}
          onChange={(v) => setIntent(v as IntentFilter)}
          options={INTENT_FILTERS.map((i) => ({
            value: i,
            label: i === 'all' ? t('policyRules.table.filterAll') : t(`policyRules.intent.${i}`),
          }))}
          className="w-full grid-cols-4 sm:w-[360px]"
          ariaLabel={t('policyRules.table.colIntent')}
        />
        <div className="relative w-full sm:w-60">
          <SearchIcon
            className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint"
            aria-hidden="true"
          />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t('policyRules.table.searchPlaceholder')}
            data-testid="policy-rules-search"
            className="w-full rounded-pill pl-10"
          />
        </div>
      </div>
      {filtering ? (
        // The hint carries the action that resolves it. It used to be one line
        // of 11px grey text next to controls that had disappeared entirely.
        <div className="flex flex-wrap items-center gap-2 border-b border-divider bg-surface-container-low px-4 py-2 text-label text-text-mid">
          <SortIcon className="h-4 w-4 shrink-0 text-text-faint" aria-hidden="true" />
          <span className="min-w-0 flex-1">{t('policyRules.table.reorderDisabledHint')}</span>
          <Button type="button" variant="ghost" size="sm" onClick={clearFilters}>
            {t('policyRules.table.clearFilters')}
          </Button>
        </div>
      ) : null}
      {isMobile ? (
        <div className="divide-y divide-border">
          {filtered.length === 0 ? <div className="p-8 text-center text-label text-text-faint">{t('policyRules.table.empty')}</div> : filtered.map((rule) => {
            const index = indexById.get(rule.id) ?? -1
            return (
              <article
                key={rule.id}
                data-highlighted={highlightId === rule.id ? 'true' : undefined}
                className={cn(
                  'p-4',
                  pending.has(rule.id) && 'border-l-[3px] border-l-[var(--md-sys-color-warning)]',
                  highlightId === rule.id && 'bg-secondary-container',
                )}
              >
                <div className="flex items-start gap-3">
                  <span className="grid h-8 w-8 shrink-0 place-items-center rounded-pill bg-surface-container font-mono text-meta text-text-faint">{index + 1}</span>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge tone="neutral">{t(`policyRules.kind.${rule.matcher.kind}`)}</Badge>
                      <Badge tone={INTENT_TONE[rule.intent]}>{t(`policyRules.intent.${rule.intent}`)}</Badge>
                      {pending.has(rule.id) ? <Badge tone="amber">{t('policyRules.table.pendingTag')}</Badge> : null}
                    </div>
                    <div className="mt-2 break-all font-mono text-label text-text-strong">{rule.matcher.value}</div>
                  </div>
                  <Toggle checked={rule.enabled} onCheckedChange={() => onToggle(rule)} aria-label={t('policyRules.table.colEnabled')} />
                </div>
                <div className="mt-3 flex items-center justify-end gap-1">
                  <button
                    type="button"
                    aria-label={t('policyRules.table.moveUp')}
                    disabled={filtering || index <= 0}
                    onClick={() => onReorder(moveIds(rules, index, -1))}
                    className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-text-soft disabled:opacity-30"
                  >
                    <ArrowUpIcon className="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    aria-label={t('policyRules.table.moveDown')}
                    disabled={filtering || index < 0 || index >= rules.length - 1}
                    onClick={() => onReorder(moveIds(rules, index, 1))}
                    className="zds-state-layer grid h-field w-field place-items-center rounded-pill text-text-soft disabled:opacity-30"
                  >
                    <ArrowDownIcon className="h-4 w-4" />
                  </button>
                  <RowActions
                    a={{
                      t,
                      filtering,
                      fullIndexOf: (id) => indexById.get(id) ?? -1,
                      count: rules.length,
                      pendingIds: pending,
                      highlightId,
                      onReorder,
                      rules,
                      onEdit,
                      onDelete,
                      onToggle,
                    }}
                    rule={rule}
                    index={index}
                  />
                </div>
              </article>
            )
          })}
        </div>
      ) : (
        <div className="max-h-[560px] overflow-auto">
          <DataGrid columns={columns} data={filtered} emptyText={t('policyRules.table.empty')} />
        </div>
      )}
    </Card>
  )
}
