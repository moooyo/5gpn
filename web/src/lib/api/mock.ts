/*
 * Mock implementations backing client.ts's MOCK-branch when
 * VITE_API_MOCK=1. Each fn resolves from the in-memory fixtures (mutated in
 * place for the write ops, so a mock session behaves like a tiny stateful
 * backend) after a small artificial delay so loading states in the UI are
 * exercised even without a real network. Only current API surfaces are mocked.
 */
import * as fixtures from './fixtures'
import { ApiError } from './http'
import type * as T from './types'

const delay = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))

// ---- mihomo config editor -------------------------------------------------
// Mirrors the real apply pipeline's ONE observable invariant check the
// editor page (next unit) needs to exercise: a submitted text missing the
// `external-controller:` line is rejected with the same ApiError(400, …)
// shape a live 400 response produces (http.ts's throwForStatus reads the
// JSON body's `error` field into the thrown message) — callers don't need to
// branch on mock-vs-live to handle the rejection path.
const missingControllerMsg = 'missing required infrastructure: controller'
let mihomoRevisionSequence = 1

function advanceMihomoRevision(): void {
  mihomoRevisionSequence++
  const revision = mihomoRevisionSequence.toString(16).padStart(64, '0')
  fixtures.mihomoConfig.revision = revision
  fixtures.ingressModules.revision = revision
}

export async function getMihomoConfig(): Promise<T.MihomoConfig> {
  await delay(100)
  return { ...fixtures.mihomoConfig }
}
export async function putMihomoConfig(text: string, revision: string): Promise<T.MihomoConfig> {
  await delay(150)
  if (revision !== fixtures.mihomoConfig.revision) {
    throw new ApiError(409, 'The mihomo configuration changed. Reload and merge your edit.')
  }
  if (!text.includes('external-controller:')) {
    throw new ApiError(400, missingControllerMsg)
  }
  fixtures.mihomoConfig.text = text
  fixtures.mihomoConfig.applied_at = new Date().toISOString()
  advanceMihomoRevision()
  return { ...fixtures.mihomoConfig }
}
export async function resetMihomoConfig(revision: string): Promise<T.MihomoConfig> {
  await delay(150)
  if (revision !== fixtures.mihomoConfig.revision) {
    throw new ApiError(409, 'The mihomo configuration changed. Reload before restoring the default.')
  }
  fixtures.mihomoConfig.text = fixtures.mihomoConfigDefaultText
  fixtures.mihomoConfig.applied_at = new Date().toISOString()
  advanceMihomoRevision()
  return { ...fixtures.mihomoConfig }
}

// ---- ingress modules -----------------------------------------------------

function ingressModulesView(): T.IngressModulesView {
  return {
    revision: fixtures.ingressModules.revision,
    modules: fixtures.ingressModules.modules.map((module) => ({
      ...module,
      networks: [...module.networks],
      sniffers: [...module.sniffers],
    })),
  }
}

export async function getIngressModules(): Promise<T.IngressModulesView> {
  await delay(100)
  return ingressModulesView()
}

export async function putIngressModule(id: string, enabled: boolean, revision: string): Promise<T.IngressModulesView> {
  await delay(150)
  if (revision !== fixtures.ingressModules.revision) {
    throw new ApiError(409, 'The ingress configuration changed. Refresh and try again.')
  }
  const module = fixtures.ingressModules.modules.find((candidate) => candidate.id === id)
  if (!module) throw new ApiError(404, 'Ingress module not found.')
  if (!module.manageable) throw new ApiError(409, 'This module is managed by a custom mihomo configuration.')
  module.enabled = enabled
  advanceMihomoRevision()
  return ingressModulesView()
}

export async function getMITMSettings(): Promise<T.MITMSettingsView> {
  await delay(100)
  return { ...fixtures.mitmSettings }
}

export async function putMITMSettings(update: T.MITMSettingsUpdate): Promise<T.MITMSettingsView> {
  await delay(150)
  if (update.revision !== fixtures.mitmSettings.revision) {
    throw new ApiError(409, 'The MITM configuration changed. Refresh and try again.')
  }
  const revision = (BigInt(`0x${fixtures.mitmSettings.revision}`) + 1n).toString(16).padStart(64, '0')
  Object.assign(fixtures.mitmSettings, update, { revision })
  fixtures.interceptModules.revision = revision
  refreshActiveInterceptHosts()
  return { ...fixtures.mitmSettings }
}

