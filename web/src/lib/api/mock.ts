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

export async function getMihomoConfig(): Promise<T.MihomoConfig> {
  await delay(100)
  return { ...fixtures.mihomoConfig }
}
export async function putMihomoConfig(text: string): Promise<T.MihomoConfig> {
  await delay(150)
  if (!text.includes('external-controller:')) {
    throw new ApiError(400, missingControllerMsg)
  }
  fixtures.mihomoConfig.text = text
  fixtures.mihomoConfig.applied_at = new Date().toISOString()
  return { ...fixtures.mihomoConfig }
}
export async function resetMihomoConfig(): Promise<T.MihomoConfig> {
  await delay(150)
  fixtures.mihomoConfig.text = fixtures.mihomoConfigDefaultText
  fixtures.mihomoConfig.applied_at = new Date().toISOString()
  return { ...fixtures.mihomoConfig }
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
