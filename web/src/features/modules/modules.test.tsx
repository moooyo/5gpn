import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
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
  ca_profile_url: '/ios/ios-intercept-ca.mobileconfig',
  catalog_url: 'https://hub.kelee.one/',
  active_hosts: [],
  modules: [
    {
      id: 'builtin-wloc', name: 'Apple WLOC response rewriting', format: 'builtin', enabled: false, ready: true,
      compatibility: 'full', partial_allowed: false, hosts: ['gs-loc.apple.com', 'gs-loc-cn.apple.com'],
      script_count: 1, rewrite_count: 0, source_digest: 'a'.repeat(64),
    },
    {
      id: 'mod-1234567890abcdef', name: 'Response Cleaner', description: 'Synthetic Surge fixture', format: 'surge',
      enabled: false, ready: true, compatibility: 'partial', partial_allowed: true, hosts: ['api.example.com'],
      script_count: 1, rewrite_count: 1, source_url: 'https://example.com/test.sgmodule', source_digest: 'b'.repeat(64),
      imported_at: '2026-07-18T00:00:00Z', argument: '', unsupported: ['[Rule] unsupported'],
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
  profile_url: '/ios/ios-intercept-ca.mobileconfig',
}

function cloneView(): InterceptModulesView {
  return { ...VIEW, active_hosts: [...VIEW.active_hosts], modules: VIEW.modules.map((module) => ({ ...module, hosts: [...module.hosts], unsupported: module.unsupported ? [...module.unsupported] : undefined })) }
}

beforeEach(async () => {
  await i18n.changeLanguage('zh')
  vi.mocked(api.getInterceptModules).mockReset().mockResolvedValue(cloneView())
  vi.mocked(api.getInterceptModuleSnapshot).mockReset().mockResolvedValue({
    id: 'mod-1234567890abcdef', name: 'Response Cleaner', format: 'surge',
    source_url: 'https://example.com/test.sgmodule', source_digest: 'b'.repeat(64),
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
  return render(<><ModulesPage /><Toaster /></>)
}

describe('ModulesPage', () => {
  it('renders immutable snapshots, compatibility, and the external catalog link', async () => {
    renderPage()
    expect(await screen.findByText('Response Cleaner')).toBeInTheDocument()
    expect(screen.getByText('部分兼容')).toBeInTheDocument()
    expect(screen.getByText('api.example.com')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: /打开模块商店/ })).toHaveAttribute('href', 'https://hub.kelee.one/')
    expect(screen.getByRole('link', { name: /下载拦截 CA/ })).toHaveAttribute('href', '/ios/ios-intercept-ca.mobileconfig')
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

  it('imports a URL with the Quantumult X header preset and Referer', async () => {
    const user = userEvent.setup()
    renderPage()
    await user.click(await screen.findByRole('button', { name: /导入模块/ }))
    const dialog = await screen.findByRole('dialog')
    await user.type(within(dialog).getByLabelText('模块 URL'), 'https://example.com/test.sgmodule')
    await user.click(within(dialog).getByRole('button', { name: '获取、固化并检查' }))
    await waitFor(() => expect(api.importInterceptModule).toHaveBeenCalledWith({
      revision: VIEW.revision,
      url: 'https://example.com/test.sgmodule',
      format: 'auto',
      fetch_profile: 'quantumult-x',
      referer: 'https://hub.kelee.one/',
      argument: undefined,
      partial_allowed: false,
    }))
  })
})
