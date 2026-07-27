import type { ColumnDef } from '@tanstack/react-table'
import type { TFunction } from 'i18next'
import { Chip, StatusDot } from '../../components/ds'
import type { QueryLogEntry } from '../../lib/api/types'

export interface Decision {
  /** i18n key for the decision label. */
  key: string
  /** Hex color shared by the StatusDot and the label text. */
  color: string
}

/**
 * reason -> decision map (amendment A-H1, authoritative): the label + color
 * shown for a log row come from `reason`, NOT `verdict` — verdict only
 * carries {block,direct,proxy} and collapses the design's 5 labels / 5
 * colors down to 3.
 *
 * Colors are the shared categorical chart slots, assigned to the same entity
 * as the overview decision donut so a reader who learned a hue on one page
 * reads it the same on the other. They are not literal hex: the previous
 * fixed values were selected for a light surface and dropped below usable
 * contrast on the dark theme's card.
 *
 * This table is the single source for the decision colour AND the decision
 * wording. The filter pills above the table read it too — they used to carry
 * their own semantic-colour list, which painted 国内直连 green in the filter
 * row and orange in the table 40px below it.
 */
export const DECISION: Record<string, Decision> = {
  'block': { key: 'decision.block', color: 'var(--color-chart-1)' },
  'force-direct': { key: 'decision.forceDirect', color: 'var(--color-chart-2)' },
  'force-proxy': { key: 'decision.forceProxy', color: 'var(--color-chart-3)' },
  'chnroute-cn': { key: 'decision.chnrouteCn', color: 'var(--color-chart-4)' },
  'chnroute-foreign': { key: 'decision.chnrouteForeign', color: 'var(--color-chart-5)' },
}

/** Canonical display order for the five decisions: chart slot order, so the
 *  filter pills, the table dots and the overview donut all read left-to-right
 *  as 1,2,3,4,5. The filter row used to start at force-direct. */
export const DECISION_ORDER = [
  'block',
  'force-direct',
  'force-proxy',
  'chnroute-cn',
  'chnroute-foreign',
] as const

/** Fallback when `reason` is missing/unknown — derived from the coarser
 *  `verdict` enum ({block,direct,proxy}), reusing the matching reason slots. */
const VERDICT_FALLBACK: Record<string, Decision> = {
  block: { key: 'decision.block', color: 'var(--color-chart-1)' },
  direct: { key: 'decision.direct', color: 'var(--color-chart-2)' },
  proxy: { key: 'decision.proxy', color: 'var(--color-chart-3)' },
}

/** Neutral last-resort fallback when neither `reason` nor `verdict` is a
 *  recognized value (should not happen against a well-behaved backend). */
const UNKNOWN_DECISION: Decision = { key: 'verdicts.noVerdict', color: 'var(--color-text-faint)' }

export function resolveDecision(entry: Pick<QueryLogEntry, 'reason' | 'verdict'>): Decision {
  if (entry.reason && DECISION[entry.reason]) return DECISION[entry.reason]
  if (entry.verdict && VERDICT_FALLBACK[entry.verdict]) return VERDICT_FALLBACK[entry.verdict]
  return UNKNOWN_DECISION
}

/** Format an RFC3339 timestamp as a local HH:MM:SS clock string. Returns '—'
 *  for a missing/unparseable value. */
export function formatLogTime(iso: string | undefined | null): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '—'
  const hh = String(d.getHours()).padStart(2, '0')
  const mm = String(d.getMinutes()).padStart(2, '0')
  const ss = String(d.getSeconds()).padStart(2, '0')
  return `${hh}:${mm}:${ss}`
}

export function formatLogIps(ips: string[] | undefined): string {
  return ips && ips.length > 0 ? ips.join(', ') : '—'
}

/** Column defs for the desktop VirtualTable — widths per the brief's layout
 *  (time/name/reason/decision/ips/duration). */
export function buildLogColumns(t: TFunction): ColumnDef<QueryLogEntry, any>[] {
  return [
    {
      id: 'time',
      header: t('logs.colTime'),
      accessorFn: (row) => row.time,
      cell: ({ row }) => <span className="font-mono text-text-faint">{formatLogTime(row.original.time)}</span>,
      // Wide enough for the fixed `HH:MM:SS` monospace clock at px-4 padding —
      // an under-sized fixed column would (via min-width:auto on the flex cell)
      // expand only in the BODY, shoving every later column out of line with
      // the header. VirtualTable now pins cells to `min-w-0`, so this basis is
      // honored exactly and header ↔ body stay aligned.
      meta: { width: 92 },
    },
    {
      id: 'name',
      header: t('logs.colName'),
      accessorFn: (row) => row.name,
      cell: ({ row }) => (
        <span className="block truncate font-mono text-text-strong" title={row.original.name}>
          {row.original.name}
        </span>
      ),
      // No `meta.width` — VirtualTable's columnFlexStyle treats an undefined
      // width as `flex: 1 1 0%`, i.e. this column fills the remaining row
      // width (the design's `flex:1` on 域名).
    },
    {
      id: 'reason',
      header: t('logs.colReason'),
      accessorFn: (row) => row.reason ?? '',
      cell: ({ row }) => (row.original.reason ? <Chip value={row.original.reason} /> : <span className="text-text-faint">—</span>),
      meta: { width: 180 },
    },
    {
      id: 'decision',
      header: t('logs.colDecision'),
      accessorFn: (row) => row.reason ?? row.verdict ?? '',
      cell: ({ row }) => {
        const decision = resolveDecision(row.original)
        return (
          <span className="inline-flex items-center gap-1.5 text-label font-semibold text-text-mid">
            <StatusDot color={decision.color} />
            {t(decision.key)}
          </span>
        )
      },
      meta: { width: 110 },
    },
    {
      id: 'ips',
      header: t('logs.colIps'),
      accessorFn: (row) => (row.ips ?? []).join(', '),
      // Truncate like every other cell in this table. An answer with several
      // addresses used to wrap out of the fixed row box and draw over the row
      // below it — visible the moment the log holds a real multi-A response.
      cell: ({ row }) => (
        <span className="block truncate font-mono text-text-soft" title={formatLogIps(row.original.ips)}>
          {formatLogIps(row.original.ips)}
        </span>
      ),
      meta: { width: 140 },
    },
    {
      id: 'duration',
      header: () => <span className="block text-right">{t('logs.colDuration')}</span>,
      accessorFn: (row) => row.duration_ms,
      cell: ({ row }) => (
        <span className="block text-right font-mono text-text-faint">{Math.round(row.original.duration_ms)}ms</span>
      ),
      meta: { width: 80 },
    },
  ]
}
