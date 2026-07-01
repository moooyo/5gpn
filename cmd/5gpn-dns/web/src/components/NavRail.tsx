import { ROUTES, navigate, type Route } from '../router'

/** The signal glyph in the wordmark — a small stacked-signal mark. */
function SignalGlyph() {
  return (
    <svg width="18" height="18" viewBox="0 0 18 18" fill="none" aria-hidden>
      <rect x="1" y="10" width="3" height="6" rx="1" fill="var(--v-block)" />
      <rect x="6" y="6" width="3" height="10" rx="1" fill="var(--v-proxy)" />
      <rect x="11" y="2" width="3" height="14" rx="1" fill="var(--v-direct)" />
    </svg>
  )
}

/** The three configured ingress transports — labeled dots, NOT live-probed. */
function TransportsStrip() {
  const transports = [
    { label: 'DoT', port: ':853', color: 'var(--v-direct)' },
    { label: 'DoH', port: ':8443', color: 'var(--v-proxy)' },
    { label: 'Plain', port: ':53', color: 'var(--v-adblock)' },
  ]
  return (
    <div className="mt-auto px-3 pb-4 pt-3" style={{ borderTop: '1px solid var(--border)' }}>
      <div className="eyebrow mb-2.5 px-1">Ingress · configured</div>
      <ul className="flex flex-col gap-2">
        {transports.map((t) => (
          <li key={t.label} className="flex items-center gap-2.5 px-1">
            <span
              className="dot-live inline-block h-2 w-2 shrink-0 rounded-full"
              style={{ background: t.color, color: t.color }}
            />
            <span className="font-mono text-xs" style={{ color: 'var(--text)' }}>
              {t.label}
            </span>
            <span className="font-mono text-xs" style={{ color: 'var(--muted)' }}>
              {t.port}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

interface NavRailProps {
  active: Route
  open: boolean
  onClose: () => void
}

/** Fixed left nav rail (~210px). Collapses to an overlay drawer on mobile. */
export function NavRail({ active, open, onClose }: NavRailProps) {
  return (
    <>
      {/* Mobile backdrop */}
      {open && (
        <div
          className="fixed inset-0 z-30 bg-black/50 md:hidden"
          onClick={onClose}
          aria-hidden
        />
      )}
      <nav
        className={[
          'fixed z-40 flex h-full w-[210px] flex-col md:static md:z-auto md:translate-x-0',
          'transition-transform duration-200',
          open ? 'translate-x-0' : '-translate-x-full',
        ].join(' ')}
        style={{ background: 'var(--surface)', borderRight: '1px solid var(--border)' }}
        aria-label="Primary"
      >
        <div className="flex items-center gap-2.5 px-4 pb-5 pt-5">
          <SignalGlyph />
          <span
            className="font-display text-base font-bold"
            style={{ letterSpacing: '0.02em', color: 'var(--text)' }}
          >
            5gpn-dns
          </span>
        </div>

        <ul className="flex flex-col gap-0.5 px-3">
          {ROUTES.map((r) => {
            const isActive = r.key === active
            return (
              <li key={r.key}>
                <button
                  onClick={() => {
                    navigate(r.key)
                    onClose()
                  }}
                  aria-current={isActive ? 'page' : undefined}
                  className="flex w-full items-center gap-2 rounded-panel px-3 py-2 text-left transition-colors"
                  style={{
                    background: isActive ? 'var(--surface-2)' : 'transparent',
                    color: isActive ? 'var(--accent)' : 'var(--muted)',
                    fontFamily: '"Space Grotesk", system-ui, sans-serif',
                    fontWeight: 600,
                    fontSize: 13,
                    letterSpacing: '0.03em',
                  }}
                >
                  <span
                    className="inline-block h-4 w-[3px] rounded-full"
                    style={{ background: isActive ? 'var(--accent)' : 'transparent' }}
                    aria-hidden
                  />
                  {r.label}
                </button>
              </li>
            )
          })}
        </ul>

        <TransportsStrip />
      </nav>
    </>
  )
}
