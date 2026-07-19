import { useRef } from 'react'
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
}

function columnFlexStyle<T>(column: Column<T, unknown>): { flex: string } {
  const width = (column.columnDef.meta as { width?: number | string } | undefined)?.width
  if (width === undefined) return { flex: '1 1 0%' }
  const px = typeof width === 'number' ? `${width}px` : width
  return { flex: `0 0 ${px}` }
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
}: VirtualTableProps<T>) {
  const scrollRef = useRef<HTMLDivElement>(null)

  const table = useReactTable({
    data,
    columns,
    getCoreRowModel: getCoreRowModel(),
  })

  const rows = table.getRowModel().rows

  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => rowHeight,
    overscan: 12,
  })

  return (
    <div ref={scrollRef} className={cn('overflow-auto', className)} style={{ height }} data-testid="virtual-scroll">
      {showHeader ? <div className="sticky top-0 z-10 flex bg-surface-container-low">
        {table.getHeaderGroups().map((headerGroup) =>
          headerGroup.headers.map((header) => (
            <div
              key={header.id}
              style={columnFlexStyle(header.column)}
              className="min-w-0 px-4 py-3 text-left text-[10.5px] font-medium tracking-[.04em] text-text-faint"
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
          return (
            <div
              key={row.id}
              className={cn(
                'flex items-center transition-colors hover:bg-surface-container-low',
                showRowDividers && 'border-b border-divider',
              )}
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                right: 0,
                height: rowHeight,
                transform: `translateY(${virtualRow.start}px)`,
              }}
            >
              {row.getVisibleCells().map((cell) => (
                <div key={cell.id} style={columnFlexStyle(cell.column)} className={cn('min-w-0 px-4 text-[12px]', rowHeight <= 36 ? 'py-1.5' : 'py-3')}>
                  {flexRender(cell.column.columnDef.cell, cell.getContext())}
                </div>
              ))}
            </div>
          )
        })}
      </div>
    </div>
  )
}
