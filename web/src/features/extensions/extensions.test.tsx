import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import type { InterceptModule, InterceptModulesView } from '../../lib/api/types'
import i18n from '../../i18n'
import ExtensionsPage from './ExtensionsPage'

vi.mock('../../lib/api/client', () => ({
  api: {
    getInterceptModules: vi.fn(),
    getInterceptModuleSnapshot: vi.fn(),
    importInterceptModule: vi.fn(),
    checkInterceptModuleUpdate: vi.fn(),
    applyInterceptModuleUpdate: vi.fn(),
    putInterceptModule: vi.fn(),
    deleteInterceptModule: vi.fn(),
    reorderInterceptModules: vi.fn(),
    getMITMSettings: vi.fn(),
  },
}))

vi.mock('./LocationPicker', () => ({
  LocationPicker: ({ onChange }: { onChange: (value: unknown) => void }) => (
    <button type="button" data-testid="mock-location-picker" onClick={() => onChange({ longitude: 113.94114, latitude: 22.544577, accuracy: 25 })}>pick location</button>
  ),
}))

import { api } from '../../lib/api/client'

const WLOC: InterceptModule = {
  id: 'io.5gpn.apple-wloc', extension_version: '1.0.0', name: 'Apple WLOC Location Override',
  description: 'Native online extension for Apple location responses.', enabled: false, ready: false,
  reason: 'settings-required', capture_hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'], capture_dns: 'trust', script_count: 1,
  settings: [
    { key: 'location', type: 'location', label: 'Target location', required: true, value: { accuracy: 25 } },
    { key: 'failClosed', type: 'boolean', label: 'Block on transformation failure', required: true, value: true },
  ],
  persistent_storage: false, execution_order: 1, network_origins: [], egress_group_required: false,
  source_url: 'https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml',
  source_digest: 'a'.repeat(64), snapshot_digest: 'a'.repeat(64), imported_at: '2026-07-18T00:00:00Z',
}

const CLEANER: InterceptModule = {
  id: 'io.example.response-cleaner', extension_version: '1.0.0', name: 'Response Cleaner',
  description: 'Native response action fixture.', enabled: false, ready: true, reason: undefined,
  capture_hosts: ['api.example.com'], capture_dns: 'china', script_count: 1, settings: [], persistent_storage: false,
  upstream_mappings: [{ host: 'api.example.com', target: 'origin.example.net' }],
  routing_rules: [{ action: 'reject', domain_suffix: 'ads.example.com', network: 'udp' }],
  source_url: 'https://extensions.example.test/clean.yaml', source_digest: 'b'.repeat(64), snapshot_digest: 'b'.repeat(64), imported_at: '2026-07-18T00:00:00Z',
  execution_order: 2, network_origins: ['https://origin.example.net'], egress_group_required: true, egress_group: 'Proxies',
}

const VIEW: InterceptModulesView = {
  revision: '1'.repeat(64),
  catalog_url: 'https://github.com/moooyo/5gpn-extensions',
  active_capture_hosts: [],
  execution_order: [WLOC.id, CLEANER.id],
  available_egress_groups: ['DIRECT', 'Proxies'],
  modules: [WLOC, CLEANER],
}

function cloneView(): InterceptModulesView {
  return structuredClone(VIEW)
}

