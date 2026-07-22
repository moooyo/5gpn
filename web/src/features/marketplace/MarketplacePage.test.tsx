import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { Toaster } from '../../components/ds'
import type { InterceptModule, InterceptModulesView, MarketplaceEntry, MarketplaceSource, MarketplacesView } from '../../lib/api/types'
import i18n from '../../i18n'
import MarketplacePage from './MarketplacePage'

vi.mock('../../lib/api/client', () => ({ api: {
  getMarketplaces: vi.fn(),
  getInterceptModules: vi.fn(),
  addMarketplace: vi.fn(),
  refreshMarketplace: vi.fn(),
  deleteMarketplace: vi.fn(),
  installMarketplaceEntry: vi.fn(),
} }))

import { api } from '../../lib/api/client'

const APPLE: MarketplaceEntry = {
  id: 'io.5gpn.apple-wloc',
  name: 'Apple WLOC Location Override',
  version: '1.0.0',
  description: 'Rewrites a bounded location response.',
  tags: ['apple', 'location'],
  license: { spdx: 'MIT', url: 'https://example.test/MIT' },
  documentation_url: 'https://example.test/apple',
  manifest_url: 'https://cdn.example.test/apple/extension.yaml',
  manifest_digest: 'a'.repeat(64),
  capabilities: { capture_host_count: 2, action_count: 1, setting_count: 2, network_origins: [], persistent_storage: false, upstream_mapping_count: 0, routing_rule_count: 0, egress_group_required: false },
}
const CLEANER: MarketplaceEntry = {
  id: 'io.example.response-cleaner',
  name: 'Response Cleaner',
  version: '2.1.0',
  description: 'Cleans one reviewed response shape.',
  tags: ['privacy', 'response'],
  license: { spdx: 'Apache-2.0' },
  manifest_url: 'https://mirror.example.test/cleaner/extension.yaml',
  manifest_digest: 'b'.repeat(64),
  capabilities: { capture_host_count: 4, action_count: 3, setting_count: 0, network_origins: ['https://api.example.test'], persistent_storage: true, upstream_mapping_count: 0, routing_rule_count: 2, egress_group_required: true },
}
const OFFICIAL: MarketplaceSource = {
  id: 'io.5gpn.official',
  name: '5gpn Official Extensions',
  metadata_name: '5gpn Official Extensions',
  description: 'First-party reviewed extensions.',
  homepage: 'https://example.test/official',
  url: 'https://market.example.test/index.json',
  final_url: 'https://market.example.test/index.json',
  digest: 'c'.repeat(64),
  snapshot_digest: 'e'.repeat(64),
  fetched_at: '2026-07-20T10:00:00Z',
  entries: [APPLE],
}
const COMMUNITY: MarketplaceSource = {
  id: 'io.example.community',
  name: 'Community mirror',
  metadata_name: 'Community catalog',
  url: 'https://community.example.test/index.json',
  final_url: 'https://community.example.test/index.json',
  digest: 'd'.repeat(64),
  snapshot_digest: 'f'.repeat(64),
  fetched_at: '2026-07-21T10:00:00Z',
  entries: [CLEANER],
}
const MARKETPLACES: MarketplacesView = { revision: '1'.repeat(64), recommended_url: OFFICIAL.url, sources: [OFFICIAL, COMMUNITY] }
const INSTALLED_APPLE: InterceptModule = {
  id: APPLE.id,
  extension_version: APPLE.version,
  name: APPLE.name,
  enabled: false,
  ready: true,
  capture_hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
  capture_dns: 'trust',
  script_count: 1,
  settings: [],
  persistent_storage: false,
  source_url: APPLE.manifest_url,
  source_digest: APPLE.manifest_digest,
  snapshot_digest: 'e'.repeat(64),
  execution_order: 1,
  network_origins: [],
  egress_group_required: false,
}
const MODULES: InterceptModulesView = {
  revision: '2'.repeat(64),
  catalog_url: '',
  active_capture_hosts: [],
  execution_order: [INSTALLED_APPLE.id],
  available_egress_groups: [],
  modules: [INSTALLED_APPLE],
}

