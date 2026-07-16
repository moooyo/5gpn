import { useMemo } from 'react'
import { ReactECharts, type EChartsCoreOption } from './echarts'

export interface SparklineProps {
  /** Series values, left→right. */
  data: number[]
  /** Line + fill color (fill is drawn at ~12% opacity). */
  color: string
  height?: number
  className?: string
}

/** A tiny trend line with no axes/labels — for inline stat-tile use. */
export function Sparkline({ data, color, height = 32, className }: SparklineProps) {
  const option = useMemo<EChartsCoreOption>(
    () => ({
      animation: false,
      grid: { left: 0, right: 0, top: 2, bottom: 2 },
      xAxis: {
        type: 'category',
        show: false,
        data: data.map((_, i) => i),
        boundaryGap: false,
      },
      yAxis: {
        type: 'value',
        show: false,
        min: 'dataMin',
        max: 'dataMax',
      },
      tooltip: { show: false },
      series: [
        {
          type: 'line',
          data,
          smooth: true,
          symbol: 'none',
          lineStyle: { color, width: 1.5 },
          areaStyle: { color, opacity: 0.12 },
        },
      ],
    }),
    [data, color],
  )

  return <ReactECharts option={option} className={className} style={{ height, width: '100%' }} />
}