function renderPage(path = '/extensions') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/extensions" element={<ExtensionsPage />} />
        <Route path="/extensions/hosts" element={<ExtensionsPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  localStorage.clear()
  vi.clearAllMocks()
  vi.mocked(api.getInterceptModules).mockResolvedValue(cloneView())
  vi.mocked(api.getMITMSettings).mockResolvedValue({ revision: '1'.repeat(64), enabled: false, http2: true, quic_fallback_protection: true })
  vi.mocked(api.putInterceptModule).mockImplementation(async (_id, update) => {
    const next = cloneView()
    const module = next.modules.find((candidate) => candidate.id === _id)!
    if (update.enabled !== undefined) module.enabled = update.enabled
    if (update.settings) module.settings = module.settings?.map((setting) => ({ ...setting, value: update.settings?.[setting.key] }))
    if (update.capture_dns !== undefined) module.capture_dns = update.capture_dns
    return next
  })
  vi.mocked(api.deleteInterceptModule).mockResolvedValue(cloneView())
  vi.mocked(api.reorderInterceptModules).mockImplementation(async (_revision, order) => {
    const next = cloneView()
    const byID = new Map(next.modules.map((module) => [module.id, module]))
    next.execution_order = order
    next.modules = order.map((id, index) => ({ ...byID.get(id)!, execution_order: index + 1 }))
    return next
  })
  vi.mocked(api.getInterceptModuleSnapshot).mockResolvedValue({ id: CLEANER.id, name: CLEANER.name, source_digest: CLEANER.source_digest, source_body: 'apiVersion: 5gpn.io/v1', scripts: [] })
})

