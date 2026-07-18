import { lazy, Suspense, useState } from 'react'
import { Outlet, useLocation } from 'react-router-dom'
import { Sidebar } from './Sidebar'
import { Topbar } from './Topbar'
import { StatusProvider } from '../lib/StatusContext'

const MobileNavigation = lazy(() => import('./MobileNavigation'))

export function AppShell() {
  const { pathname } = useLocation()
  const [mobileNavOpen, setMobileNavOpen] = useState(false)

  return (
    <StatusProvider>
      <div className="flex h-dvh w-screen overflow-hidden bg-bg text-text-strong">
        <Sidebar className="hidden md:flex" testId="desktop-sidebar" />
        {mobileNavOpen ? (
          <Suspense fallback={<div className="zds-dialog-backdrop md:hidden" />}>
            <MobileNavigation open={mobileNavOpen} onOpenChange={setMobileNavOpen} />
          </Suspense>
        ) : null}

        <div className="flex min-w-0 flex-1 flex-col">
          <Topbar onOpenNavigation={() => setMobileNavOpen(true)} />
          <main className="flex-1 overflow-y-auto px-3 pb-10 pt-2 sm:px-5 sm:pt-3 lg:px-7">
            <div key={pathname} className="ds-page-in mx-auto w-full max-w-[1200px]">
              <Outlet />
            </div>
          </main>
        </div>
      </div>
    </StatusProvider>
  )
}
