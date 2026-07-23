// Authoritative application route/navigation manifest shared by the router
// and the E2E suite.
export interface NavItem {
  id: string
  path: string
  labelKey: string
  icon: NavIcon
}

export type NavIcon = 'dashboard' | 'setup' | 'logs' | 'resolve' | 'policy' | 'extensions' | 'marketplace' | 'pluginLogs' | 'mihomo' | 'config' | 'settings'

export interface NavGroup {
  id: string
  labelKey: string
  items: NavItem[]
}

export const NAV_GROUPS: NavGroup[] = [
  {
    id: 'overview',
    labelKey: 'nav.group.overview',
    items: [
      { id: 'overview', path: '/overview', labelKey: 'nav.overview', icon: 'dashboard' },
      { id: 'setup-guide', path: '/setup-guide', labelKey: 'nav.setupGuide', icon: 'setup' },
    ],
  },
  {
    id: 'parse',
    labelKey: 'nav.group.parse',
    items: [
      { id: 'logs', path: '/logs', labelKey: 'nav.logs', icon: 'logs' },
      { id: 'resolve-test', path: '/resolve-test', labelKey: 'nav.resolveTest', icon: 'resolve' },
      { id: 'policy-rules', path: '/policy-rules', labelKey: 'nav.policyRules', icon: 'policy' },
    ],
  },
  {
    id: 'plugins',
    labelKey: 'nav.group.plugins',
    items: [
      { id: 'extensions', path: '/extensions', labelKey: 'nav.extensions', icon: 'extensions' },
      { id: 'marketplace', path: '/marketplace', labelKey: 'nav.marketplace', icon: 'marketplace' },
      { id: 'plugin-logs', path: '/plugin-logs', labelKey: 'nav.pluginLogs', icon: 'pluginLogs' },
    ],
  },
  {
    id: 'system',
    labelKey: 'nav.group.system',
    items: [
      { id: 'mihomo', path: '/mihomo', labelKey: 'nav.mihomo', icon: 'mihomo' },
      { id: 'mihomo-config', path: '/mihomo-config', labelKey: 'nav.mihomoConfig', icon: 'config' },
      { id: 'settings', path: '/settings', labelKey: 'nav.settings', icon: 'settings' },
    ],
  },
]

export const ALL_NAV_ITEMS: NavItem[] = NAV_GROUPS.flatMap((g) => g.items)