describe('ExtensionsPage native extension contract', () => {
  it('renders native extension snapshots', async () => {
    const user = userEvent.setup()
    renderPage()
    expect(await screen.findByText('Response Cleaner')).toBeInTheDocument()
    expect(screen.getByText('接管 · 1')).toBeInTheDocument()
    expect(screen.getByText('上游映射 · 1')).toBeInTheDocument()
    expect(screen.getByText('路由规则 · 1')).toBeInTheDocument()
    await user.click(screen.getByText('查看精确路由规则 · 1'))
    expect(screen.getByText('{"action":"reject","domain_suffix":"ads.example.com","network":"udp"}')).toBeVisible()
    expect(screen.getByRole('link', { name: /打开插件目录/ })).toHaveAttribute('href', VIEW.catalog_url)
    expect(screen.queryByTestId('extension-traffic-contract')).not.toBeInTheDocument()
    expect(screen.queryByRole('tab', { name: '插件市场' })).not.toBeInTheDocument()
  })

  it('arms a valid native extension while the MITM master is off after confirmation', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('switch'))
    const dialog = await screen.findByRole('dialog')
    expect(dialog).toHaveTextContent('改写会转发完整的方法、解码后的请求体和端到端请求头，其中可能包含 Cookie 和 Authorization 凭据')
    expect(within(dialog).getByText('https://origin.example.net')).toHaveClass('min-w-0', 'max-w-full', 'break-all')
    expect(dialog).toHaveTextContent('本次启用确认同时授权这些已审查的 REJECT/DIRECT 规则')
    expect(dialog).toHaveTextContent('{"action":"reject","domain_suffix":"ads.example.com","network":"udp"}')
    expect(within(dialog).getByTestId('enable-capture-dns')).toHaveTextContent('China 组')
    expect(dialog).toHaveTextContent('实时 China group（默认 223.5.5.5）及当前 ECS 设置')
    await user.click(within(dialog).getByRole('button', { name: '启用' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith(CLEANER.id, { revision: VIEW.revision, enabled: true }))
  })

  it('uses the generic location setting editor for the online WLOC extension', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${WLOC.id}`)
    await user.click(within(card).getByRole('button', { name: '设置 · 2' }))
    const dialog = await screen.findByRole('dialog', { name: /Apple WLOC/ })
    await user.click(within(dialog).getByTestId('mock-location-picker'))
    await user.click(within(dialog).getByRole('button', { name: '保存' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith(WLOC.id, {
      revision: VIEW.revision,
      settings: {
        location: { longitude: 113.94114, latitude: 22.544577, accuracy: 25 },
        failClosed: true,
      },
    }))
  })

  it('edits the operator-selected capture DNS group', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('button', { name: '配置' }))
    const dialog = await screen.findByRole('dialog', { name: /Response Cleaner/ })
    expect(within(dialog).getByTestId('capture-dns-editor')).toHaveTextContent('China 组')
    await user.click(within(dialog).getByRole('tab', { name: 'Trust 组' }))
    await user.click(within(dialog).getByRole('button', { name: '保存' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith(CLEANER.id, {
      revision: VIEW.revision,
      settings: {},
      capture_dns: 'trust',
    }))
  })

  it('keeps URL installation and local add as distinct dialogs', async () => {
    const user = userEvent.setup()
    renderPage()
    await user.click(await screen.findByRole('button', { name: '从 URL 安装' }))
    let dialog = await screen.findByRole('dialog', { name: '从 URL 安装原生插件' })
    expect(within(dialog).getByLabelText('Manifest URL')).toBeInTheDocument()
    expect(within(dialog).queryByLabelText('原生插件 manifest')).not.toBeInTheDocument()
    await user.click(within(dialog).getByRole('button', { name: '取消' }))

    await user.click(screen.getByRole('button', { name: '本地新增' }))
    dialog = await screen.findByRole('dialog', { name: '本地新增原生插件' })
    expect(within(dialog).getByLabelText('原生插件 manifest')).toBeInTheDocument()
    expect(within(dialog).queryByLabelText('Manifest URL')).not.toBeInTheDocument()
  })

  it('installs and reviews a native manifest URL without exposing source-mode tabs', async () => {
    const user = userEvent.setup()
    const installed = cloneView()
    installed.modules.push({ ...CLEANER, id: 'io.example.installed', name: 'Installed extension', source_digest: 'c'.repeat(64), snapshot_digest: 'c'.repeat(64) })
    vi.mocked(api.importInterceptModule).mockResolvedValueOnce(installed)
    renderPage()
    await user.click(await screen.findByRole('button', { name: '从 URL 安装' }))
    const dialog = await screen.findByRole('dialog')
    await user.type(within(dialog).getByLabelText('Manifest URL'), 'https://example.com/extension.yaml')
    await user.click(within(dialog).getByRole('button', { name: '获取、固化并检查' }))
    expect(await within(dialog).findByTestId('extension-install-review')).toHaveTextContent('Installed extension')
    expect(within(dialog).getByTestId('install-capture-dns')).toHaveTextContent('China 组')
    expect(api.importInterceptModule).toHaveBeenCalledWith({ revision: VIEW.revision, url: 'https://example.com/extension.yaml' })
  })

  it('audits capture hosts by extension and supports host search', async () => {
    const user = userEvent.setup()
    renderPage('/extensions/hosts')
    expect(await screen.findByTestId('host-audit-view')).toBeInTheDocument()
    expect(screen.getByTestId(`host-group-${WLOC.id}`)).toHaveTextContent('gs-loc.apple.com')
    await user.type(screen.getByTestId('host-audit-search'), 'api.example.com')
    expect(screen.getByTestId(`host-group-${CLEANER.id}`)).toBeInTheDocument()
    expect(screen.queryByTestId(`host-group-${WLOC.id}`)).not.toBeInTheDocument()
  })

  it('shows the first enabled DNS winner for exact and wildcard overlap', async () => {
    const overlap = cloneView()
    const first = overlap.modules[0]
    const second = overlap.modules[1]
    first.capture_hosts = ['*.example.com']
    first.capture_dns = 'trust'
    first.enabled = true
    first.ready = true
    first.reason = undefined
    second.capture_hosts = ['api.example.com']
    second.capture_dns = 'china'
    second.enabled = true
    second.ready = true
    overlap.active_capture_hosts = ['*.example.com', 'api.example.com']
    vi.mocked(api.getInterceptModules).mockResolvedValueOnce(overlap)
    vi.mocked(api.getMITMSettings).mockResolvedValueOnce({ revision: overlap.revision, enabled: true, http2: true, quic_fallback_protection: true })

    renderPage('/extensions/hosts')
    const firstGroup = await screen.findByTestId(`host-group-${WLOC.id}`)
    const secondGroup = screen.getByTestId(`host-group-${CLEANER.id}`)
    expect(firstGroup).toHaveTextContent('DNS 赢家 · Trust 组')
    expect(secondGroup).toHaveTextContent('DNS 由 Apple WLOC Location Override 决定 · Trust 组')
    expect(secondGroup).toHaveTextContent('范围重叠')
  })

  it('reviews before and after order before moving an extension', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('button', { name: '上移 Response Cleaner' }))
    const dialog = await screen.findByRole('dialog', { name: /确认调整执行顺序/ })
    expect(api.reorderInterceptModules).not.toHaveBeenCalled()
    expect(dialog).toHaveTextContent('插件 actions 的组合顺序')
    expect(dialog).toHaveTextContent('重叠 egress 的选择优先级')
    expect(dialog).toHaveTextContent('全局 REJECT/DIRECT 路由规则的优先级')
    const before = within(dialog).getByTestId('extension-reorder-before')
    const after = within(dialog).getByTestId('extension-reorder-after')
    expect(within(before).getAllByRole('listitem')[0]).toHaveTextContent(WLOC.name)
    expect(within(before).getAllByRole('listitem')[0]).toHaveTextContent('Trust 组')
    expect(within(before).getAllByRole('listitem')[1]).toHaveTextContent(CLEANER.name)
    expect(within(before).getAllByRole('listitem')[1]).toHaveTextContent('China 组')
    expect(within(after).getAllByRole('listitem')[0]).toHaveTextContent(CLEANER.name)
    expect(within(after).getAllByRole('listitem')[1]).toHaveTextContent(WLOC.name)
    await user.click(within(dialog).getByRole('button', { name: '确认调整顺序' }))
    await waitFor(() => expect(api.reorderInterceptModules).toHaveBeenCalledWith(VIEW.revision, [CLEANER.id, WLOC.id]))
  })

  it('uses the same reorder confirmation without routing rules and cancels without an API call', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${WLOC.id}`)
    expect(WLOC.routing_rules).toBeUndefined()
    await user.click(within(card).getByRole('button', { name: '下移 Apple WLOC Location Override' }))
    const dialog = await screen.findByRole('dialog', { name: /Apple WLOC Location Override/ })
    expect(dialog).toHaveTextContent('即使某个插件没有声明路由规则')
    await user.click(within(dialog).getByRole('button', { name: '取消' }))
    await waitFor(() => expect(screen.queryByRole('dialog', { name: /Apple WLOC Location Override/ })).not.toBeInTheDocument())
    expect(api.reorderInterceptModules).not.toHaveBeenCalled()
  })

  it('locks every extension action while a reorder transaction is pending', async () => {
    const user = userEvent.setup()
    let releaseReorder!: (value: InterceptModulesView) => void
    vi.mocked(api.reorderInterceptModules).mockReturnValueOnce(new Promise((resolve) => { releaseReorder = resolve }))
    renderPage()
    const wlocCard = await screen.findByTestId(`extension-${WLOC.id}`)
    const cleanerCard = screen.getByTestId(`extension-${CLEANER.id}`)
    const wlocMoveDown = within(wlocCard).getByRole('button', { name: '下移 Apple WLOC Location Override' })
    expect(wlocMoveDown).toBeEnabled()

    await user.click(within(cleanerCard).getByRole('button', { name: '上移 Response Cleaner' }))
    const dialog = await screen.findByRole('dialog', { name: /确认调整执行顺序/ })
    expect(wlocMoveDown).toBeEnabled()
    await user.click(within(dialog).getByRole('button', { name: '确认调整顺序' }))
    await waitFor(() => expect(wlocMoveDown).toBeDisabled())
    expect(within(wlocCard).getByRole('button', { name: '设置 · 2' })).toBeDisabled()
    expect(wlocCard.parentElement).toHaveAttribute('aria-busy', 'true')

    releaseReorder(cloneView())
    await waitFor(() => expect(wlocMoveDown).toBeEnabled())
  })

  it('explains how to restore ordering controls while search is active', async () => {
    const user = userEvent.setup()
    renderPage()
    await user.type(await screen.findByRole('textbox', { name: '搜索插件' }), 'Response Cleaner')
    expect(screen.getByTestId('extension-order-hint')).toHaveTextContent('切换到“全部”并清空搜索')
    const card = screen.getByTestId(`extension-${CLEANER.id}`)
    expect(within(card).getByRole('button', { name: '上移 Response Cleaner' })).toBeDisabled()
  })

  it('marks a missing required egress group as not ready and prevents enable', async () => {
    const missing = cloneView()
    const module = missing.modules.find((candidate) => candidate.id === CLEANER.id)!
    module.egress_group = 'RemovedGroup'
    vi.mocked(api.getInterceptModules).mockResolvedValueOnce(missing)
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    expect(within(card).getByText('出口组缺失')).toBeInTheDocument()
    expect(within(card).getByRole('switch')).toBeDisabled()
  })

  it('configures a required egress group even when the extension has no typed settings', async () => {
    const user = userEvent.setup()
    const unbound = cloneView()
    const module = unbound.modules.find((candidate) => candidate.id === CLEANER.id)!
    module.egress_group = undefined
    vi.mocked(api.getInterceptModules).mockResolvedValueOnce(unbound)
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('button', { name: '配置' }))
    const dialog = await screen.findByRole('dialog', { name: /Response Cleaner/ })
    await user.click(within(dialog).getByRole('combobox'))
    await user.click(await screen.findByRole('option', { name: 'Proxies' }))
    await user.click(within(dialog).getByRole('button', { name: '保存' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith(CLEANER.id, {
      revision: VIEW.revision,
      settings: {},
      egress_group: 'Proxies',
    }))
  })

  it('clears an optional egress binding back to the terminal target', async () => {
    const user = userEvent.setup()
    const optional = cloneView()
    const module = optional.modules.find((candidate) => candidate.id === CLEANER.id)!
    module.egress_group_required = false
    vi.mocked(api.getInterceptModules).mockResolvedValueOnce(optional)
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('button', { name: '配置' }))
    const dialog = await screen.findByRole('dialog', { name: /Response Cleaner/ })
    await user.click(within(dialog).getByRole('combobox'))
    await user.click(await screen.findByRole('option', { name: '使用 mihomo 配置中的默认出口' }))
    await user.click(within(dialog).getByRole('button', { name: '保存' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith(CLEANER.id, {
      revision: VIEW.revision,
      settings: {},
      egress_group: '',
    }))
  })

  it('reviews a same-id native update before replacement', async () => {
    const user = userEvent.setup()
    const candidate = { ...CLEANER, extension_version: '1.1.0', snapshot_digest: 'f'.repeat(64) }
    vi.mocked(api.checkInterceptModuleUpdate).mockResolvedValueOnce({ revision: VIEW.revision, state: 'available', candidate })
    vi.mocked(api.applyInterceptModuleUpdate).mockResolvedValueOnce(cloneView())
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('button', { name: '检查更新' }))
    const dialog = await screen.findByRole('dialog', { name: /审查更新/ })
    expect(dialog).toHaveTextContent('v1.1.0')
    expect(within(dialog).getByTestId('update-capture-dns')).toHaveTextContent('China 组')
    expect(within(dialog).getByText('https://origin.example.net')).toHaveClass('min-w-0', 'max-w-full', 'break-all')
    expect(dialog).toHaveTextContent('{"action":"reject","domain_suffix":"ads.example.com","network":"udp"}')
    await user.click(within(dialog).getByRole('button', { name: '替换快照' }))
    await waitFor(() => expect(api.applyInterceptModuleUpdate).toHaveBeenCalledWith(CLEANER.id, VIEW.revision, candidate.snapshot_digest))
  })
})