function interceptModulesView(): T.InterceptModulesView {
  return {
    ...fixtures.interceptModules,
    active_capture_hosts: [...fixtures.interceptModules.active_capture_hosts],
    execution_order: [...fixtures.interceptModules.execution_order],
    available_egress_groups: [...fixtures.interceptModules.available_egress_groups],
    modules: fixtures.interceptModules.modules.map((module) => ({
      ...module,
      capture_hosts: [...module.capture_hosts],
      network_origins: [...module.network_origins],
      settings: module.settings?.map((setting) => ({ ...setting })),
      upstream_mappings: module.upstream_mappings?.map((mapping) => ({ ...mapping })),
    })),
  }
}

function advanceInterceptRevision(): void {
  const revision = (BigInt(`0x${fixtures.interceptModules.revision}`) + 1n).toString(16).padStart(64, '0')
  fixtures.interceptModules.revision = revision
  fixtures.mitmSettings.revision = revision
}

function refreshActiveInterceptHosts(): void {
  const masterEnabled = fixtures.mitmSettings.enabled
  fixtures.interceptModules.active_capture_hosts = masterEnabled
    ? Array.from(
        new Set(fixtures.interceptModules.modules.filter((module) => module.enabled &&
          (!module.egress_group_required || !!module.egress_group) &&
          (!module.egress_group || fixtures.interceptModules.available_egress_groups.includes(module.egress_group)))
          .flatMap((module) => module.capture_hosts)),
      ).sort()
    : []
  for (const module of fixtures.interceptModules.modules) {
    if (!masterEnabled) {
      module.ready = false
      module.reason = 'mitm-disabled'
    } else if (module.egress_group_required && (!module.egress_group || !fixtures.interceptModules.available_egress_groups.includes(module.egress_group))) {
      module.ready = false
      module.reason = 'egress-group-missing'
    } else if (module.reason !== 'settings-required') {
      module.ready = true
      module.reason = undefined
    }
  }
}

export async function getInterceptModules(): Promise<T.InterceptModulesView> {
  await delay(100)
  return interceptModulesView()
}

export async function getInterceptModuleSnapshot(id: string): Promise<T.InterceptModuleSnapshot> {
  await delay(80)
  const module = fixtures.interceptModules.modules.find((candidate) => candidate.id === id)
  if (!module) throw new ApiError(404, 'Interception module not found.')
  return {
    id, name: module.name, source_url: module.source_url,
    source_digest: module.source_digest,
    source_body: 'apiVersion: 5gpn.io/v1\nkind: Extension\nmetadata:\n  id: io.example.response-cleaner\n  name: Synthetic response cleaner\n  version: 1.0.0\n',
    scripts: [{
      id: 'clean-response', url: 'https://extensions.example.test/clean.js', digest: 'd'.repeat(64),
      body: 'function transform(context) { return { response: { body: context.response.body } } }',
    }],
  }
}

export async function importInterceptModule(request: T.InterceptModuleImport): Promise<T.InterceptModulesView> {
  await delay(180)
  if (request.revision !== fixtures.interceptModules.revision) {
    throw new ApiError(409, 'The interception module registry changed. Refresh and try again.')
  }
  const seed = (request.url || request.content || 'module').length.toString(16).padStart(16, '0').slice(-16)
  const id = `io.example.imported-${seed}`
  if (fixtures.interceptModules.modules.some((module) => module.id === id)) {
    throw new ApiError(409, 'This immutable snapshot is already imported.')
  }
  fixtures.interceptModules.modules.push({
    id,
    extension_version: '1.0.0',
    name: 'Imported native extension',
    description: 'Mock native manifest preview',
    enabled: false,
    ready: true,
    capture_hosts: ['service.example.test'],
    capture_dns: 'trust',
    script_count: 1,
    settings: [],
    persistent_storage: false,
    source_url: request.url,
    source_digest: 'c'.repeat(64),
    snapshot_digest: 'c'.repeat(64),
    imported_at: new Date().toISOString(),
    execution_order: fixtures.interceptModules.modules.length + 1,
    network_origins: [],
    egress_group_required: false,
  })
  fixtures.interceptModules.execution_order = fixtures.interceptModules.modules.map((module) => module.id)
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
  return interceptModulesView()
}

