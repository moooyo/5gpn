import { useMemo } from 'react'
import { ReactECharts, type EChartsCoreOption } from './echarts'

export interface BarSeries {
  /** Localized series name — tooltip only, the built-in legend is always
   *  hidden below (callers render their own legend, matching `DualAreaChart`). */
  name: string
  data: number[]
  color: string
}

export interface BarChartProps {
  /** x-axis category labels, one per group (e.g. china/trust). */
  categories: string[]
  series: BarSeries[]
  height?: number
  className?: string
}

/** A grouped bar chart (N named series across shared categories) — for the
 *  上游健康与延迟 card's ok/err counts per upstream group. Mirrors
 *  `DualAreaChart`'s shape (own legend, hidden built-in one, shared grid/axis
 *  styling) with `type: 'bar'` series instead of `'line'`. */
export function BarChart({ categories, series, height = 160, className }: BarChartProps) {
  const option = useMemo<EChartsCoreOption>(
    () => ({
      animation: false,
      legend: { show: false },
      grid: { left: 8, right: 8, top: 12, bottom: 20, containLabel: true },
      tooltip: { trigger: 'axis', confine: true, axisPointer: { type: 'shadow' } },
      xAxis: {
        type: 'category',
        data: categories,
        axisTick: { show: false },
        axisLine: { show: false },
      },
      yAxis: {
        type: 'value',
        splitNumber: 3,
        minInterval: 1,
        splitLine: { lineStyle: { type: 'dashed' } },
        axisLine: { show: false },
        axisTick: { show: false },
        // Hidden: the tiny count numbers pushed the plot area right and threw
        // the per-bar labels below out of alignment; the dashed splitlines +
        // tooltip convey the scale. Keeps the two bars symmetric so the
        // latency labels (grid-cols-2) sit centered under each.
        axisLabel: { show: false },
      },
      series: series.map((s) => ({
        name: s.name,
        type: 'bar',
        data: s.data,
        barMaxWidth: 28,
        itemStyle: { color: s.color, borderRadius: [4, 4, 0, 0] },
      })),
    }),
    [categories, series],
  )

  return <ReactECharts option={option} className={className} style={{ height, width: '100%' }} />
}
