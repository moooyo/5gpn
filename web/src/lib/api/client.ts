/*
 * The single `api` object every console view calls.
 *
 * Live methods hit the daemon via apiFetch (http.ts's bearer-token core).
 * The current surface is status/diagnostics, settings, ordered DNS policy,
 * and the complete operator-owned mihomo config.
 *
 * MOCK is read once at module load — flip it in tests with
 * vi.stubEnv('VITE_API_MOCK', …) + vi.resetModules() + a dynamic
 * import('./client').
 */
import { apiFetch } from './http'
import * as mock from './mock'
import type * as T from './types'

export const MOCK = import.meta.env.VITE_API_MOCK === '1'

const qs = (params: Record<string, string | number | undefined>) => {
  const u = new URLSearchParams()
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== '') u.set(k, String(v))
  const s = u.toString()
  return s ? `?${s}` : ''
}

export const api = {
  // ---- live --------------------------------------------------------------
  getStatus: (signal?: AbortSignal) => apiFetch<T.Status>('/api/status', { signal }),
  getQueryLog: (q = '', limit?: number, signal?: AbortSignal) =>
    apiFetch<T.QueryLogResponse>('/api/querylog' + qs({ q, limit }), { signal }),
  resolveTest: (domain: string) => apiFetch<T.ResolveTestResult>('/api/resolve-test' + qs({ domain })),
  getUpstreams: () => apiFetch<T.UpstreamsView>('/api/upstreams'),
  putUpstreams: (v: T.UpstreamsView) => apiFetch<T.UpstreamsView>('/api/upstreams', { method: 'PUT', body: JSON.stringify(v) }),
  getEcs: () => apiFetch<T.ECSView>('/api/ecs'),
  putEcs: (subnet: string) => apiFetch<T.ECSView>('/api/ecs', { method: 'PUT', body: JSON.stringify({ subnet }) }),
  getTgbot: (signal?: AbortSignal) => apiFetch<T.TGBotView>('/api/tgbot', { signal }),
  putTgbot: (u: T.TGBotUpdate) => apiFetch<T.TGBotView>('/api/tgbot', { method: 'PUT', body: JSON.stringify(u) }),
  getMihomoHealth: (signal?: AbortSignal) => apiFetch<T.MihomoHealth>('/api/mihomo/health', { signal }),
  createMihomoLogTicket: () => apiFetch<T.MihomoLogTicket>('/api/mihomo/log-ticket', { method: 'POST' }),
  createZashboardHandoff: () => apiFetch<T.ZashboardHandoff>('/api/mihomo/zashboard-handoff', { method: 'POST' }),
  // ---- mihomo config editor ----------------------------------------------
  // The operator edits the WHOLE mihomo config as raw text. PUT/reset both
  // run the same infra-invariant + `mihomo
  // -t` + hot-apply pipeline server-side (see api_mihomo_config.go); a 400
  // means validation rejected the text and neither the on-disk config nor
  // the running mihomo instance was touched.
  getMihomoConfig: () => (MOCK ? mock.getMihomoConfig() : apiFetch<T.MihomoConfig>('/api/mihomo/config')),
  putMihomoConfig: (text: string, revision: string) =>
    MOCK
      ? mock.putMihomoConfig(text, revision)
      : apiFetch<T.MihomoConfig>('/api/mihomo/config', { method: 'PUT', body: JSON.stringify({ text, revision }) }),
  resetMihomoConfig: (revision: string) =>
    MOCK
      ? mock.resetMihomoConfig(revision)
      : apiFetch<T.MihomoConfig>('/api/mihomo/config/reset', { method: 'POST', body: JSON.stringify({ revision }) }),
  // Built-in optional ingress modules. The service owns the candidate
  // validation and atomic config publication. Raw editor/reset and module
  // writes all carry the same byte revision so neither surface can silently
  // replace a newer edit from the other.
  getIngressModules: () =>
    MOCK ? mock.getIngressModules() : apiFetch<T.IngressModulesView>('/api/mihomo/ingress-modules'),
  putIngressModule: (id: string, enabled: boolean, revision: string) =>
    MOCK
      ? mock.putIngressModule(id, enabled, revision)
      : apiFetch<T.IngressModulesView>(`/api/mihomo/ingress-modules/${encodeURIComponent(id)}`, {
          method: 'PUT',
          body: JSON.stringify({ enabled, revision }),
        }),

  // ---- unified policy rules ----------------------------------------------
  getPolicyRules: () => (MOCK ? mock.getPolicyRules() : apiFetch<T.PolicyRule[]>('/api/policy/rules')),
  createPolicyRule: (r: Omit<T.PolicyRule, 'id' | 'order'>) =>
    MOCK ? mock.createPolicyRule(r) : apiFetch<T.PolicyRule>('/api/policy/rules', { method: 'POST', body: JSON.stringify(r) }),
  updatePolicyRule: (id: string, r: Omit<T.PolicyRule, 'id' | 'order'>) =>
    MOCK ? mock.updatePolicyRule(id, r) : apiFetch<T.PolicyRule>(`/api/policy/rules/${encodeURIComponent(id)}`, { method: 'PATCH', body: JSON.stringify(r) }),
  deletePolicyRule: (id: string) =>
    MOCK ? mock.deletePolicyRule(id) : apiFetch<{ ok: boolean }>(`/api/policy/rules/${encodeURIComponent(id)}`, { method: 'DELETE' }),
  reorderPolicyRules: (ids: string[]) =>
    MOCK ? mock.reorderPolicyRules(ids) : apiFetch<{ ok: boolean }>('/api/policy/rules/reorder', { method: 'PUT', body: JSON.stringify({ ids }) }),
  getPolicyFallback: () => (MOCK ? mock.getPolicyFallback() : apiFetch<T.PolicyFallback>('/api/policy/fallback')),
  putPolicyFallback: (f: T.PolicyFallback) =>
    MOCK ? mock.putPolicyFallback(f) : apiFetch<{ ok: boolean }>('/api/policy/fallback', { method: 'PUT', body: JSON.stringify(f) }),
  applyPolicy: () => (MOCK ? mock.applyPolicy() : apiFetch<{ ok: boolean }>('/api/policy/apply', { method: 'POST' })),
}
