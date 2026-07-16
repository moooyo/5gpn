import { useMemo } from 'react'
import { ReactECharts, type EChartsCoreOption } from './echarts'
import { cn } from '../../lib/cn'

export interface GaugeChartProps {
  /** 0–100 value (percentage). Clamped into range; non-finite treated as 0. */
  value: number
  height?: number
  width?: number | string
  /** Progress-arc color. */
  color?: string
  className?: string
}

/** A 0–100% progress arc — for the 缓存命中率 card. Mirrors `DonutChart`'s
 *  center-label approach: the percentage is an absolutely-positioned HTML
 *  overlay, NOT ECharts' own `detail` text, since `detail.color` is a fixed
 *  canvas-rendered value (no CSS var), same unreadable-on-dark-theme problem
 *  `DonutChart`'s `title` had. */
export function GaugeChart({ value, height = 140, width = '100%', color = '#16a34a', className }: GaugeChartProps) {
  const clamped = Number.isFinite(value) ? Math.min(100, Math.max(0, value)) : 0

  const option = useMemo<EChartsCoreOption>(
    () => ({
      animation: false,
      series: [
        {
          type: 'gauge',
          startAngle: 210,
          endAngle: -30,
          min: 0,
          max: 100,
          radius: '90%',
          pointer: { show: false },
          progress: { show: true, width: 12, itemStyle: { color } },
          axisLine: { lineStyle: { width: 12, color: [[1, 'rgba(148,163,184,0.18)']] } },
          axisTick: { show: false },
          splitLine: { show: false },
          axisLabel: { show: false },
          anchor: { show: false },
          title: { show: false },
          detail: { show: false },
          data: [{ value: clamped }],
        },
      ],
    }),
    [clamped, color],
  )

  return (
    <div className={cn('relative', className)} style={{ height, width }}>
      <ReactECharts option={option} style={{ height: '100%', width: '100%' }} />
      <span className="pointer-events-none absolute inset-0 flex items-center justify-center text-[22px] font-extrabold tracking-tight text-text-strong">
        {`${Math.round(clamped)}%`}
      </span>
    </div>
  )
}
