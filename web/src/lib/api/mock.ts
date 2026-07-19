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
  fixtures.wlocIntercept.revision = revision
  refreshActiveInterceptHosts()
  return { ...fixtures.mitmSettings }
}

export async function getWLOCIntercept(): Promise<T.WLOCInterceptView> {
  await delay(100)
  return { ...fixtures.wlocIntercept, hosts: [...fixtures.wlocIntercept.hosts] }
}

export async function putWLOCIntercept(update: T.WLOCInterceptUpdate): Promise<T.WLOCInterceptView> {
  await delay(150)
  if (update.revision !== fixtures.wlocIntercept.revision) {
    throw new ApiError(409, 'The WLOC interception configuration changed. Refresh and try again.')
  }
  const revision = (BigInt(`0x${fixtures.wlocIntercept.revision}`) + 1n).toString(16).padStart(64, '0')
  Object.assign(fixtures.wlocIntercept, update, { revision })
  fixtures.interceptModules.revision = revision
  fixtures.mitmSettings.revision = revision
  const builtIn = fixtures.interceptModules.modules.find((module) => module.id === 'builtin-wloc')
  if (builtIn) {
    builtIn.enabled = update.enabled
    builtIn.ready = true
  }
  refreshActiveInterceptHosts()
  return { ...fixtures.wlocIntercept, hosts: [...fixtures.wlocIntercept.hosts] }
}

function interceptModulesView(): T.InterceptModulesView {
  return {
    ...fixtures.interceptModules,
    active_hosts: [...fixtures.interceptModules.active_hosts],
    modules: fixtures.interceptModules.modules.map((module) => ({
      ...module,
      hosts: [...module.hosts],
      unsupported: module.unsupported ? [...module.unsupported] : undefined,
    })),
  }
}

function advanceInterceptRevision(): void {
  const revision = (BigInt(`0x${fixtures.interceptModules.revision}`) + 1n).toString(16).padStart(64, '0')
  fixtures.interceptModules.revision = revision
  fixtures.wlocIntercept.revision = revision
  fixtures.mitmSettings.revision = revision
}

function refreshActiveInterceptHosts(): void {
  const masterEnabled = fixtures.mitmSettings.enabled
  fixtures.interceptModules.active_hosts = masterEnabled
    ? Array.from(
        new Set(fixtures.interceptModules.modules.filter((module) => module.enabled).flatMap((module) => module.hosts)),
      ).sort()
    : []
  for (const module of fixtures.interceptModules.modules) {
    if (!masterEnabled) {
      module.ready = false
      module.reason = 'mitm-disabled'
    } else if (module.compatibility !== 'incompatible' && module.compatibility !== 'needs_configuration') {
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
  if (id === 'builtin-wloc') {
    return {
      id, name: module.name, source_digest: module.source_digest,
      source_body: 'Built into the 5gpn-intercept binary; no remote source is executed.', scripts: [],
    }
  }
  return {
    id, name: module.name, source_url: module.source_url,
    source_digest: module.source_digest,
    source_body: '#!name=Synthetic response cleaner\n[Script]\nhttp-response ^https://api\\.example\\.test/ script-path=https://modules.example.test/clean.js,tag=Cleaner\n[MITM]\nhostname=api.example.test\n',
    scripts: [{
      id: 'script-001', url: 'https://modules.example.test/clean.js', digest: 'd'.repeat(64),
      body: '$done({body: $response.body});',
    }],
  }
}

export async function importInterceptModule(request: T.InterceptModuleImport): Promise<T.InterceptModulesView> {
  await delay(180)
  if (request.revision !== fixtures.interceptModules.revision) {
    throw new ApiError(409, 'The interception module registry changed. Refresh and try again.')
  }
  const seed = (request.url || request.content || 'module').length.toString(16).padStart(16, '0').slice(-16)
  const id = `mod-${seed}`
  if (fixtures.interceptModules.modules.some((module) => module.id === id)) {
    throw new ApiError(409, 'This immutable snapshot is already imported.')
  }
  fixtures.interceptModules.modules.push({
    id,
    name: 'Imported module snapshot',
    description: 'Mock import preview',
    enabled: false,
    ready: true,
    compatibility: 'full',
    partial_allowed: false,
    hosts: ['service.example.test'],
    script_count: 1,
    rewrite_count: 0,
    source_url: request.url,
    source_digest: 'c'.repeat(64),
    imported_at: new Date().toISOString(),
    argument: '',
  })
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
    if (id === 'builtin-wloc') fixtures.wlocIntercept.enabled = update.enabled
  }
  if (update.argument !== undefined) module.argument = update.argument
  if (update.partial_allowed !== undefined) module.partial_allowed = update.partial_allowed
  if (update.parameters !== undefined && module.parameters) {
    module.parameters = module.parameters.map((parameter) => ({ ...parameter, value: update.parameters?.[parameter.key] ?? '' }))
    if (module.parameters.every((parameter) => parameter.value)) {
      module.compatibility = (module.issues?.length ?? 0) > 0 ? 'partial' : 'full'
    }
  }
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
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
  advanceInterceptRevision()
  refreshActiveInterceptHosts()
  return interceptModulesView()
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
