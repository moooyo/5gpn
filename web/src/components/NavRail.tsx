import { useEffect, useRef } from 'react'
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

/** Matches the Tailwind `md` breakpoint — below this the rail is an overlay
 *  drawer, at/above it the rail is a static column. */
const MOBILE_QUERY = '(max-width: 767px)'

/**
 * Drawer accessibility, applied ONLY while the rail is an open mobile overlay:
 *   - Escape closes it.
 *   - Tab focus is trapped inside the drawer.
 *   - On open, focus moves into the drawer; on close, focus returns to the
 *     element that opened it (the ☰ trigger, which had focus at open time).
 * On desktop (static rail) none of this applies — the effect is a no-op.
 */
function useDrawerA11y(
  open: boolean,
  onClose: () => void,
  navRef: React.RefObject<HTMLElement>,
) {
  const restoreRef = useRef<HTMLElement | null>(null)

  useEffect(() => {
    const isMobile =
      typeof window !== 'undefined' && window.matchMedia
        ? window.matchMedia(MOBILE_QUERY).matches
        : false
    if (!open || !isMobile) return

    const nav = navRef.current
    if (!nav) return

    // Remember what opened the drawer so we can return focus on close.
    restoreRef.current = document.activeElement as HTMLElement | null

    const focusables = () =>
      Array.from(
        nav.querySelectorAll<HTMLElement>(
          'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((el) => el.offsetParent !== null || el === document.activeElement)

    // Move focus into the drawer.
    focusables()[0]?.focus()

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
        return
      }
      if (e.key !== 'Tab') return
      const list = focusables()
      if (list.length === 0) return
      const first = list[0]
      const last = list[list.length - 1]
      const activeEl = document.activeElement as HTMLElement | null
      if (e.shiftKey) {
        if (activeEl === first || !nav.contains(activeEl)) {
          e.preventDefault()
          last.focus()
        }
      } else {
        if (activeEl === last || !nav.contains(activeEl)) {
          e.preventDefault()
          first.focus()
        }
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      // Return focus to the trigger when the drawer closes.
      restoreRef.current?.focus?.()
    }
  }, [open, onClose, navRef])
}

/** Fixed left nav rail (~210px). Collapses to an overlay drawer on mobile. */
export function NavRail({ active, open, onClose }: NavRailProps) {
  const navRef = useRef<HTMLElement>(null)
  useDrawerA11y(open, onClose, navRef)

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
        ref={navRef}
        className={[
          'fixed z-40 flex h-full w-[210px] flex-col md:static md:z-auto md:translate-x-0',
          'transition-transform duration-200',
          open ? 'translate-x-0' : '-translate-x-full',
        ].join(' ')}
        style={{ background: 'var(--surface)', borderRight: '1px solid var(--border)' }}
        // When it's an open mobile overlay it's a modal dialog; the desktop
        // static rail is just a landmark. `md:hidden`-scoped semantics can't be
        // expressed in markup, so we always expose the dialog role but it only
        // behaves modally (Esc / focus-trap) on mobile via useDrawerA11y.
        role={open ? 'dialog' : undefined}
        aria-modal={open ? true : undefined}
        aria-label={open ? 'Navigation menu' : 'Primary'}
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
