import { useState } from 'react'
import { Outlet, useLocation } from 'react-router-dom'
import * as DialogPrimitive from '@radix-ui/react-dialog'
import { useTranslation } from 'react-i18next'
import { Sidebar } from './Sidebar'
import { Topbar } from './Topbar'
import { StatusProvider } from '../lib/StatusContext'

/** Root layout route: Sidebar + Topbar chrome around the routed page body.
 *  Wrapped in its own StatusProvider so the Sidebar's kernel status dots can
 *  poll independently of whatever page is mounted in the Outlet. */
export function AppShell() {
  const { pathname } = useLocation()
  const { t } = useTranslation()
  const [mobileNavOpen, setMobileNavOpen] = useState(false)
  return (
    <StatusProvider>
      <div className="w-screen h-screen flex bg-bg text-text-strong overflow-hidden">
        <Sidebar className="hidden md:flex" testId="desktop-sidebar" />
        <DialogPrimitive.Root open={mobileNavOpen} onOpenChange={setMobileNavOpen}>
          <DialogPrimitive.Portal>
            <DialogPrimitive.Overlay className="fixed inset-0 z-50 bg-[rgba(16,24,40,.42)] md:hidden" />
            <DialogPrimitive.Content
              id="mobile-navigation"
              aria-describedby={undefined}
              className="fixed inset-y-0 left-0 z-50 w-[min(85vw,236px)] outline-none md:hidden"
              data-testid="mobile-sidebar-drawer"
            >
              <DialogPrimitive.Title className="sr-only">{t('nav.primary')}</DialogPrimitive.Title>
              <Sidebar
                className="h-full w-full"
                onNavigate={() => setMobileNavOpen(false)}
                onClose={() => setMobileNavOpen(false)}
              />
            </DialogPrimitive.Content>
          </DialogPrimitive.Portal>
        </DialogPrimitive.Root>
        <div className="flex-1 flex flex-col min-w-0">
          <Topbar onOpenNavigation={() => setMobileNavOpen(true)} />
          <main className="flex-1 overflow-y-auto p-3 sm:p-[22px_24px]">
            {/* Keyed by route so the page-enter animation replays on every tab
                switch: changing the pathname remounts this wrapper, which
                re-triggers `ds-page-in` for the freshly mounted page body. */}
            <div key={pathname} className="ds-page-in mx-auto max-w-[1180px]">
              <Outlet />
            </div>
          </main>
        </div>
      </div>
    </StatusProvider>
  )
}