function mockUpdateCandidate(module: T.InterceptModule): T.InterceptModule {
  return {
    ...module,
    extension_version: '1.1.0',
    enabled: false,
    ready: true,
    reason: undefined,
    source_digest: 'e'.repeat(64),
    snapshot_digest: 'f'.repeat(64),
    imported_at: new Date().toISOString(),
    capture_hosts: [...module.capture_hosts],
    settings: module.settings?.map((setting) => ({ ...setting })),
  }
}

export async function checkInterceptModuleUpdate(id: string, revision: string): Promise<T.InterceptModuleUpdateCheck> {
  await delay(150)
  if (revision !== fixtures.interceptModules.revision) throw new ApiError(409, 'The extension registry changed. Refresh and try again.')
  const module = fixtures.interceptModules.modules.find((candidate) => candidate.id === id)
  if (!module) throw new ApiError(404, 'Extension not found.')
  if (!module.source_url) throw new ApiError(400, 'Only URL-sourced extensions can check for updates.')
  return { revision, state: 'available', candidate: mockUpdateCandidate(module) }
}

export async function applyInterceptModuleUpdate(id: string, revision: string, snapshotDigest: string): Promise<T.InterceptModulesView> {
  await delay(180)
  if (revision !== fixtures.interceptModules.revision) throw new ApiError(409, 'The extension registry changed. Refresh and try again.')
  const index = fixtures.interceptModules.modules.findIndex((candidate) => candidate.id === id)
  if (index < 0) throw new ApiError(404, 'Extension not found.')
  const current = fixtures.interceptModules.modules[index]
  if (current.enabled) throw new ApiError(400, 'Disable the extension before applying an update.')
  const candidate = mockUpdateCandidate(current)
  if (candidate.snapshot_digest !== snapshotDigest) throw new ApiError(409, 'The reviewed candidate changed. Check again.')
  fixtures.interceptModules.modules[index] = candidate
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
  return interceptModulesView()
}

export async function putInterceptModule(id: string, update: T.InterceptModuleUpdate): Promise<T.InterceptModulesView> {
  await delay(150)
  if (update.revision !== fixtures.interceptModules.revision) {
    throw new ApiError(409, 'The interception module registry changed. Refresh and try again.')
  }
  const module = fixtures.interceptModules.modules.find((candidate) => candidate.id === id)
  if (!module) throw new ApiError(404, 'Interception module not found.')
  if (update.enabled !== undefined) {
    module.enabled = update.enabled
    module.ready = true
  }
  if (update.settings !== undefined && module.settings) {
    module.settings = module.settings.map((setting) => ({ ...setting, value: update.settings?.[setting.key] }))
    module.ready = module.settings.every((setting) => !setting.required || setting.value !== undefined)
    module.reason = module.ready ? undefined : 'settings-required'
  }
  if (update.egress_group !== undefined) module.egress_group = update.egress_group
  if (update.capture_dns !== undefined) module.capture_dns = update.capture_dns
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
  return interceptModulesView()
}

export async function reorderInterceptModules(revision: string, executionOrder: string[]): Promise<T.InterceptModulesView> {
  await delay(150)
  if (revision !== fixtures.interceptModules.revision) {
    throw new ApiError(409, 'The interception module registry changed. Refresh and try again.')
  }
  const modules = fixtures.interceptModules.modules
  if (executionOrder.length !== modules.length || new Set(executionOrder).size !== modules.length || executionOrder.some((id) => !modules.some((module) => module.id === id))) {
    throw new ApiError(400, 'Execution order must include every installed extension exactly once.')
  }
  const byID = new Map(modules.map((module) => [module.id, module]))
  fixtures.interceptModules.modules.splice(0, modules.length, ...executionOrder.map((id, index) => ({ ...byID.get(id)!, execution_order: index + 1 })))
  fixtures.interceptModules.execution_order = [...executionOrder]
  advanceInterceptRevision()
  return interceptModulesView()
}

export async function deleteInterceptModule(id: string, revision: string): Promise<T.InterceptModulesView> {
  await delay(120)
  if (revision !== fixtures.interceptModules.revision) {
    throw new ApiError(409, 'The interception module registry changed. Refresh and try again.')
  }
  const index = fixtures.interceptModules.modules.findIndex((module) => module.id === id)
  if (index < 0) throw new ApiError(404, 'Interception module not found.')
  if (fixtures.interceptModules.modules[index].enabled) throw new ApiError(400, 'Disable the module before deleting it.')
  fixtures.interceptModules.modules.splice(index, 1)
  fixtures.interceptModules.execution_order = fixtures.interceptModules.modules.map((module, order) => {
    module.execution_order = order + 1
    return module.id
  })
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
  return interceptModulesView()
}

