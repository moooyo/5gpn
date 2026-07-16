import { useMemo } from 'react'
import { ReactECharts, type EChartsCoreOption } from './echarts'

export interface DualAreaChartProps {
  /** 下行 (download) series values, left→right. */
  down: number[]
  /** 上行 (upload) series values, left→right. */
  up: number[]
  height?: number
  /** x-axis category labels; defaults to numeric time ticks (0..n-1). */
  labels?: string[]
  className?: string
  /** Localized series names (tooltip only — the built-in ECharts legend is
   *  always hidden below since the caller renders its own localized legend
   *  row). Defaults to empty when omitted. */
  downName?: string
  upName?: string
}

const DOWN_COLOR = '#2563eb'
const UP_COLOR = '#38bdf8'

/** Two stacked-line traffic series (down/up) with a shared time axis. */
export function DualAreaChart({ down, up, height = 164, labels, className, downName = '', upName = '' }: DualAreaChartProps) {
  const option = useMemo<EChartsCoreOption>(() => {
    const categories = labels ?? down.map((_, i) => String(i))
    return {
      animation: false,
      // The OverviewPage already renders its own localized legend row next
      // to this chart — the built-in ECharts legend would just duplicate it
      // (and previously hardcoded Chinese series names regardless of locale).
      legend: { show: false },
      grid: { left: 8, right: 8, top: 12, bottom: 20, containLabel: true },
      tooltip: { trigger: 'axis', confine: true },
      xAxis: {
        type: 'category',
        data: categories,
        boundaryGap: false,
        axisTick: { show: false },
        axisLine: { show: false },
      },
      yAxis: {
        type: 'value',
        splitNumber: 3,
        splitLine: { lineStyle: { type: 'dashed' } },
        axisLine: { show: false },
        axisTick: { show: false },
      },
      series: [
        {
          name: downName,
          type: 'line',
          data: down,
          smooth: true,
          symbol: 'none',
          lineStyle: { color: DOWN_COLOR, width: 1.5 },
          areaStyle: { color: DOWN_COLOR, opacity: 0.12 },
        },
        {
          name: upName,
          type: 'line',
          data: up,
          smooth: true,
          symbol: 'none',
          lineStyle: { color: UP_COLOR, width: 1.5 },
          areaStyle: { color: UP_COLOR, opacity: 0.12 },
        },
      ],
    }
  }, [down, up, labels, downName, upName])

  return <ReactECharts option={option} className={className} style={{ height, width: '100%' }} />
}
