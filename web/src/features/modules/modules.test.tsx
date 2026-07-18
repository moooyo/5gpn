import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import i18n from '../../i18n'
import { Toaster } from '../../components/ds'
import { api } from '../../lib/api/client'
import type { InterceptModulesView, WLOCInterceptView } from '../../lib/api/types'
import ModulesPage from './ModulesPage'

vi.mock('../../lib/api/client', () => ({
  api: {
    getInterceptModules: vi.fn(),
    getInterceptModuleSnapshot: vi.fn(),
    importInterceptModule: vi.fn(),
    putInterceptModule: vi.fn(),
    deleteInterceptModule: vi.fn(),
    getWLOCIntercept: vi.fn(),
    putWLOCIntercept: vi.fn(),
  },
}))

const VIEW: InterceptModulesView = {
  revision: '1'.repeat(64),
  catalog_url: 'https://hub.kelee.one/',
  active_hosts: [],
  modules: [
    {
      id: 'builtin-wloc', name: 'Apple WLOC response rewriting', enabled: false, ready: true,
      compatibility: 'full', partial_allowed: false, hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
      script_count: 1, rewrite_count: 0, source_digest: 'a'.repeat(64),
    },
    {
      id: 'mod-1234567890abcdef', name: 'Response Cleaner', description: 'Synthetic Loon fixture',
      enabled: false, ready: true, compatibility: 'partial', partial_allowed: true, hosts: ['api.example.com'],
      script_count: 1, rewrite_count: 1, source_url: 'https://example.com/test.lpx', source_digest: 'b'.repeat(64),
      imported_at: '2026-07-18T00:00:00Z', argument: '', unsupported: ['[Rule] unsupported'],
      issues: [{ severity: 'warning', message: '[Rule] unsupported' }],
      host_mappings: [{ pattern: 'api.example.com', target: 'origin.example.net' }],
    },
  ],
}

const WLOC: WLOCInterceptView = {
  revision: VIEW.revision,
  enabled: false,
  longitude: null,
  latitude: null,
  accuracy: 25,
  fail_closed: true,
  max_body_bytes: 8388608,
  hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
}

function cloneView(): InterceptModulesView {
  return { ...VIEW, active_hosts: [...VIEW.active_hosts], modules: VIEW.modules.map((module) => ({ ...module, hosts: [...module.hosts], unsupported: module.unsupported ? [...module.unsupported] : undefined })) }
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.getInterceptModules).mockReset().mockResolvedValue(cloneView())
  vi.mocked(api.getInterceptModuleSnapshot).mockReset().mockResolvedValue({
    id: 'mod-1234567890abcdef', name: 'Response Cleaner',
    source_url: 'https://example.com/test.lpx', source_digest: 'b'.repeat(64),
    source_body: '#!name=Response Cleaner\n[MITM]\nhostname=api.example.com',
    scripts: [{ id: 'script-001', url: 'https://example.com/clean.js', digest: 'd'.repeat(64), body: '$done({body: $response.body});' }],
  })
  vi.mocked(api.getWLOCIntercept).mockReset().mockResolvedValue({ ...WLOC })
  vi.mocked(api.putInterceptModule).mockReset().mockResolvedValue(cloneView())
  vi.mocked(api.deleteInterceptModule).mockReset().mockResolvedValue(cloneView())
  vi.mocked(api.importInterceptModule).mockReset().mockResolvedValue(cloneView())
  vi.mocked(api.putWLOCIntercept).mockReset().mockResolvedValue({ ...WLOC })
})

afterEach(() => vi.restoreAllMocks())

function renderPage() {
  return render(<MemoryRouter><ModulesPage /><Toaster /></MemoryRouter>)
}

