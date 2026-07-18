import { useState } from 'react'
import {
  type ColumnDef,
  type SortingState,
  flexRender,
  getCoreRowModel,
  getPaginationRowModel,
  getSortedRowModel,
  useReactTable,
} from '@tanstack/react-table'
import { ChevronDownIcon, ChevronUpIcon } from '../icons'
import { cn } from '../../lib/cn'
import { Pagination } from './Pagination'

export interface DataGridProps<T> {
  columns: ColumnDef<T, any>[]
  data: T[]
  className?: string
  emptyText?: string
  /** When set, the grid paginates internally at this page size, renders a
   *  footer once there is more than one page, and pads short pages with filler
   *  rows so the card height stays stable. Omit for the unpaginated behavior. */
  pageSize?: number
}

/**
 * Small/medium table primitive (rules, subscriptions, resolve-test probes).
 * Renders a real `<table>` — not virtualized. See `VirtualTable` for large,
 * scroll-heavy lists (query log). Optional internal pagination via `pageSize`.
 */
export function DataGrid<T>({ columns, data, className, emptyText = 'No data', pageSize }: DataGridProps<T>) {
  const [sorting, setSorting] = useState<SortingState>([])
  const paginated = pageSize != null

  const table = useReactTable({
    data,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
    ...(paginated
      ? { getPaginationRowModel: getPaginationRowModel(), initialState: { pagination: { pageIndex: 0, pageSize } } }
      : {}),
  })

  const columnCount = table.getAllLeafColumns().length
  const leafColumns = table.getAllLeafColumns()
  const pageCount = paginated ? table.getPageCount() : 1
  const rawPageIndex = table.getState().pagination.pageIndex
  // @tanstack/react-table's own autoResetPageIndex clamps the page index
  // asynchronously (via a queued microtask), which lags one tick behind a
  // synchronous data shrink and would otherwise render an out-of-range
  // (empty) page for a frame. Clamp synchronously here instead: calling a
  // state setter conditionally during render is the officially-supported
  // React pattern for adjusting derived state — React re-invokes this
  // render immediately with the corrected value, no extra tick needed.
  if (paginated && rawPageIndex > 0 && rawPageIndex >= pageCount) {
    table.setPageIndex(Math.max(0, pageCount - 1))
  }
  const pageIndex = table.getState().pagination.pageIndex
  const pageRows = table.getRowModel().rows
  const fillerCount = paginated && pageCount > 1 ? Math.max(0, (pageSize as number) - pageRows.length) : 0

  return (
    <>
      <table className={cn('w-full table-fixed border-collapse text-left', className)}>
        {/* Fixed layout + an explicit colgroup so a column's width comes from
            its `meta.width`, NOT the widest cell on the CURRENT page — otherwise
            the same column visibly jumps between pages as the content changes
            (e.g. short vs long domains). Columns without a meta.width share the
            remaining space. */}
        <colgroup>
          {leafColumns.map((col) => {
            const width = (col.columnDef.meta as { width?: number | string } | undefined)?.width
            const w = width === undefined ? undefined : typeof width === 'number' ? `${width}px` : width
            return <col key={col.id} style={w ? { width: w } : undefined} />
          })}
        </colgroup>
        <thead className="bg-surface-container-low">
          {table.getHeaderGroups().map((headerGroup) => (
            <tr key={headerGroup.id}>
              {headerGroup.headers.map((header) => {
                const canSort = header.column.getCanSort()
                const sorted = header.column.getIsSorted()
                const label = header.isPlaceholder
                  ? null
                  : flexRender(header.column.columnDef.header, header.getContext())

                return (
                  <th
                    key={header.id}
                    className="px-4 py-3 text-left text-[10.5px] font-medium tracking-[.04em] text-text-faint"
                    aria-sort={canSort ? (sorted === 'asc' ? 'ascending' : sorted === 'desc' ? 'descending' : 'none') : undefined}
                  >
                    {canSort ? (
                      <button
                        type="button"
                        onClick={header.column.getToggleSortingHandler()}
                        className="inline-flex cursor-pointer items-center gap-1"
                      >
                        {label}
                        {sorted === 'asc' && <ChevronUpIcon className="h-3.5 w-3.5" aria-hidden="true" />}
                        {sorted === 'desc' && <ChevronDownIcon className="h-3.5 w-3.5" aria-hidden="true" />}
                      </button>
                    ) : (
                      label
                    )}
                  </th>
                )
              })}
            </tr>
          ))}
        </thead>
        <tbody>
          {data.length === 0 ? (
            <tr>
              <td colSpan={columnCount} className="px-4 py-8 text-center text-[12px] text-text-faint">
                {emptyText}
              </td>
            </tr>
          ) : (
            <>
              {pageRows.map((row) => (
                <tr key={row.id} className="border-b border-divider transition-colors hover:bg-surface-container-low">
                  {row.getVisibleCells().map((cell) => (
                    <td key={cell.id} className="px-4 py-3 text-[12px]">
                      {flexRender(cell.column.columnDef.cell, cell.getContext())}
                    </td>
                  ))}
                </tr>
              ))}
              {Array.from({ length: fillerCount }, (_, i) => (
                <tr key={`filler-${i}`} data-testid="datagrid-filler" aria-hidden="true" className="border-b border-divider">
                  <td colSpan={columnCount} className="px-4 py-3 text-[12px]">
                    &nbsp;
                  </td>
                </tr>
              ))}
            </>
          )}
        </tbody>
      </table>
      {paginated && pageCount > 1 ? (
        <Pagination
          page={pageIndex + 1}
          pageCount={pageCount}
          onPageChange={(p) => table.setPageIndex(p - 1)}
        />
      ) : null}
    </>
  )
}
