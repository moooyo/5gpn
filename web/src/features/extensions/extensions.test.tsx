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
  persistent_storage: false, execution_order: 1, network: false, egress_group_required: false,
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
  execution_order: 2, network: true, egress_group_required: true, egress_group: 'Proxies',
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

/** Card layout branches at 767px, matching every other page in this console. */
function setMobile(mobile: boolean) {
  vi.stubGlobal('matchMedia', vi.fn().mockImplementation((query: string) => ({
    matches: mobile && query.includes('max-width: 767px'),
    media: query,
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })))
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
    const card0 = await screen.findByTestId(`extension-${CLEANER.id}`)
    expect(within(card0).getByText(i18n.t('extensions.chipHostMappings'))).toBeInTheDocument()
    // Routing rules read as "matcher → action" rather than as a stringified
    // object in a 9.5px monospace block.
    // Amber is reserved for the status banner. This disclosure is neutral, or
    // a card would show two identical alarm bars, one of which is a fact.
    const disclosure = within(card0).getByTestId(`routing-rules-${CLEANER.id}`)
    expect(disclosure.className).toContain('bg-surface-container')
    expect(disclosure.className).not.toContain('warning-container')
    await user.click(screen.getByText('查看精确路由规则 · 1'))
    const rule = within(card0).getByRole('listitem')
    expect(rule).toHaveTextContent('DOMAIN-SUFFIX')
    expect(rule).toHaveTextContent('ads.example.com')
    expect(rule).toHaveTextContent('UDP')
    expect(rule).toHaveTextContent('REJECT')
    expect(screen.getByRole('link', { name: /打开插件目录/ })).toHaveAttribute('href', VIEW.catalog_url)
    expect(screen.queryByTestId('extension-traffic-contract')).not.toBeInTheDocument()
    expect(screen.queryByRole('tab', { name: '插件市场' })).not.toBeInTheDocument()
  })

  /**
   * Every network disclosure used to be gated on a non-empty origin list, so an
   * extension granted the unrestricted capability — which by definition has no
   * list — rendered as "no additional network access requested" and suppressed
   * the warning entirely. That told an operator the opposite of what enabling
   * would grant, in the one place the decision is made.
   */
  it('warns about an unrestricted network grant that has no origin list', async () => {
    const unrestricted: InterceptModule = { ...CLEANER, network: true }
    vi.mocked(api.getInterceptModules).mockResolvedValue({ ...cloneView(), modules: [unrestricted] })
    renderPage()
    const row = await screen.findByTestId(`capabilities-${unrestricted.id}`)
    expect(within(row).getByText(i18n.t('extensions.networkChip'))).toBeInTheDocument()
    expect(screen.queryByText(i18n.t('extensions.networkNone'))).not.toBeInTheDocument()
  })

  /**
   * The capability row is an inventory, and the row's own comment said "one
   * neutral shape" while its first entry was painted `primary-container` — so
   * the card claimed the capture-host count mattered more than the six chips
   * beside it, for no reason other than being first in the list. It stays a
   * button because it opens the host audit; only the tone changes.
   */
  it('tones every capability chip alike, including the one that opens the audit', async () => {
    renderPage()
    const row = await screen.findByTestId(`capabilities-${CLEANER.id}`)
    const audit = within(row).getByRole('button', { name: i18n.t('extensions.auditHosts') })
    expect(audit.className).toContain('bg-surface-container')
    expect(audit.className).not.toContain('primary-container')
  })

  /**
   * Seven chips at 390px wrap into three rows and push the card's own actions
   * off a phone screen, so below `md` the row is capped and the remainder
   * becomes a count that opens the detail. The cap uses the same 767px branch
   * every other page in this console uses — Tailwind's `sm` would fire at
   * 640px, while the card is still rendering its wide form.
   */
  it('caps the capability row on a phone and routes the rest to the detail', async () => {
    setMobile(true)
    try {
      renderPage()
      const row = await screen.findByTestId(`capabilities-${CLEANER.id}`)
      // 4 chips plus the overflow control.
      expect(within(row).getAllByText(/./, { selector: 'span,button' }).length).toBeGreaterThan(0)
      expect(within(row).getByText(/还有 \d+ 项/)).toBeInTheDocument()
    } finally {
      setMobile(false)
    }
  })

  it('arms a valid native extension while the MITM master is off after confirmation', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('switch'))
    const dialog = await screen.findByRole('dialog')
    // The grant names no addresses, so the confirmation has to say that it
    // cannot say where -- that is the whole risk being accepted.
    expect(dialog).toHaveTextContent('权限本身无法说明它会访问何处')
    expect(dialog).toHaveTextContent('本次启用确认同时授权这些已审查的 REJECT/DIRECT 规则')
    // The confirmation still has to state every declared field; it just states
    // them as matcher → action rather than as a stringified object.
    const rule = within(dialog).getByRole('listitem')
    expect(rule).toHaveTextContent('DOMAIN-SUFFIX')
    expect(rule).toHaveTextContent('ads.example.com')
    expect(rule).toHaveTextContent('UDP')
    expect(rule).toHaveTextContent('REJECT')
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

  /**
   * An upstream plugin format gates a whole script entry on a switch instead of
   * passing it to the script, so a boolean setting can decide whether an action
   * is loaded at all. That is a bigger consequence than a preference -- the one
   * that made this feature necessary switches off a request to a third party --
   * so the operator has to be able to read it before flipping the toggle.
   */
  it('says which actions a boolean setting switches off', async () => {
    const gated: InterceptModule = {
      ...CLEANER,
      settings: [{ key: 'airborne', type: 'boolean', label: 'Airborne helper', required: true, value: true }],
      actions: [
        { id: 'transform-airborne', phase: 'request', match: { hosts: ['api.example.com'], schemes: ['https'], path_regex: '^/' }, enabled_when: 'airborne', script_digest: 'c'.repeat(64), body_mode: 'binary', timeout_ms: 1000, max_body_bytes: 1024 },
        { id: 'clean-json', phase: 'response', match: { hosts: ['api.example.com'], schemes: ['https'], path_regex: '^/' }, script_digest: 'd'.repeat(64), body_mode: 'text', timeout_ms: 1000, max_body_bytes: 1024 },
      ],
    }
    vi.mocked(api.getInterceptModules).mockResolvedValue({ ...cloneView(), modules: [gated] })
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${gated.id}`)
    await user.click(within(card).getByRole('button', { name: '设置 · 1' }))
    const dialog = await screen.findByRole('dialog', { name: /Response Cleaner/ })
    const note = within(dialog).getByText(/transform-airborne/)
    expect(note).toHaveTextContent('停用 1 个 action')
    expect(note).not.toHaveTextContent('clean-json')
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
    const banner = within(card).getByTestId(`extension-status-${CLEANER.id}`)
    expect(banner).toHaveAttribute('role', 'alert')
    expect(banner).toHaveTextContent(i18n.t('extensions.statusEgressMissing', { group: 'RemovedGroup' }))
    expect(within(banner).getByRole('link', { name: i18n.t('extensions.statusGoSettings') }))
      .toHaveAttribute('href', '/settings')
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
    expect(dialog).toHaveTextContent('权限本身无法说明它会访问何处')
    // The confirmation still has to state every declared field; it just states
    // them as matcher → action rather than as a stringified object.
    const rule = within(dialog).getByRole('listitem')
    expect(rule).toHaveTextContent('DOMAIN-SUFFIX')
    expect(rule).toHaveTextContent('ads.example.com')
    expect(rule).toHaveTextContent('UDP')
    expect(rule).toHaveTextContent('REJECT')
    await user.click(within(dialog).getByRole('button', { name: '替换快照' }))
    await waitFor(() => expect(api.applyInterceptModuleUpdate).toHaveBeenCalledWith(CLEANER.id, VIEW.revision, candidate.snapshot_digest))
  })
})