let marketplaceRevision = '2000000000000000000000000000000000000000000000000000000000000001'
let marketplaces: T.MarketplaceSource[] = [{
  id: 'io.5gpn.official',
  name: '5GPN Extensions',
  metadata_name: '5GPN Extensions',
  description: 'Maintained native extensions for explicit review and snapshot installation.',
  homepage: 'https://github.com/moooyo/5gpn-extensions',
  url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json',
  final_url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json',
  digest: '9'.repeat(64),
  snapshot_digest: '6'.repeat(64),
  fetched_at: '2026-07-20T00:00:00Z',
  entries: [{
    id: 'io.5gpn.apple-wloc', name: 'Apple WLOC Location Override', version: '1.0.0',
    description: 'Override Apple location responses with an operator-selected point.',
    tags: ['location', 'apple'], license: { spdx: 'MIT' },
    documentation_url: 'https://github.com/moooyo/5gpn-extensions',
    manifest_url: 'https://raw.githubusercontent.com/moooyo/5gpn-extensions/main/apple-wloc/extension.yaml',
    manifest_digest: 'a'.repeat(64),
    capabilities: { capture_host_count: 2, action_count: 1, setting_count: 2, network_origins: [], persistent_storage: false, upstream_mapping_count: 0, routing_rule_count: 0, egress_group_required: false },
  }, {
    id: 'io.example.marketplace-cleaner', name: 'Marketplace Response Cleaner', version: '1.0.0',
    description: 'A native response transformation example from the marketplace.',
    tags: ['response', 'example'], license: { spdx: 'Apache-2.0' },
    manifest_url: 'https://extensions.example.test/marketplace-cleaner.yaml', manifest_digest: '7'.repeat(64),
    capabilities: { capture_host_count: 1, action_count: 1, setting_count: 0, network_origins: ['https://origin.example.net'], persistent_storage: false, upstream_mapping_count: 1, routing_rule_count: 0, egress_group_required: true },
  }],
}]

function marketplacesView(): T.MarketplacesView {
  return { revision: marketplaceRevision, recommended_url: 'https://moooyo.github.io/5gpn-extensions/marketplace/v1/index.json', sources: structuredClone(marketplaces) }
}

function advanceMarketplaceRevision(): void {
  marketplaceRevision = (BigInt(`0x${marketplaceRevision}`) + 1n).toString(16).padStart(64, '0')
}

export async function getMarketplaces(): Promise<T.MarketplacesView> {
  await delay(100)
  return marketplacesView()
}

export async function addMarketplace(revision: string, url: string, name?: string): Promise<T.MarketplacesView> {
  await delay(160)
  if (revision !== marketplaceRevision) throw new ApiError(409, 'The marketplace ledger changed. Refresh and try again.')
  if (!url.startsWith('https://')) throw new ApiError(400, 'Marketplace URLs must use HTTPS.')
  marketplaces.push({ id: `source-${marketplaces.length + 1}`, name: name?.trim() || 'Added marketplace', metadata_name: 'Added marketplace', url, final_url: url, digest: '8'.repeat(64), snapshot_digest: '5'.repeat(64), fetched_at: new Date().toISOString(), entries: [] })
  advanceMarketplaceRevision()
  return marketplacesView()
}

export async function refreshMarketplace(id: string, revision: string): Promise<T.MarketplacesView> {
  await delay(140)
  if (revision !== marketplaceRevision) throw new ApiError(409, 'The marketplace ledger changed. Refresh and try again.')
  const source = marketplaces.find((candidate) => candidate.id === id)
  if (!source) throw new ApiError(404, 'Marketplace source not found.')
  source.fetched_at = new Date().toISOString()
  advanceMarketplaceRevision()
  return marketplacesView()
}

export async function deleteMarketplace(id: string, revision: string): Promise<T.MarketplacesView> {
  await delay(120)
  if (revision !== marketplaceRevision) throw new ApiError(409, 'The marketplace ledger changed. Refresh and try again.')
  marketplaces = marketplaces.filter((candidate) => candidate.id !== id)
  advanceMarketplaceRevision()
  return marketplacesView()
}

