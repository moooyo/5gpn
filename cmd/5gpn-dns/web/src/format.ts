import { useEffect, useRef, useState } from 'react'

/** Humanize a duration in seconds to e.g. "3d 4h 12m" (uptime display). */
export function humanizeUptime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '—'
  const s = Math.floor(seconds)
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  const parts: string[] = []
  if (d) parts.push(`${d}d`)
  if (h) parts.push(`${h}h`)
  if (m) parts.push(`${m}m`)
  if (!d && !h) parts.push(`${sec}s`)
  return parts.join(' ') || '0s'
}

/** Group a large integer with thin separators, e.g. 12345 -> "12,345". */
export function fmtInt(n: number): string {
  if (!Number.isFinite(n)) return '—'
  return Math.round(n).toLocaleString('en-US')
}

/** A percentage string for a ratio of ok/(ok+err), or "—" when no samples. */
export function successRatio(ok: number, err: number): string {
  const total = ok + err
  if (total === 0) return '—'
  return `${((ok / total) * 100).toFixed(1)}%`
}

function prefersReducedMotion(): boolean {
  return (
    typeof window !== 'undefined' &&
    window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches
  )
}

/**
 * A subtle count-up toward `value` on mount / when value changes. Honors
 * prefers-reduced-motion (snaps straight to the value). Used for stat numbers.
 */
export function useCountUp(value: number, durationMs = 650): number {
  const [display, setDisplay] = useState(value)
  const fromRef = useRef(value)
  const rafRef = useRef<number>(0)

  useEffect(() => {
    if (prefersReducedMotion()) {
      setDisplay(value)
      fromRef.current = value
      return
    }
    const from = fromRef.current
    const to = value
    if (from === to) {
      setDisplay(to)
      return
    }
    const start = performance.now()
    const tick = (now: number) => {
      const t = Math.min(1, (now - start) / durationMs)
      // easeOutCubic
      const eased = 1 - Math.pow(1 - t, 3)
      setDisplay(from + (to - from) * eased)
      if (t < 1) {
        rafRef.current = requestAnimationFrame(tick)
      } else {
        fromRef.current = to
      }
    }
    rafRef.current = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(rafRef.current)
  }, [value, durationMs])

  return display
}
