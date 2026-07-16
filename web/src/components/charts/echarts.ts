// echarts core-only registration — CSP-safe.
//
// AMENDMENT A-L1: register ONLY `echarts/core` plus the exact renderer/chart/
// component pieces the wrappers in this directory need. NEVER `import
// 'echarts'` (the barrel pulls in every chart/component, including
// Geo/Map, whose coordinate-system code uses `new Function` — that throws
// under this console's strict CSP, which has no `unsafe-eval`). Do NOT
// register `GeoComponent` or `MapChart` here. `CanvasRenderer` is CSP-safe:
// canvas `toDataURL` output is covered by the existing `img-src 'self' data:`
// directive, and canvas rendering itself needs no dynamic code generation.
// `BarChart`/`GaugeChart` (added for the "A档" dashboard cards — upstream
// health bars + cache-hit-rate gauge) are plain series renderers like
// Line/Pie, no coordinate-system risk, same CSP-safe reasoning applies.
import * as echarts from 'echarts/core'
import { BarChart, GaugeChart, LineChart, PieChart } from 'echarts/charts'
import { GridComponent, LegendComponent, TooltipComponent } from 'echarts/components'
import { CanvasRenderer } from 'echarts/renderers'
import type { CSSProperties } from 'react'
import { createElement, useEffect, useRef } from 'react'
import type { ECharts, EChartsCoreOption } from 'echarts/core'

echarts.use([LineChart, PieChart, BarChart, GaugeChart, GridComponent, TooltipComponent, LegendComponent, CanvasRenderer])

export { echarts }
export type { ECharts, EChartsCoreOption }

export interface ReactEChartsProps {
  option: EChartsCoreOption
  style?: CSSProperties
  className?: string
}

/** Minimal typed React wrapper around an `echarts/core` instance. */
export function ReactECharts({ option, style, className }: ReactEChartsProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const chartRef = useRef<ECharts | null>(null)

  // Mount-only: create + dispose the chart instance, and keep it sized to
  // its container via ResizeObserver.
  useEffect(() => {
    const node = containerRef.current
    if (!node) return
    const chart = echarts.init(node)
    chartRef.current = chart

    const resizeObserver = new ResizeObserver(() => chart.resize())
    resizeObserver.observe(node)

    return () => {
      resizeObserver.disconnect()
      chart.dispose()
      chartRef.current = null
    }
  }, [])

  // Re-apply option on every change (also fires once on mount, after the
  // init effect above has run since effects run in declaration order). Clear
  // any lingering tooltip first: a `trigger:'axis'` tooltip left showing from
  // a prior hover would otherwise "stick" over the chart across the 3s poll
  // re-renders (the setOption merge does not dismiss it on its own).
  useEffect(() => {
    chartRef.current?.dispatchAction({ type: 'hideTip' })
    chartRef.current?.setOption(option)
  }, [option])

  return createElement('div', { ref: containerRef, style, className })
}
