import { useEffect, useState } from 'react'

function matches(query: string): boolean {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return false
  return window.matchMedia(query).matches
}

/**
 * Tracks whether a CSS media query currently matches, re-evaluating on
 * change. Used for JS-side responsive swaps (e.g. table vs. card rows) where
 * a pure CSS show/hide would double-mount both variants. Defaults to `false`
 * (desktop) when `matchMedia` is unavailable — jsdom's test stub always
 * returns `matches: false`, so component tests deterministically exercise
 * the desktop path unless a test explicitly stubs a match.
 */
export function useMediaQuery(query: string): boolean {
  const [matched, setMatched] = useState<boolean>(() => matches(query))

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const mql = window.matchMedia(query)
    const onChange = () => setMatched(mql.matches)
    onChange()
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [query])

  return matched
}
