import { useEffect, useRef, type ReactNode } from 'react'
import { type ColumnDef, type Column, flexRender, getCoreRowModel, useReactTable } from '@tanstack/react-table'
import { useVirtualizer } from '@tanstack/react-virtual'
import { cn } from '../../lib/cn'

export interface VirtualTableProps<T> {
  columns: ColumnDef<T, any>[]
  data: T[]
  /** Fixed row height in px used both for layout and size estimation. */
  rowHeight?: number
  /** Scroll-container height (CSS value or px number). */
  height?: number | string
  /** Hide the sticky column header for compact stream-style lists. */
  showHeader?: boolean
  /** Keep row separators off for stream-style lists while preserving them for tables. */
  showRowDividers?: boolean
  className?: string
  headerClassName?: string
  rowClassName?: string
  /** Stable identities are important when newest-first streams prepend rows. */
  getRowId?: (row: T, index: number) => string
  /** Optional deterministic height for rows that expose inline details. */
  getRowHeight?: (row: T) => number
  getRowClassName?: (row: T) => string | undefined
  getRowAriaLabel?: (row: T) => string
  isRowExpanded?: (row: T) => boolean
  onRowClick?: (row: T) => void
  renderRowDetails?: (row: T) => ReactNode
}

function columnFlexStyle<T>(column: Column<T, unknown>): { flex: string } {
  const width = (column.columnDef.meta as { width?: number | string } | undefined)?.width
  if (width === undefined) return { flex: '1 1 0%' }
  const px = typeof width === 'number' ? `${width}px` : width
  return { flex: `0 0 ${px}` }
}

function columnClassName<T>(column: Column<T, unknown>, kind: 'header' | 'cell'): string | undefined {
  const meta = column.columnDef.meta as { headerClassName?: string; cellClassName?: string } | undefined
  return kind === 'header' ? meta?.headerClassName : meta?.cellClassName
}

/**
 * Virtualized table for large row counts (query log). Rows are absolutely
 * positioned via an inline `transform: translateY(...)` — no injected
 * `<style>` (allowed by the `style-src-attr` CSP directive). Since a
 * virtualized list can't rely on native `<table>` layout, header + rows are
 * `display:flex` rows sharing the same per-column widths.
 */
export function VirtualTable<T>({
  columns,
  data,
  rowHeight = 44,
  height = '60vh',
  showHeader = true,
  showRowDividers = true,
  className,
  headerClassName,
  rowClassName,
  getRowId,
  getRowHeight,
  getRowClassName,
  getRowAriaLabel,
  isRowExpanded,
  onRowClick,
  renderRowDetails,
}: VirtualTableProps<T>) {
  const scrollRef = useRef<HTMLDivElement>(null)

  const table = useReactTable({
    data,
    columns,
    getCoreRowModel: getCoreRowModel(),
    ...(getRowId ? { getRowId } : {}),
  })

  const rows = table.getRowModel().rows

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: (index) => {
      const row = rows[index]
      return row && getRowHeight ? getRowHeight(row.original) : rowHeight
    },
    getItemKey: (index) => rows[index]?.id ?? index,
    overscan: 12,
  })

  // Expansion changes a stable row's deterministic size without changing
  // its key, so explicitly discard the virtualizer's cached measurement.
  useEffect(() => {
    virtualizer.measure()
  }, [getRowHeight, virtualizer])

  return (
    <div ref={scrollRef} className={cn('overflow-auto', className)} style={{ height }} data-testid="virtual-scroll">
      {showHeader ? <div className={cn('sticky top-0 z-10 flex bg-surface-container-low', headerClassName)}>
        {table.getHeaderGroups().map((headerGroup) =>
          headerGroup.headers.map((header) => (
            <div
              key={header.id}
              style={columnFlexStyle(header.column)}
              className={cn('min-w-0 px-4 py-3 text-left text-[10.5px] font-medium tracking-[.04em] text-text-faint', columnClassName(header.column, 'header'))}
            >
              {header.isPlaceholder ? null : flexRender(header.column.columnDef.header, header.getContext())}
            </div>
          )),
        )}
      </div> : null}
      <div
        style={{ position: 'relative', height: virtualizer.getTotalSize() }}
        data-testid="virtual-spacer"
      >
        {virtualizer.getVirtualItems().map((virtualRow) => {
          const row = rows[virtualRow.index]
          const original = row.original
          const expanded = isRowExpanded?.(original)
          const interactive = onRowClick !== undefined
          return (
            <div
              key={row.id}
              className={cn(
                'flex flex-col transition-colors hover:bg-surface-container-low',
                showRowDividers && 'border-b border-divider',
                interactive && 'cursor-pointer outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary',
                rowClassName,
                getRowClassName?.(original),
              )}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                right: 0,
                height: getRowHeight ? getRowHeight(original) : rowHeight,
                transform: `translateY(${virtualRow.start}px)`,
              }}
              role={interactive ? 'button' : undefined}
              tabIndex={interactive ? 0 : undefined}
              aria-label={getRowAriaLabel?.(original)}
              aria-expanded={renderRowDetails ? Boolean(expanded) : undefined}
              onClick={interactive ? () => onRowClick(original) : undefined}
              onKeyDown={interactive ? (event) => {
                if (event.target !== event.currentTarget || (event.key !== 'Enter' && event.key !== ' ')) return
                event.preventDefault()
                onRowClick(original)
              } : undefined}
            >
              <div className="flex w-full shrink-0 items-center" style={{ height: rowHeight }}>
                {row.getVisibleCells().map((cell) => (
                  <div key={cell.id} style={columnFlexStyle(cell.column)} className={cn('min-w-0 px-4 text-[12px]', rowHeight <= 36 ? 'py-1.5' : 'py-3', columnClassName(cell.column, 'cell'))}>
                    {flexRender(cell.column.columnDef.cell, cell.getContext())}
                  </div>
                ))}
              </div>
              {expanded && renderRowDetails ? renderRowDetails(original) : null}
            </div>
          )
        })}
      </div>
    </div>
  )
}
