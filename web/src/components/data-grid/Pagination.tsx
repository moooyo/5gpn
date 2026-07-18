import { useTranslation } from 'react-i18next'
import { ChevronLeftIcon, ChevronRightIcon } from '../icons'
import { cn } from '../../lib/cn'

export interface PaginationProps {
  /** 1-based current page. */
  page: number
  pageCount: number
  onPageChange: (page: number) => void
  className?: string
}

/** Compact table pagination footer: 上一页 · 第 X / Y 页 · 下一页. Presentational
 *  only — the owning table computes page/pageCount and handles the change. */
export function Pagination({ page, pageCount, onPageChange, className }: PaginationProps) {
  const { t } = useTranslation()
  const canPrev = page > 1
  const canNext = page < pageCount
  const btn =
    'zds-state-layer inline-flex h-8 items-center gap-1 rounded-full px-3 text-[11.5px] text-text-soft outline-none disabled:opacity-40'
  return (
    <div className={cn('flex items-center justify-end gap-2 border-t border-divider px-4 py-2', className)}>
      <button
        type="button"
        data-testid="pagination-prev"
        disabled={!canPrev}
        onClick={() => onPageChange(page - 1)}
        className={btn}
      >
        <ChevronLeftIcon className="h-3.5 w-3.5" aria-hidden="true" />
        {t('common.pagePrev')}
      </button>
      <span data-testid="pagination-status" className="font-mono text-[11px] tabular-nums text-text-faint">
        {t('common.pageOf', { page, count: pageCount })}
      </span>
      <button
        type="button"
        data-testid="pagination-next"
        disabled={!canNext}
        onClick={() => onPageChange(page + 1)}
        className={btn}
      >
        {t('common.pageNext')}
        <ChevronRightIcon className="h-3.5 w-3.5" aria-hidden="true" />
      </button>
    </div>
  )
}
