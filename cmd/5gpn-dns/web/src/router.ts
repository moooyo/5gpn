export type Route = 'dashboard' | 'subscriptions' | 'rules' | 'lookup' | 'stats'

export const ROUTES: { key: Route; label: string; path: string }[] = [
  { key: 'dashboard', label: 'Dashboard', path: '/dashboard' },
  { key: 'subscriptions', label: 'Subscriptions', path: '/subscriptions' },
  { key: 'rules', label: 'Rules', path: '/rules' },
  { key: 'lookup', label: 'Lookup', path: '/lookup' },
  { key: 'stats', label: 'Stats', path: '/stats' },
]

const DEFAULT: Route = 'dashboard'

/** Parse the current window pathname into a Route (deep-link safe). */
export function routeFromPath(pathname: string): Route {
  const seg = pathname.replace(/^\/+/, '').split('/')[0]
  const match = ROUTES.find((r) => r.key === seg)
  return match ? match.key : DEFAULT
}

/** Navigate via History API without a full reload (SPA routing). */
export function navigate(route: Route): void {
  const path = ROUTES.find((r) => r.key === route)?.path ?? '/dashboard'
  if (window.location.pathname !== path) {
    window.history.pushState({}, '', path)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }
}
