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
  reason: 'settings-required', capture_hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'], script_count: 1,
  settings: [
    { key: 'location', type: 'location', label: 'Target location', required: true, value: { accuracy: 25 } },
    { key: 'failClosed', type: 'boolean', label: 'Block on transformation failure', required: true, value: true },
  ],
  persistent_storage: false,
  source_url: 'https://raw.githubusercontent.com/moooyo/5gpn/main/extensions/apple-wloc/extension.yaml',
  source_digest: 'a'.repeat(64), snapshot_digest: 'a'.repeat(64), imported_at: '2026-07-18T00:00:00Z',
}

const CLEANER: InterceptModule = {
  id: 'io.example.response-cleaner', extension_version: '1.0.0', name: 'Response Cleaner',
  description: 'Native response action fixture.', enabled: false, ready: true, reason: undefined,
  capture_hosts: ['api.example.com'], script_count: 1, settings: [], persistent_storage: false,
  upstream_mappings: [{ host: 'api.example.com', target: 'origin.example.net' }],
  source_url: 'https://extensions.example.test/clean.yaml', source_digest: 'b'.repeat(64), snapshot_digest: 'b'.repeat(64), imported_at: '2026-07-18T00:00:00Z',
}

const VIEW: InterceptModulesView = {
  revision: '1'.repeat(64),
  catalog_url: 'https://github.com/moooyo/5gpn/tree/main/extensions',
  active_capture_hosts: [],
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
    return next
  })
  vi.mocked(api.deleteInterceptModule).mockResolvedValue(cloneView())
  vi.mocked(api.getInterceptModuleSnapshot).mockResolvedValue({ id: CLEANER.id, name: CLEANER.name, source_digest: CLEANER.source_digest, source_body: 'apiVersion: 5gpn.io/v1', scripts: [] })
})

describe('ExtensionsPage native extension contract', () => {
  it('renders the capture-transform-egress rail and native extension snapshots', async () => {
    renderPage()
    expect(await screen.findByText('Response Cleaner')).toBeInTheDocument()
    expect(screen.getByTestId('extension-traffic-contract')).toHaveTextContent('声明接管域名')
    expect(screen.getByTestId('extension-traffic-contract')).toHaveTextContent('mihomo 决定出口')
    expect(screen.getByText('接管 · 1')).toBeInTheDocument()
    expect(screen.getByText('上游映射 · 1')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /打开插件目录/ })).toHaveAttribute('href', VIEW.catalog_url)
  })

  it('arms a valid native extension while the MITM master is off after confirmation', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId(`extension-${CLEANER.id}`)
    await user.click(within(card).getByRole('switch'))
    await user.click(within(await screen.findByRole('dialog')).getByRole('button', { name: '启用' }))
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
    await user.click(within(dialog).getByRole('button', { name: '替换快照' }))
    await waitFor(() => expect(api.applyInterceptModuleUpdate).toHaveBeenCalledWith(CLEANER.id, VIEW.revision, candidate.snapshot_digest))
  })
})
