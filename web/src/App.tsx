import { useCallback, useEffect, useState } from 'react'
import { api, AuthError, clearToken, getToken, setAuthLostHandler, type Status } from './api'
import { routeFromPath, type Route } from './router'
import { useTheme } from './useTheme'
import { NavRail } from './components/NavRail'
import { TopBar } from './components/TopBar'
import { LoginView } from './views/Login'
import { DashboardView } from './views/Dashboard'
import { SubscriptionsView } from './views/Subscriptions'
import { RulesView } from './views/Rules'
import { LookupView } from './views/Lookup'
import { StatsView } from './views/Stats'

type AuthState = 'checking' | 'in' | 'out'

export function App() {
  const { theme, toggle } = useTheme()
  const [auth, setAuth] = useState<AuthState>(() => (getToken() ? 'checking' : 'out'))
  const [route, setRoute] = useState<Route>(() => routeFromPath(window.location.pathname))
  const [navOpen, setNavOpen] = useState(false)
  const [status, setStatus] = useState<Status | null>(null)

  // SPA routing: react to back/forward and programmatic navigate().
  useEffect(() => {
    const onPop = () => setRoute(routeFromPath(window.location.pathname))
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [])

  // Any 401 from the API client drops us back to Login.
  useEffect(() => {
    setAuthLostHandler(() => setAuth('out'))
    return () => setAuthLostHandler(null)
  }, [])

  // On first mount with a stored token, verify it via GET /api/status.
  useEffect(() => {
    if (auth !== 'checking') return
    let cancelled = false
    api
      .status()
      .then((s) => {
        if (cancelled) return
        setStatus(s)
        setAuth('in')
      })
      .catch((e) => {
        if (cancelled) return
        if (e instanceof AuthError) setAuth('out')
        else setAuth('in') // reachable+authed but transient error; let views retry
      })
    return () => {
      cancelled = true
    }
  }, [auth])

  // While signed in, poll status for the shared top-bar lane bar.
  useEffect(() => {
    if (auth !== 'in') return
    let cancelled = false
    const tick = () => {
      api
        .status()
        .then((s) => {
          if (!cancelled) setStatus(s)
        })
        .catch(() => {
          /* AuthError already handled globally; ignore transient errors here */
        })
    }
    tick()
    const id = window.setInterval(tick, 5000)
    return () => {
      cancelled = true
      window.clearInterval(id)
    }
  }, [auth])

  const onConnected = useCallback((s: Status) => {
    setStatus(s)
    setAuth('in')
  }, [])

  const onDisconnect = useCallback(() => {
    clearToken()
    setStatus(null)
    setAuth('out')
  }, [])

  if (auth === 'checking') {
    return (
      <div className="flex h-full items-center justify-center" style={{ color: 'var(--muted)' }}>
        <span className="font-mono text-sm">Verifying token…</span>
      </div>
    )
  }

  if (auth === 'out') {
    return <LoginView theme={theme} onToggleTheme={toggle} onConnected={onConnected} />
  }

  return (
    <div className="flex h-full w-full overflow-hidden">
      <NavRail active={route} open={navOpen} onClose={() => setNavOpen(false)} />
      <div className="flex min-w-0 flex-1 flex-col">
        <TopBar
          active={route}
          stats={status?.stats ?? null}
          theme={theme}
          onToggleTheme={toggle}
          onDisconnect={onDisconnect}
          onMenu={() => setNavOpen(true)}
        />
        <main className="flex-1 overflow-y-auto p-4 md:p-6">
          <div className="mx-auto max-w-6xl">
            {route === 'dashboard' && <DashboardView status={status} />}
            {route === 'subscriptions' && <SubscriptionsView />}
            {route === 'rules' && <RulesView />}
            {route === 'lookup' && <LookupView />}
            {route === 'stats' && <StatsView />}
          </div>
        </main>
      </div>
    </div>
  )
}
