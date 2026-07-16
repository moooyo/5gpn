import { describe, it, expect } from 'vitest'
import { NAV_GROUPS, ALL_NAV_ITEMS } from './navigation'
import i18n from '../i18n'

describe('navigation model', () => {
  // The xray item was removed in B2, exits in B3; a prior phase landed
  // egress (overview group) and mihomo (system group); UP-3/C2 then merged
  // the DNS-rules + DNS-subscriptions items into a single policy-rules item
  // in the 'rules' group; UP-4 then removed the egress item entirely along
  // with the structured egress model, dropping the item count from 8 to 7,
  // then (Task 11) added a 'mihomo-config' item next to 'mihomo' in the
	// system group, then the obsolete advanced draft editor was removed.
	it('has exactly 4 groups and 8 items total', () => {
		expect(NAV_GROUPS.length).toBe(4)
		expect(ALL_NAV_ITEMS.length).toBe(8)
  })

  it('exposes the setup guide next to the dashboard', () => {
    const overview = NAV_GROUPS.find((g) => g.id === 'overview')
    expect(overview?.items.map((item) => item.id)).toEqual(['overview', 'setup-guide'])
    expect(overview?.items[1]).toEqual({
      id: 'setup-guide',
      path: '/setup-guide',
      labelKey: 'nav.setupGuide',
      icon: 'BookOpenCheck',
    })
  })

  it('exposes the unified policy-rules item and no longer the DNS subscriptions item', () => {
    expect(ALL_NAV_ITEMS.some((i) => i.id === 'policy-rules' && i.path === '/policy-rules')).toBe(true)
    expect(ALL_NAV_ITEMS.some((i) => i.id === 'subscriptions')).toBe(false)
    expect(ALL_NAV_ITEMS.some((i) => i.path === '/rules')).toBe(false)
  })

  it('has no xray item or path (removed in B2)', () => {
    expect(ALL_NAV_ITEMS.some((item) => item.id === 'xray')).toBe(false)
    expect(ALL_NAV_ITEMS.some((item) => item.path === '/xray')).toBe(false)
  })

  it('has no exits item or path (removed in B3)', () => {
    expect(ALL_NAV_ITEMS.some((item) => item.id === 'exits')).toBe(false)
    expect(ALL_NAV_ITEMS.some((item) => item.path === '/exits')).toBe(false)
  })

	it('has no egress item or path (removed in UP-4 along with the structured egress model)', () => {
    expect(ALL_NAV_ITEMS.some((item) => item.id === 'egress')).toBe(false)
    expect(ALL_NAV_ITEMS.some((item) => item.path === '/egress')).toBe(false)
	})

	it('has no legacy advanced draft editor', () => {
		expect(ALL_NAV_ITEMS.some((item) => item.id === 'policy')).toBe(false)
		expect(ALL_NAV_ITEMS.some((item) => item.path === '/policy')).toBe(false)
	})

  it('has a mihomo item in the system group (added in C3)', () => {
    const system = NAV_GROUPS.find((g) => g.id === 'system')
    expect(system).toBeDefined()
    const mihomo = system?.items.find((i) => i.id === 'mihomo')
    expect(mihomo).toEqual({ id: 'mihomo', path: '/mihomo', labelKey: 'nav.mihomo', icon: 'Gauge' })
  })

  it('has a mihomo-config item in the system group, next to mihomo (Task 11)', () => {
    const system = NAV_GROUPS.find((g) => g.id === 'system')
    expect(system).toBeDefined()
    const mihomoConfig = system?.items.find((i) => i.id === 'mihomo-config')
    expect(mihomoConfig).toEqual({
      id: 'mihomo-config',
      path: '/mihomo-config',
      labelKey: 'nav.mihomoConfig',
      icon: 'FileCode2',
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