function renderPage() {
  return render(<MemoryRouter><MarketplacePage /><Toaster /></MemoryRouter>)
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.clearAllMocks()
  vi.mocked(api.getMarketplaces).mockResolvedValue(structuredClone(MARKETPLACES))
  vi.mocked(api.getInterceptModules).mockResolvedValue(structuredClone(MODULES))
})

describe('MarketplacePage', () => {
  it('filters across connected sources and searches real marketplace metadata', async () => {
    const user = userEvent.setup()
    renderPage()
    await screen.findByText('Response Cleaner')
    expect(screen.getByText('Apple WLOC Location Override')).toBeInTheDocument()
    expect(screen.getByText('路由 · 2')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Community mirror/ }))
    expect(screen.queryByText('Apple WLOC Location Override')).not.toBeInTheDocument()
    expect(screen.getByText('Response Cleaner')).toBeInTheDocument()
    await user.type(screen.getByLabelText('搜索市场插件'), 'not-present')
    expect(await screen.findByText('该市场暂无匹配插件')).toBeInTheDocument()
  })

  it('sorts by real source refresh time or extension name without invented popularity', async () => {
    const user = userEvent.setup()
    renderPage()
    await screen.findByText('Response Cleaner')
    expect(within(screen.getAllByRole('article')[0]).getByText('Response Cleaner')).toBeInTheDocument()
    await user.click(screen.getByRole('combobox', { name: '排序市场插件' }))
    await user.click(await screen.findByRole('option', { name: '名称' }))
    await waitFor(() => expect(within(screen.getAllByRole('article')[0]).getByText('Apple WLOC Location Override')).toBeInTheDocument())
  })

  it('adds a marketplace URL with an optional local display name', async () => {
    const user = userEvent.setup()
    const added: MarketplaceSource = { ...COMMUNITY, id: 'io.example.added', name: '本地镜像', url: 'https://added.example.test/index.json', final_url: 'https://added.example.test/index.json' }
    vi.mocked(api.addMarketplace).mockResolvedValue({ ...MARKETPLACES, revision: '3'.repeat(64), sources: [...MARKETPLACES.sources, added] })
    renderPage()
    await screen.findByText('Response Cleaner')
    await user.click(screen.getByRole('button', { name: '添加市场' }))
    const dialog = await screen.findByRole('dialog', { name: /添加插件市场/ })
    await user.type(within(dialog).getByLabelText('市场 URL'), added.url)
    await user.type(within(dialog).getByLabelText('显示名称（可选）'), '本地镜像')
    await user.click(within(dialog).getByRole('button', { name: '添加并拉取' }))
    await waitFor(() => expect(api.addMarketplace).toHaveBeenCalledWith(MARKETPLACES.revision, added.url, '本地镜像'))
  })

  it('refreshes all sources sequentially with each returned revision', async () => {
    const user = userEvent.setup()
    const afterOfficial = { ...MARKETPLACES, revision: '4'.repeat(64) }
    const afterCommunity = { ...MARKETPLACES, revision: '5'.repeat(64) }
    vi.mocked(api.refreshMarketplace)
      .mockResolvedValueOnce(afterOfficial)
      .mockResolvedValueOnce(afterCommunity)
    renderPage()
    await screen.findByText('Response Cleaner')
    await user.click(screen.getByRole('button', { name: '刷新市场源' }))
    await waitFor(() => expect(api.refreshMarketplace).toHaveBeenCalledTimes(2))
    expect(api.refreshMarketplace).toHaveBeenNthCalledWith(1, OFFICIAL.id, MARKETPLACES.revision)
    expect(api.refreshMarketplace).toHaveBeenNthCalledWith(2, COMMUNITY.id, afterOfficial.revision)
  })

  it('confirms cached scope before installing and then reviews the actual disabled snapshot', async () => {
    const user = userEvent.setup()
    const actual: InterceptModule = {
      id: CLEANER.id,
      extension_version: CLEANER.version,
      name: 'Actual verified cleaner',
      enabled: false,
      ready: true,
      capture_hosts: ['api.example.test'],
      capture_dns: 'china',
      script_count: 3,
      settings: [],
      routing_rules: [{ action: 'reject', domain: 'ads.example.test' }],
      persistent_storage: true,
      source_url: CLEANER.manifest_url,
      source_digest: CLEANER.manifest_digest,
      snapshot_digest: 'f'.repeat(64),
      execution_order: 2,
      network_origins: ['https://api.example.test'],
      egress_group_required: true,
    }
    const installed: InterceptModulesView = { ...MODULES, revision: '6'.repeat(64), execution_order: [...MODULES.execution_order, actual.id], modules: [...MODULES.modules, actual] }
    vi.mocked(api.installMarketplaceEntry).mockResolvedValue(installed)
    renderPage()
    const card = (await screen.findByText('Response Cleaner')).closest('article')!
    await user.click(within(card).getByRole('button', { name: '安装快照' }))
    const dialog = await screen.findByRole('dialog', { name: /安装快照前确认/ })
    expect(dialog).toHaveTextContent('接管域名')
    expect(dialog).toHaveTextContent('4')
    expect(dialog).toHaveTextContent('全局路由规则')
    expect(dialog).toHaveTextContent('2')
    expect(api.installMarketplaceEntry).not.toHaveBeenCalled()
    await user.click(within(dialog).getByRole('button', { name: '确认安装' }))
    await waitFor(() => expect(api.installMarketplaceEntry).toHaveBeenCalledWith(COMMUNITY.id, CLEANER.id, MARKETPLACES.revision, MODULES.revision))
    expect(await screen.findByText(/Actual verified cleaner/)).toBeInTheDocument()
    expect(dialog).toHaveTextContent('已关闭')
    expect(dialog).toHaveTextContent('f'.repeat(64))
    expect(dialog).toHaveTextContent('{"action":"reject","domain":"ads.example.test"}')
  })

  it('shows installed entries as management actions rather than update claims', async () => {
    renderPage()
    const card = (await screen.findByText('Apple WLOC Location Override')).closest('article')!
    expect(within(card).getByText('已安装')).toBeInTheDocument()
    expect(within(card).getByRole('button', { name: '管理快照' })).toBeInTheDocument()
    expect(within(card).queryByText('有更新')).not.toBeInTheDocument()
  })

  it('keeps the cached source visible and marks it after a refresh failure', async () => {
    const user = userEvent.setup()
    vi.mocked(api.refreshMarketplace).mockRejectedValueOnce(new Error('refresh unavailable'))
    renderPage()
    await screen.findByText('Response Cleaner')
    await user.click(screen.getByRole('button', { name: /Community mirror/ }))
    await user.click(screen.getByRole('button', { name: '刷新市场源' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('refresh unavailable')
    expect(screen.getByText('Response Cleaner')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Community mirror.*最近一次刷新失败/ })).toBeInTheDocument()
  })

  it('removes only the selected marketplace source after confirmation', async () => {
    const user = userEvent.setup()
    vi.mocked(api.deleteMarketplace).mockResolvedValue({ ...MARKETPLACES, revision: '7'.repeat(64), sources: [OFFICIAL] })
    renderPage()
    await screen.findByText('Response Cleaner')
    await user.click(screen.getByRole('button', { name: /Community mirror/ }))
    await user.click(screen.getByRole('button', { name: '移除当前市场源' }))
    const dialog = await screen.findByRole('dialog', { name: /移除 Community mirror/ })
    await user.click(within(dialog).getByRole('button', { name: '移除来源' }))
    await waitFor(() => expect(api.deleteMarketplace).toHaveBeenCalledWith(COMMUNITY.id, MARKETPLACES.revision))
  })
})
