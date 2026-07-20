import { lazy, Suspense, type ComponentType } from 'react'
import { createBrowserRouter, Navigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { AppShell } from './AppShell'
import { ALL_NAV_ITEMS } from './navigation'

/** Lightweight loading fallback shown while a route chunk downloads. Kept
 *  tiny and dependency-free so it never itself needs code-splitting. */
function PageSpinner() {
  const { t } = useTranslation()
  return <div className="p-8 text-center text-sm text-text-faint">{t('common.loading')}</div>
}

/** Wraps a route-lazy page loader in its own Suspense boundary. Every page
 *  loads this way so its JS —
 *  and its heavier deps (TanStack Table/Virtual, Base UI overlays, …) — code-splits into a
 *  dynamic chunk instead of the entry graph. This is what keeps the initial
 *  bundle within the budget checked by scripts/check-bundle.mjs: the entry
 *  only has to carry the AppShell chrome + shared libs, never page bodies. */
function lazyPage(loader: () => Promise<{ default: ComponentType }>) {
  const LazyComponent = lazy(loader)
  return (
    <Suspense fallback={<PageSpinner />}>
      <LazyComponent />
    </Suspense>
  )
}

/** Client-side router derived from the shared navigation manifest. Page
 * loaders stay keyed by id here to retain per-route code splitting; paths are
 * never duplicated. The daemon serves the SPA with history fallback. */
const PAGE_LOADERS: Record<string, () => Promise<{ default: ComponentType }>> = {
  overview: () => import('../features/overview/OverviewPage'),
  'setup-guide': () => import('../features/setup-guide/SetupGuidePage'),
  logs: () => import('../features/logs/LogsPage'),
  'resolve-test': () => import('../features/resolve-test/ResolveTestPage'),
  'policy-rules': () => import('../features/policy-rules/PolicyRulesPage'),
  extensions: () => import('../features/extensions/ExtensionsPage'),
  marketplace: () => import('../features/marketplace/MarketplacePage'),
  mihomo: () => import('../features/mihomo/MihomoPage'),
  'mihomo-config': () => import('../features/mihomo-config/MihomoConfigPage'),
  settings: () => import('../features/settings/SettingsPage'),
}

export const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    children: [
      { index: true, element: <Navigate to="/overview" replace /> },
      ...ALL_NAV_ITEMS.map((item) => ({
        path: item.path.replace(/^\//, ''),
        element: lazyPage(PAGE_LOADERS[item.id]),
      })),
      { path: 'extensions/hosts', element: lazyPage(PAGE_LOADERS.extensions) },
      { path: '*', element: <Navigate to="/overview" replace /> },
    ],
  },
])
