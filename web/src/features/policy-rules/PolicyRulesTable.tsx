import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { TFunction } from 'i18next'
import { ArrowDown, ArrowUp, Search } from 'lucide-react'
import { Badge, type BadgeTone, Button, Card, Input, SegmentedControl, Toggle } from '../../components/ds'
import { DataGrid, type ColumnDef } from '../../components/data-grid'
import type { Intent, PolicyRule } from '../../lib/api/types'

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
                  className="rounded p-1 text-text-faint transition-colors hover:text-primary disabled:cursor-not-allowed disabled:opacity-30"
                >
                  <ArrowUp className="h-3.5 w-3.5" aria-hidden="true" />
                </button>
                <button
                  type="button"
                  aria-label={a.t('policyRules.table.moveDown')}
                  disabled={idx < 0 || idx >= a.count - 1}
                  onClick={() => a.onReorder(moveIds(a.rules, idx, 1))}
                  className="rounded p-1 text-text-faint transition-colors hover:text-primary disabled:cursor-not-allowed disabled:opacity-30"
                >
                  <ArrowDown className="h-3.5 w-3.5" aria-hidden="true" />
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
          <span className="font-mono text-[12px] text-text-strong">{row.original.matcher.value}</span>
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
            {a.t('common.edit')}
          </Button>
          <Button
            type="button"
            variant="danger"
            size="sm"
            onClick={() => a.onDelete(row.original)}
            aria-label={`${a.t('common.delete')} ${row.original.id}`}
          >
            {a.t('common.delete')}
          </Button>
        </div>
      ),
    },
  ]
}

/** Ordered rule table for the ~90-default-row seed (UP-3 Task B3). A pure
 *  presentational component — the CRUD calls (reorder/toggle/edit/delete)
 *  are all owned by the caller (B4's page shell), matching egress's
 *  Tab-owns-CRUD split at one level up: here the table only computes WHICH
 *  id list a reorder means and hands it back via onReorder.
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
    <Card className="overflow-hidden p-0">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-divider px-4 py-3">
        <SegmentedControl
          value={intent}
          onChange={(v) => setIntent(v as IntentFilter)}
          options={INTENT_FILTERS.map((i) => ({
            value: i,
            label: i === 'all' ? t('policyRules.table.filterAll') : t(`policyRules.intent.${i}`),
          }))}
          className="w-full sm:w-[320px]"
        />
        <div className="relative">
          <Search
            className="pointer-events-none absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2 text-text-faint"
            aria-hidden="true"
          />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder={t('policyRules.table.searchPlaceholder')}
            data-testid="policy-rules-search"
            className="w-56 pl-9"
          />
        </div>
      </div>
      {filtering ? (
        <div className="border-b border-divider px-4 py-1.5 text-[11px] text-text-faint">
          {t('policyRules.table.reorderDisabledHint')}
        </div>
      ) : null}
      <div className="max-h-[560px] overflow-auto">
        <DataGrid columns={columns} data={filtered} emptyText={t('policyRules.table.empty')} />
      </div>
    </Card>
  )
}
