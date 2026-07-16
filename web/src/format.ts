import { useEffect, useRef, useState } from 'react'
import i18n from './i18n'

/** Humanize a duration in seconds to e.g. "3d 4h 12m" (uptime display). */
export function humanizeUptime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return '—'
  const s = Math.floor(seconds)
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  const parts: string[] = []
  if (d) parts.push(i18n.t('format.uptimeD', { count: d }))
  if (h) parts.push(i18n.t('format.uptimeH', { count: h }))
  if (m) parts.push(i18n.t('format.uptimeM', { count: m }))
  if (!d && !h) parts.push(i18n.t('format.uptimeS', { count: sec }))
  return parts.join(' ') || i18n.t('format.uptimeS', { count: 0 })
}

/** Group a large integer with thin separators, e.g. 12345 -> "12,345". */
export function fmtInt(n: number): string {
  if (!Number.isFinite(n)) return '—'
  return Math.round(n).toLocaleString(i18n.language || 'en')
}

/** A percentage string for a ratio of ok/(ok+err), or "—" when no samples. */
export function successRatio(ok: number, err: number): string {
  const total = ok + err
  if (total === 0) return '—'
  return `${((ok / total) * 100).toFixed(1)}%`
}

/**
 * A compact relative time from an RFC3339/ISO timestamp to now, e.g. "just
 * now", "2m ago", "3h ago", "5d ago". Returns "—" for a missing or unparseable
 * value. Future timestamps read as "just now".
 */
export function relativeTime(iso: string | undefined | null): string {
  if (!iso) return '—'
  const t = Date.parse(iso)
  if (!Number.isFinite(t)) return '—'
  const diffMs = Date.now() - t
  const sec = Math.floor(diffMs / 1000)
  if (sec < 45) return i18n.t('format.justNow')
  const min = Math.floor(sec / 60)
  if (min < 60) return i18n.t('format.mAgo', { count: min })
  const hr = Math.floor(min / 60)
  if (hr < 24) return i18n.t('format.hAgo', { count: hr })
  const day = Math.floor(hr / 24)
  return i18n.t('format.dAgo', { count: day })
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
