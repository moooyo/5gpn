import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { ArrowDownIcon, ArrowUpIcon, DeleteIcon, EditIcon, SearchIcon } from '../../components/icons'
import { Badge, type BadgeTone, Button, Card, Input, SegmentedControl, Toggle } from '../../components/ds'
import { DataGrid, type ColumnDef } from '../../components/data-grid'
import type { Intent, PolicyRule } from '../../lib/api/types'
import { useMediaQuery } from '../../lib/useMediaQuery'

const INTENT_TONE: Record<Intent, BadgeTone> = { block: 'red', direct: 'green', proxy: 'blue' }
type IntentFilter = 'all' | Intent
const INTENT_FILTERS: IntentFilter[] = ['all', 'block', 'direct', 'proxy']

export interface PolicyRulesTableProps {
  rules: PolicyRule[]
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

interface ColArgs {
  t: TFunction
  filtering: boolean
  fullIndexOf: (id: string) => number
  count: number
  onReorder: (ids: string[]) => void
  rules: PolicyRule[]
  onEdit: (r: PolicyRule) => void
  onDelete: (r: PolicyRule) => void
  onToggle: (r: PolicyRule) => void
}

function buildColumns(a: ColArgs): ColumnDef<PolicyRule, any>[] {
  return [
    {
      id: 'order',
      header: '#',
      enableSorting: false,
      meta: { width: 84 },
      cell: ({ row }) => {
        const idx = a.fullIndexOf(row.original.id)
        return (
          <div className="flex items-center gap-1">
            <span className="w-5 font-mono text-[11px] text-text-faint">{idx + 1}</span>
            {a.filtering ? null : (
              <div className="flex items-center gap-0.5">
                <button
                  type="button"
                  aria-label={a.t('policyRules.table.moveUp')}
                  disabled={idx <= 0}
                  onClick={() => a.onReorder(moveIds(a.rules, idx, -1))}
                  className="zds-state-layer grid h-8 w-8 place-items-center rounded-full text-text-faint disabled:cursor-not-allowed disabled:opacity-30"
                >
                  <ArrowUpIcon className="h-4 w-4" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label={a.t('policyRules.table.moveDown')}
                  disabled={idx < 0 || idx >= a.count - 1}
                  onClick={() => a.onReorder(moveIds(a.rules, idx, 1))}
                  className="zds-state-layer grid h-8 w-8 place-items-center rounded-full text-text-faint disabled:cursor-not-allowed disabled:opacity-30"
                >
                  <ArrowDownIcon className="h-4 w-4" aria-hidden="true" />
                </button>
              </div>
            )}
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
          <span className="min-w-0 truncate font-mono text-[12px] text-text-strong" title={row.original.matcher.value}>{row.original.matcher.value}</span>
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
      cell: ({ row }) => (
        <div className="flex items-center justify-end gap-1.5">
          <Button type="button" variant="secondary" size="sm" onClick={() => a.onEdit(row.original)}>
            <EditIcon className="h-4 w-4" aria-hidden="true" />
            {a.t('common.edit')}
          </Button>
          <Button
            type="button"
            variant="danger"
            size="sm"
            onClick={() => a.onDelete(row.original)}
            aria-label={`${a.t('common.delete')} ${row.original.id}`}
          >
            <DeleteIcon className="h-4 w-4" aria-hidden="true" />
            {a.t('common.delete')}
          </Button>
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
export function PolicyRulesTable({ rules, onEdit, onDelete, onToggle, onReorder }: PolicyRulesTableProps) {
  const { t } = useTranslation()
  const [search, setSearch] = useState('')
  const [intent, setIntent] = useState<IntentFilter>('all')
  const isMobile = useMediaQuery('(max-width: 767px)')
  const filtering = search.trim() !== '' || intent !== 'all'

  const indexById = useMemo(() => new Map(rules.map((r, i) => [r.id, i])), [rules])
  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    return rules.filter(
      (r) => (intent === 'all' || r.intent === intent) && (q === '' || r.matcher.value.toLowerCase().includes(q)),
    )
  }, [rules, search, intent])

  const columns = buildColumns({
    t,
    filtering,
    fullIndexOf: (id) => indexById.get(id) ?? -1,
    count: rules.length,
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
            className="w-full rounded-full pl-10"
          />
        </div>
      </div>
      {filtering ? (
        <div className="border-b border-divider px-4 py-1.5 text-[11px] text-text-faint">
          {t('policyRules.table.reorderDisabledHint')}
        </div>
      ) : null}
      {isMobile ? (
        <div className="divide-y divide-border">
          {filtered.length === 0 ? <div className="p-8 text-center text-[12px] text-text-faint">{t('policyRules.table.empty')}</div> : filtered.map((rule) => {
            const index = indexById.get(rule.id) ?? -1
            return (
              <article key={rule.id} className="p-4">
                <div className="flex items-start gap-3">
                  <span className="grid h-8 w-8 shrink-0 place-items-center rounded-full bg-surface-container font-mono text-[11px] text-text-faint">{index + 1}</span>
                  <div className="min-w-0 flex-1">
                    <div className="flex flex-wrap items-center gap-2">
                      <Badge tone="neutral">{t(`policyRules.kind.${rule.matcher.kind}`)}</Badge>
                      <Badge tone={INTENT_TONE[rule.intent]}>{t(`policyRules.intent.${rule.intent}`)}</Badge>
                    </div>
                    <div className="mt-2 break-all font-mono text-[12px] text-text-strong">{rule.matcher.value}</div>
                  </div>
                  <Toggle checked={rule.enabled} onCheckedChange={() => onToggle(rule)} aria-label={t('policyRules.table.colEnabled')} />
                </div>
                <div className="mt-3 flex items-center justify-end gap-1">
                  {!filtering ? (
                    <>
                      <button type="button" aria-label={t('policyRules.table.moveUp')} disabled={index <= 0} onClick={() => onReorder(moveIds(rules, index, -1))} className="zds-state-layer grid h-9 w-9 place-items-center rounded-full text-text-soft disabled:opacity-30"><ArrowUpIcon className="h-4 w-4" /></button>
                      <button type="button" aria-label={t('policyRules.table.moveDown')} disabled={index < 0 || index >= rules.length - 1} onClick={() => onReorder(moveIds(rules, index, 1))} className="zds-state-layer grid h-9 w-9 place-items-center rounded-full text-text-soft disabled:opacity-30"><ArrowDownIcon className="h-4 w-4" /></button>
                    </>
                  ) : null}
                  <Button variant="ghost" size="sm" onClick={() => onEdit(rule)}><EditIcon className="h-4 w-4" />{t('common.edit')}</Button>
                  <Button variant="danger" size="sm" onClick={() => onDelete(rule)}><DeleteIcon className="h-4 w-4" />{t('common.delete')}</Button>
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
