import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Toaster } from '../../components/ds'
import type { InterceptModule, InterceptModulesView, MarketplaceSource, MarketplacesView } from '../../lib/api/types'
import i18n from '../../i18n'
import MarketplaceView from './MarketplaceView'

vi.mock('../../lib/api/client', () => ({ api: {
  getMarketplaces: vi.fn(), addMarketplace: vi.fn(), refreshMarketplace: vi.fn(), deleteMarketplace: vi.fn(), installMarketplaceEntry: vi.fn(),
} }))

import { api } from '../../lib/api/client'

const ENTRY = {
  id: 'io.example.marketplace-cleaner', name: 'Marketplace Response Cleaner', version: '1.0.0', description: 'Directory metadata must not replace the installed review.', tags: ['response'], license: { spdx: 'MIT' }, manifest_url: 'https://example.test/cleaner.yaml', manifest_digest: 'a'.repeat(64),
  capabilities: { capture_host_count: 1, action_count: 1, setting_count: 0, network_origins: ['https://directory.example.test'], persistent_storage: false, upstream_mapping_count: 0, egress_group_required: true },
}
const SOURCE: MarketplaceSource = { id: 'io.5gpn.official', name: '5GPN Extensions', url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json', final_url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json', digest: 'b'.repeat(64), fetched_at: '2026-07-20T00:00:00Z', entries: [ENTRY] }
const MARKETPLACES: MarketplacesView = { revision: 'm'.repeat(64), recommended_url: SOURCE.url, sources: [SOURCE] }
const MODULES: InterceptModulesView = { revision: 'r'.repeat(64), catalog_url: '', active_capture_hosts: [], execution_order: [], available_egress_groups: [], modules: [] }

function renderView(view = MODULES, onModulesInstalled = vi.fn()) {
  return { onModulesInstalled, ...render(<><MarketplaceView modulesView={view} onModulesInstalled={onModulesInstalled} /><Toaster /></>) }
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.clearAllMocks()
  vi.mocked(api.getMarketplaces).mockResolvedValue(structuredClone(MARKETPLACES))
})

describe('MarketplaceView', () => {
  it('offers the recommended URL when the ledger has no sources', async () => {
    const user = userEvent.setup()
    vi.mocked(api.getMarketplaces).mockResolvedValueOnce({ ...MARKETPLACES, sources: [] })
    vi.mocked(api.addMarketplace).mockResolvedValue({ ...MARKETPLACES, sources: [SOURCE] })
    renderView()
    await user.click((await screen.findAllByRole('button', { name: '添加市场来源' }))[0])
    await user.click(screen.getByRole('button', { name: '添加推荐来源' }))
    await waitFor(() => expect(api.addMarketplace).toHaveBeenCalledWith('m'.repeat(64), SOURCE.url))
  })

  it('keeps the prior source visible and announces refresh failure before reloading', async () => {
    const user = userEvent.setup()
    vi.mocked(api.refreshMarketplace).mockRejectedValueOnce(new Error('refresh unavailable'))
    renderView()
    await screen.findByText('Marketplace Response Cleaner')
    await user.click(screen.getByRole('button', { name: '刷新来源' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('refresh unavailable')
    expect(screen.getByText('Marketplace Response Cleaner')).toBeInTheDocument()
    await waitFor(() => expect(api.getMarketplaces).toHaveBeenCalledTimes(2))
  })

  it('requires confirmation before deleting a source', async () => {
    const user = userEvent.setup()
    vi.mocked(api.deleteMarketplace).mockResolvedValue({ ...MARKETPLACES, sources: [] })
    renderView()
    await screen.findByText('Marketplace Response Cleaner')
    await user.click(screen.getByRole('button', { name: '删除来源' }))
    const dialog = await screen.findByRole('dialog', { name: /删除 5GPN Extensions/ })
    await user.click(within(dialog).getByRole('button', { name: '删除来源' }))
    await waitFor(() => expect(api.deleteMarketplace).toHaveBeenCalledWith(SOURCE.id, MARKETPLACES.revision))
  })

  it('reviews only the server-returned disabled snapshot after installation', async () => {
    const user = userEvent.setup()
    const actual: InterceptModule = { id: ENTRY.id, extension_version: ENTRY.version, name: 'Actual stored cleaner', enabled: false, ready: true, capture_hosts: ['captured.example.test'], script_count: 2, settings: [], persistent_storage: true, source_url: ENTRY.manifest_url, source_digest: 'c'.repeat(64), snapshot_digest: 'd'.repeat(64), execution_order: 1, network_origins: ['https://actual.example.test'], egress_group_required: true }
    const installed = { ...MODULES, revision: 's'.repeat(64), execution_order: [actual.id], modules: [actual] }
    vi.mocked(api.installMarketplaceEntry).mockResolvedValue(installed)
    const { onModulesInstalled } = renderView()
    const card = await screen.findByText('Marketplace Response Cleaner')
    await user.click(within(card.closest('article')!).getByRole('button', { name: '安装快照' }))
    const dialog = await screen.findByRole('dialog', { name: /审查已安装快照/ })
    expect(dialog).toHaveTextContent('Actual stored cleaner')
    expect(dialog).toHaveTextContent('https://actual.example.test')
    expect(dialog).toHaveTextContent('持久存储')
    expect(dialog).toHaveTextContent('已关闭')
    expect(dialog).toHaveTextContent('c'.repeat(64))
    expect(onModulesInstalled).toHaveBeenCalledWith(installed)
  })
})