export async function installMarketplaceEntry(marketplace: string, extension: string, sourceRevision: string, moduleRevision: string): Promise<T.InterceptModulesView> {
  await delay(180)
  if (sourceRevision !== marketplaceRevision || moduleRevision !== fixtures.interceptModules.revision) throw new ApiError(409, 'The marketplace changed. Refresh and try again.')
  const entry = marketplaces.find((source) => source.id === marketplace)?.entries.find((candidate) => candidate.id === extension)
  if (!entry) throw new ApiError(404, 'Marketplace extension not found.')
  if (fixtures.interceptModules.modules.some((module) => module.id === entry.id)) throw new ApiError(409, 'This extension is already installed.')
  fixtures.interceptModules.modules.push({
    id: entry.id, extension_version: entry.version, name: entry.name, description: entry.description,
    enabled: false, ready: true, capture_hosts: Array.from({ length: entry.capabilities.capture_host_count }, (_, index) => `capture-${index + 1}.example.test`), capture_dns: 'trust',
    script_count: entry.capabilities.action_count, settings: [], persistent_storage: entry.capabilities.persistent_storage,
    source_url: entry.manifest_url, source_digest: entry.manifest_digest, snapshot_digest: entry.manifest_digest,
    imported_at: new Date().toISOString(), execution_order: fixtures.interceptModules.modules.length + 1,
    network_origins: [...entry.capabilities.network_origins], egress_group_required: entry.capabilities.egress_group_required,
  })
  fixtures.interceptModules.execution_order = fixtures.interceptModules.modules.map((module) => module.id)
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
  return interceptModulesView()
}

export async function searchCities(query: string, _language: string): Promise<T.CitySearchResult[]> {
  await delay(120)
  if (!query.trim()) return []
  return [{ place_id: 1, display_name: `${query}, China`, lat: '22.544577', lon: '113.94114' }]
}

// ---- Unified policy rules -------------------------------------------------
// Same quartet-plus-apply idiom as the mihomo-config mocks above, plus a
// reorder op (rules are order-sensitive — first match wins) and a fallback
// get/put.

export async function getPolicyRules(): Promise<T.PolicyRule[]> {
  await delay(120)
  return fixtures.policyRules
}
export async function createPolicyRule(r: Omit<T.PolicyRule, 'id' | 'order'>): Promise<T.PolicyRule> {
  await delay(120)
  const entry: T.PolicyRule = { ...r, id: `prule-${fixtures.policyRules.length + 1}`, order: fixtures.policyRules.length }
  fixtures.policyRules.push(entry)
  return entry
}
export async function updatePolicyRule(id: string, r: Omit<T.PolicyRule, 'id' | 'order'>): Promise<T.PolicyRule> {
  await delay(120)
  const idx = fixtures.policyRules.findIndex((p) => p.id === id)
  const order = idx >= 0 ? fixtures.policyRules[idx].order : fixtures.policyRules.length
  const entry: T.PolicyRule = { ...r, id, order }
  if (idx >= 0) fixtures.policyRules[idx] = entry
  return entry
}
export async function deletePolicyRule(id: string): Promise<{ ok: boolean }> {
  await delay(120)
  const idx = fixtures.policyRules.findIndex((p) => p.id === id)
  if (idx < 0) return { ok: false }
  fixtures.policyRules.splice(idx, 1)
  fixtures.policyRules.forEach((p, i) => (p.order = i))
  return { ok: true }
}
export async function reorderPolicyRules(ids: string[]): Promise<{ ok: boolean }> {
  await delay(120)
  const byId = new Map(fixtures.policyRules.map((p) => [p.id, p]))
  const next = ids.map((id, i) => ({ ...byId.get(id)!, order: i }))
  fixtures.policyRules.splice(0, fixtures.policyRules.length, ...next)
  return { ok: true }
}
export async function getPolicyFallback(): Promise<T.PolicyFallback> {
  await delay(120)
  return fixtures.policyFallback
}
export async function putPolicyFallback(f: T.PolicyFallback): Promise<{ ok: boolean }> {
  await delay(120)
  // Mutate in place, not `fixtures.policyFallback = f` — a namespace-import
  // binding is read-only from the consumer side (TS2540), even though the
  // exporting module could reassign its own `let`/`const`.
  Object.assign(fixtures.policyFallback, f)
  return { ok: true }
}
export async function applyPolicy(): Promise<{ ok: boolean }> {
  await delay(200)
  return { ok: true }
}
