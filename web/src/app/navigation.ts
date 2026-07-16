// Authoritative application route/navigation manifest. The router and E2E
// suite both derive paths from this list, so a removed page cannot silently
// remain as a redirecting false-positive test fixture.
export interface NavItem {
  id: string
  path: string
  labelKey: string
  icon: string // lucide-react component name, resolved by the consumer
}

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
      { id: 'overview', path: '/overview', labelKey: 'nav.overview', icon: 'LayoutGrid' },
      { id: 'setup-guide', path: '/setup-guide', labelKey: 'nav.setupGuide', icon: 'BookOpenCheck' },
    ],
  },
  {
    id: 'parse',
    labelKey: 'nav.group.parse',
    items: [
      { id: 'logs', path: '/logs', labelKey: 'nav.logs', icon: 'ScrollText' },
      { id: 'resolve-test', path: '/resolve-test', labelKey: 'nav.resolveTest', icon: 'Search' },
    ],
  },
  {
    id: 'rules',
    labelKey: 'nav.group.rules',
    items: [
      { id: 'policy-rules', path: '/policy-rules', labelKey: 'nav.policyRules', icon: 'ListChecks' },
    ],
  },
  {
    id: 'system',
    labelKey: 'nav.group.system',
    items: [
      { id: 'mihomo', path: '/mihomo', labelKey: 'nav.mihomo', icon: 'Gauge' },
      { id: 'mihomo-config', path: '/mihomo-config', labelKey: 'nav.mihomoConfig', icon: 'FileCode2' },
      { id: 'settings', path: '/settings', labelKey: 'nav.settings', icon: 'Settings' },
    ],
  },
]

export const ALL_NAV_ITEMS: NavItem[] = NAV_GROUPS.flatMap((g) => g.items)
