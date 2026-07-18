import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export const THEMES = ['light', 'dark', 'ocean', 'forest', 'violet'] as const
export type ThemeName = (typeof THEMES)[number]
export type Scheme = 'light' | 'dark'

const STORAGE_KEY = '5gpn_theme'

export interface ThemeMeta {
  name: ThemeName
  scheme: Scheme
  swatch: string
}

export const THEME_CATALOG: readonly ThemeMeta[] = [
  { name: 'light', scheme: 'light', swatch: '#0B57D0' },
  { name: 'dark', scheme: 'dark', swatch: '#A8C7FA' },
  { name: 'ocean', scheme: 'light', swatch: '#006A6A' },
  { name: 'forest', scheme: 'light', swatch: '#146C2E' },
  { name: 'violet', scheme: 'light', swatch: '#6750A4' },
]

function isThemeName(value: unknown): value is ThemeName {
  return typeof value === 'string' && (THEMES as readonly string[]).includes(value)
}

function readStoredTheme(): ThemeName {
  if (typeof localStorage === 'undefined') return 'light'
  try {
    const stored = localStorage.getItem(STORAGE_KEY)
    return isThemeName(stored) ? stored : 'light'
  } catch {
    return 'light'
  }
}

interface ThemeContextValue {
  theme: ThemeName
  scheme: Scheme
  setTheme: (theme: ThemeName) => void
}

const ThemeContext = createContext<ThemeContextValue | null>(null)

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setThemeState] = useState<ThemeName>(() => readStoredTheme())
  const scheme = theme === 'dark' ? 'dark' : 'light'

  useEffect(() => {
    document.documentElement.dataset.theme = theme
    document.documentElement.style.colorScheme = scheme
    const meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')
    if (meta) meta.content = getComputedStyle(document.documentElement).getPropertyValue('--md-sys-color-background').trim()
  }, [scheme, theme])

  const setTheme = (next: ThemeName) => {
    setThemeState(next)
    try {
      localStorage.setItem(STORAGE_KEY, next)
    } catch {
      // The active theme remains usable when storage is unavailable.
    }
  }

  const value = useMemo<ThemeContextValue>(() => ({ theme, scheme, setTheme }), [scheme, theme])
  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme(): ThemeContextValue {
  const context = useContext(ThemeContext)
  if (!context) throw new Error('useTheme must be used within a ThemeProvider')
  return context
}
