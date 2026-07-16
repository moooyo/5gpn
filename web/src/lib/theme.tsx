import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export type ThemePref = 'light' | 'dark' | 'system'
export type Scheme = 'light' | 'dark'

const STORAGE_KEY = '5gpn_theme'
const MEDIA_QUERY = '(prefers-color-scheme: dark)'

function readStoredPref(): ThemePref {
  if (typeof localStorage === 'undefined') return 'system'
  const v = localStorage.getItem(STORAGE_KEY)
  return v === 'light' || v === 'dark' || v === 'system' ? v : 'system'
}

function systemPrefersDark(): boolean {
  if (typeof matchMedia !== 'function') return false
  return matchMedia(MEDIA_QUERY).matches
}

interface ThemeContextValue {
  theme: ThemePref
  scheme: Scheme
  setTheme: (pref: ThemePref) => void
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [pref, setPref] = useState<ThemePref>(() => readStoredPref())
  // Tracked in STATE (not just read once via resolveScheme) so a live OS
  // scheme flip while `pref === 'system'` updates `useTheme().scheme` itself,
  // not just the DOM — a consumer reading `scheme` used to see a stale value
  // after the flip even though the document's data-theme attribute (written
  // out-of-band by the listener below) had already changed.
  const [systemDark, setSystemDark] = useState<boolean>(() => systemPrefersDark())
  const scheme = useMemo<Scheme>(() => (pref === 'system' ? (systemDark ? 'dark' : 'light') : pref), [pref, systemDark])

  // The single DOM-write site: both a pref change and a system-scheme flip
  // funnel through `scheme`, so nothing else writes document.dataset.theme.
  useEffect(() => {
    if (typeof document !== 'undefined') {
      document.documentElement.dataset.theme = scheme
    }
  }, [scheme])

  // Track OS/browser scheme changes in state (not just an out-of-band DOM
  // write) so `useTheme().scheme` stays consistent after a live flip.
  useEffect(() => {
    if (typeof matchMedia !== 'function') return
    const mql = matchMedia(MEDIA_QUERY)
    const onChange = () => setSystemDark(mql.matches)
    mql.addEventListener('change', onChange)
    return () => mql.removeEventListener('change', onChange)
  }, [])

  const setTheme = (next: ThemePref) => {
    setPref(next)
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(STORAGE_KEY, next)
    }
  }

  const value = useMemo<ThemeContextValue>(() => ({ theme: pref, scheme, setTheme }), [pref, scheme])

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  const ctx = useContext(ThemeContext)
  if (!ctx) throw new Error('useTheme must be used within a ThemeProvider')
  return ctx
}
