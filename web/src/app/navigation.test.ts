import { describe, it, expect } from 'vitest'
import { NAV_GROUPS, ALL_NAV_ITEMS } from './navigation'
import i18n from '../i18n'

describe('navigation model', () => {
  it('exposes exactly the current route set', () => {
    expect(NAV_GROUPS.length).toBe(4)
    expect(ALL_NAV_ITEMS.map(({ id, path }) => ({ id, path }))).toEqual([
      { id: 'overview', path: '/overview' },
      { id: 'setup-guide', path: '/setup-guide' },
      { id: 'logs', path: '/logs' },
      { id: 'resolve-test', path: '/resolve-test' },
      { id: 'policy-rules', path: '/policy-rules' },
      { id: 'extensions', path: '/extensions' },
      { id: 'marketplace', path: '/marketplace' },
      { id: 'mihomo', path: '/mihomo' },
      { id: 'mihomo-config', path: '/mihomo-config' },
      { id: 'settings', path: '/settings' },
    ])
  })

  it('exposes the setup guide next to the dashboard', () => {
    const overview = NAV_GROUPS.find((g) => g.id === 'overview')
    expect(overview?.items.map((item) => item.id)).toEqual(['overview', 'setup-guide'])
    expect(overview?.items[1]).toEqual({
      id: 'setup-guide',
      path: '/setup-guide',
      labelKey: 'nav.setupGuide',
      icon: 'setup',
    })
  })

  it('exposes the unified policy-rules item', () => {
    expect(ALL_NAV_ITEMS.some((i) => i.id === 'policy-rules' && i.path === '/policy-rules')).toBe(true)
  })

  it('has a mihomo item in the system group', () => {
    const system = NAV_GROUPS.find((g) => g.id === 'system')
    expect(system).toBeDefined()
    const mihomo = system?.items.find((i) => i.id === 'mihomo')
    expect(mihomo).toEqual({ id: 'mihomo', path: '/mihomo', labelKey: 'nav.mihomo', icon: 'mihomo' })
  })

  it('has a mihomo-config item in the system group, next to mihomo', () => {
    const system = NAV_GROUPS.find((g) => g.id === 'system')
    expect(system).toBeDefined()
    const mihomoConfig = system?.items.find((i) => i.id === 'mihomo-config')
    expect(mihomoConfig).toEqual({
      id: 'mihomo-config',
      path: '/mihomo-config',
      labelKey: 'nav.mihomoConfig',
      icon: 'config',
    })
  })

  it('has unique paths across all items', () => {
    const paths = ALL_NAV_ITEMS.map((item) => item.path)
    expect(new Set(paths).size).toBe(paths.length)
  })

  it('has unique group ids and item ids', () => {
    expect(new Set(NAV_GROUPS.map((g) => g.id)).size).toBe(NAV_GROUPS.length)
    expect(new Set(ALL_NAV_ITEMS.map((i) => i.id)).size).toBe(ALL_NAV_ITEMS.length)
  })
})

describe('i18n nav keys resolve', () => {
  it('resolves nav.overview to a non-empty zh string, distinct from the key', async () => {
    await i18n.changeLanguage('zh')
    const value = i18n.t('nav.overview')
    expect(typeof value).toBe('string')
    expect(value.length).toBeGreaterThan(0)
    expect(value).not.toBe('nav.overview')
  })

  it('resolves every nav item and group labelKey used by NAV_GROUPS', async () => {
    await i18n.changeLanguage('zh')
    for (const group of NAV_GROUPS) {
      const groupLabel = i18n.t(group.labelKey)
      expect(groupLabel).not.toBe(group.labelKey)
      for (const item of group.items) {
        const itemLabel = i18n.t(item.labelKey)
        expect(itemLabel).not.toBe(item.labelKey)
      }
    }
  })
})
