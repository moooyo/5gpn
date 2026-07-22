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
 * carries {block,direct,proxy} and collapses the design's 5 labels / 4
 * colors down to 3. Colors retain the established query-log legend palette.
 */
export const DECISION: Record<string, Decision> = {
  'block': { key: 'logs.decision.block', color: '#dc2626' }, // 拦截 red
  'force-direct': { key: 'logs.decision.forceDirect', color: '#16a34a' }, // 强制直连 green
  'force-proxy': { key: 'logs.decision.forceProxy', color: '#2563eb' }, // 强制代理 blue
  'chnroute-cn': { key: 'logs.decision.chnrouteCn', color: '#0891b2' }, // 国内直连 cyan
  'chnroute-foreign': { key: 'logs.decision.chnrouteForeign', color: '#2563eb' }, // 境外代理 blue
}

/** Fallback when `reason` is missing/unknown — derived from the coarser
 *  `verdict` enum ({block,direct,proxy}), reusing the same 3 colors. */
const VERDICT_FALLBACK: Record<string, Decision> = {
  block: { key: 'logs.decision.block', color: '#dc2626' },
  direct: { key: 'logs.decision.direct', color: '#16a34a' },
  proxy: { key: 'logs.decision.proxy', color: '#2563eb' },
}

/** Neutral last-resort fallback when neither `reason` nor `verdict` is a
 *  recognized value (should not happen against a well-behaved backend). */
const UNKNOWN_DECISION: Decision = { key: 'verdicts.noVerdict', color: '#93a2bd' }

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
          <span className="inline-flex items-center gap-1.5 text-[11.5px] font-semibold text-text-mid">
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
      cell: ({ row }) => <span className="font-mono text-text-soft">{formatLogIps(row.original.ips)}</span>,
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
