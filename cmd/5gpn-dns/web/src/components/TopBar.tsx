import type { Stats } from '../api'
import type { Route } from '../router'
import { ROUTES } from '../router'
import { VerdictLaneBar } from './VerdictLaneBar'

interface TopBarProps {
  active: Route
  stats: Stats | null
  theme: 'dark' | 'light'
  onToggleTheme: () => void
  onDisconnect: () => void
  onMenu: () => void
}

const EYEBROWS: Record<Route, string> = {
  dashboard: 'Overview',
  subscriptions: 'Auto-updating rule lists',
  rules: 'Manual rule entries',
  lookup: 'Classify a name',
  stats: 'Engine counters',
}

/** Sun/moon glyph for the theme toggle. */
function ThemeGlyph({ theme }: { theme: 'dark' | 'light' }) {
  return theme === 'dark' ? (
    <svg width="15" height="15" viewBox="0 0 15 15" fill="none" aria-hidden>
      <path
        d="M13 9.2A5.5 5.5 0 0 1 5.8 2 5.5 5.5 0 1 0 13 9.2Z"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
    </svg>
  ) : (
    <svg width="15" height="15" viewBox="0 0 15 15" fill="none" aria-hidden>
      <circle cx="7.5" cy="7.5" r="3" stroke="currentColor" strokeWidth="1.2" />
      <g stroke="currentColor" strokeWidth="1.2" strokeLinecap="round">
        <path d="M7.5 1v1.5M7.5 12.5V14M1 7.5h1.5M12.5 7.5H14M3 3l1 1M11 11l1 1M12 3l-1 1M4 11l-1 1" />
      </g>
    </svg>
  )
}

export function TopBar({
  active,
  stats,
  theme,
  onToggleTheme,
  onDisconnect,
  onMenu,
}: TopBarProps) {
  const label = ROUTES.find((r) => r.key === active)?.label ?? 'Dashboard'
  return (
    <header
      className="flex items-center gap-3 px-4 py-3 md:px-6"
      style={{ borderBottom: '1px solid var(--border)', background: 'var(--bg)' }}
    >
      <button
        className="btn btn-sm md:hidden"
        onClick={onMenu}
        aria-label="Open navigation"
        style={{ padding: '6px 9px' }}
      >
        ☰
      </button>

      <div className="min-w-0">
        <div className="eyebrow">{EYEBROWS[active]}</div>
        <h1 className="font-display text-base font-semibold leading-tight" style={{ color: 'var(--text)' }}>
          {label}
        </h1>
      </div>

      <div className="ml-auto flex items-center gap-3">
        {stats && (
          <div className="hidden sm:block" title="Live verdict split (direct / proxy / block)">
            <VerdictLaneBar stats={stats} size="mini" />
          </div>
        )}
        <button
          className="btn btn-sm"
          onClick={onToggleTheme}
          aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} theme`}
          style={{ padding: '7px 9px' }}
        >
          <ThemeGlyph theme={theme} />
        </button>
        <button className="btn btn-sm btn-danger" onClick={onDisconnect}>
          Disconnect
        </button>
      </div>
    </header>
  )
}
