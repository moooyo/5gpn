import { useMemo } from 'react'
import { ReactECharts, type EChartsCoreOption } from './echarts'
import { cn } from '../../lib/cn'

export interface DonutSegment {
  name: string
  value: number
  color: string
}

export interface DonutChartProps {
  segments: DonutSegment[]
  height?: number
  /** Ring width. Defaults to `'100%'` (fill the parent). Pass a fixed number
   *  when the donut sits INLINE next to a legend in a flex row — a `'100%'`
   *  width there would greedily claim the whole row and collapse the legend to
   *  a single-character ellipsis. A square (`width === height`) reads best. */
  width?: number | string
  /** Optional text rendered in the donut's hole (e.g. a total). */
  centerLabel?: string
  className?: string
}

/** A ring chart with no per-slice labels — callers render their own legend.
 *  The center label is an absolutely-positioned HTML overlay, NOT an ECharts
 *  `title` — ECharts' `title.textStyle` has no color set, so it rendered
 *  near-black (unreadable on a dark card); the HTML span re-themes
 *  automatically via `text-text-strong`'s CSS var. */
export function DonutChart({ segments, height = 90, width = '100%', centerLabel, className }: DonutChartProps) {
  const option = useMemo<EChartsCoreOption>(
    () => ({
      animation: false,
      tooltip: { trigger: 'item', confine: true },
      series: [
        {
          type: 'pie',
          radius: ['62%', '86%'],
          avoidLabelOverlap: false,
          label: { show: false },
          labelLine: { show: false },
          emphasis: { scale: false },
          data: segments.map((segment) => ({
            name: segment.name,
            value: segment.value,
            itemStyle: { color: segment.color },
          })),
        },
      ],
    }),
    [segments],
  )

  return (
    <div className={cn('relative', className)} style={{ height, width }}>
      <ReactECharts option={option} style={{ height: '100%', width: '100%' }} />
      {centerLabel !== undefined ? (
        <span className="pointer-events-none absolute inset-0 flex items-center justify-center text-[13px] font-semibold text-text-strong">
          {centerLabel}
        </span>
      ) : null}
    </div>
  )
}