describe('ModulesPage', () => {
  it('renders immutable snapshots, compatibility, and the external catalog link', async () => {
    renderPage()
    expect(await screen.findByText('Response Cleaner')).toBeInTheDocument()
    expect(screen.getByText('部分兼容')).toBeInTheDocument()
    expect(screen.getAllByText('api.example.com').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText('origin.example.net')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /打开模块商店/ })).toHaveAttribute('href', 'https://hub.kelee.one/')
    expect(screen.getByTestId('mitm-ca-guide-notice')).toHaveTextContent('所有模块共用同一个 5gpn 根证书')
    expect(screen.getByRole('link', { name: /前往配置向导/ })).toHaveAttribute('href', '/setup-guide')
    expect(screen.queryByRole('link', { name: /下载.*CA/ })).toBeNull()
  })

  it('confirms and publishes a module toggle with the registry revision', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId('module-mod-1234567890abcdef')
    await user.click(within(card).getByRole('switch'))
    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: '启用' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith('mod-1234567890abcdef', {
      revision: VIEW.revision,
      enabled: true,
    }))
  })

  it('loads the exact source and script snapshot only when the operator inspects it', async () => {
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId('module-mod-1234567890abcdef')
    await user.click(within(card).getByRole('button', { name: '审查快照' }))
    await waitFor(() => expect(api.getInterceptModuleSnapshot).toHaveBeenCalledWith('mod-1234567890abcdef'))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByText(/hostname=api\.example\.com/)).toBeInTheDocument()
    expect(within(dialog).getByText(/\$done/)).toBeInTheDocument()
  })

  it('requires an explicit compatibility acknowledgement before partial execution', async () => {
    const partial = cloneView()
    partial.modules[1].partial_allowed = false
    vi.mocked(api.getInterceptModules).mockResolvedValueOnce(partial)
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId('module-mod-1234567890abcdef')
    expect(within(card).getByRole('switch')).toBeDisabled()
    await user.click(within(card).getByRole('button', { name: '允许部分执行' }))
    const dialog = await screen.findByRole('dialog')
    await user.click(within(dialog).getByRole('button', { name: '允许部分执行' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith('mod-1234567890abcdef', {
      revision: VIEW.revision,
      partial_allowed: true,
    }))
  })

  it('requires post-import parameter configuration before enable', async () => {
    const configurable = cloneView()
    configurable.modules[1].compatibility = 'needs_configuration'
    configurable.modules[1].ready = false
    configurable.modules[1].parameters = [
      { key: 'appName', kind: 'input', value: '' },
      { key: 'mode', kind: 'select', options: ['clean', 'full'], value: '' },
    ]
    vi.mocked(api.getInterceptModules).mockResolvedValueOnce(configurable)
    const user = userEvent.setup()
    renderPage()
    const card = await screen.findByTestId('module-mod-1234567890abcdef')
    expect(within(card).getByRole('switch')).toBeDisabled()
    await user.type(within(card).getByLabelText('appName'), 'Drive')
    await user.selectOptions(within(card).getByLabelText('mode'), 'clean')
    await user.click(within(card).getByRole('button', { name: '保存配置项' }))
    await waitFor(() => expect(api.putInterceptModule).toHaveBeenCalledWith('mod-1234567890abcdef', {
      revision: VIEW.revision,
      parameters: { appName: 'Drive', mode: 'clean' },
    }))
  })

  it('imports a Loon deep link without pre-import format, header, argument, or compatibility controls', async () => {
    const user = userEvent.setup()
    renderPage()
    await user.click(await screen.findByRole('button', { name: /导入模块/ }))
    const dialog = await screen.findByRole('dialog')
    expect(within(dialog).getByTestId('module-import-automatic')).toHaveTextContent('loon://import')
    expect(within(dialog).queryByLabelText('格式')).toBeNull()
    expect(within(dialog).queryByLabelText('初始 $argument')).toBeNull()
    expect(within(dialog).queryByLabelText('使用 Quantumult X 请求头')).toBeNull()
    expect(within(dialog).queryByLabelText('允许明确列出的未支持指令')).toBeNull()
    const deepLink = 'loon://import?plugin=https://example.com/test.lpx'
    await user.type(within(dialog).getByLabelText('模块 URL'), deepLink)
    await user.click(within(dialog).getByRole('button', { name: '获取、固化并检查' }))
    await waitFor(() => expect(api.importInterceptModule).toHaveBeenCalledWith({
      revision: VIEW.revision,
      url: deepLink,
    }))
  })

  it('keeps the import dialog open for structured incompatibility review', async () => {
    const imported = cloneView()
    imported.modules.push({
      id: 'mod-fedcba0987654321', name: 'Needs review', enabled: false, ready: false,
      compatibility: 'incompatible', partial_allowed: false, hosts: ['api.review.test'],
      script_count: 1, rewrite_count: 0, source_digest: 'e'.repeat(64),
      issues: [{ severity: 'error', message: '[Script] outbound networking is disabled' }],
      incompatible: ['[Script] outbound networking is disabled'],
    })
    vi.mocked(api.importInterceptModule).mockResolvedValueOnce(imported)
    const user = userEvent.setup()
    renderPage()
    await user.click(await screen.findByRole('button', { name: /导入模块/ }))
    const dialog = await screen.findByRole('dialog')
    await user.type(within(dialog).getByLabelText('模块 URL'), 'https://example.com/review.lpx')
    await user.click(within(dialog).getByRole('button', { name: '获取、固化并检查' }))
    expect(await within(dialog).findByTestId('module-import-review')).toHaveTextContent('outbound networking is disabled')
    expect(within(dialog).getByRole('button', { name: '我已了解，继续配置' })).toBeInTheDocument()
  })
})
