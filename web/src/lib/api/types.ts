// ---- Live endpoints (verbatim to Go json tags) ----------------------------
export interface Stats {
  total: number
  block: number
  force_direct: number
  blacklist: number
  chnroute_cn: number
  chnroute_foreign: number
  cache_entries: number
  china_ok: number
  china_err: number
  trust_ok: number
  trust_err: number
  cache_hits: number
  cache_misses: number
  china_avg_ms: number
  trust_avg_ms: number
}
export interface CertStatus {
  not_after: string // RFC3339; Go zero-time when never loaded — don't render as a date then
  days_remaining: number
  expired: boolean
  broken?: boolean
  error?: string
}
// `zash_domain` mirrors cfg.ZashDomain (DNS_ZASH_DOMAIN, added in A5) — the
// console's mihomo page (C3) deep-links into the zashboard panel using it,
// rather than deriving a domain by label-swapping location.host. Omitted
// (not empty-string) when the operator hasn't configured a zashboard panel.
// `mihomo_secret` (UP-4 Task 9/7) is the controller secret, exposed ONLY on
// the token-gated /api/status response — it feeds the zashboard deep-link's
// `secret=` param so an authenticated console admin auto-auths into zash
// (see the policy/mihomo-decoupling design §5.3). Omitted if unset.
export interface Status {
  version: string
  uptime_seconds: number
  stats: Stats
  cert?: CertStatus
  zash_domain?: string
  mihomo_secret?: string
}

export interface QueryLogEntry {
  time: string // RFC3339
  client?: string
  name: string
  qtype: string
  verdict?: string // ONLY {block,direct,proxy}
  reason?: string  // block | force-direct | blacklist | chnroute-cn | chnroute-foreign — drives the log decision label+color
  upstream?: string
  cache_hit: boolean
  rcode: string
  ips?: string[]
  duration_ms: number
}
export interface QueryLogResponse { retention_seconds: number; entries: QueryLogEntry[] | null }

export interface ResolveProbe {
  server: string
  group: 'china' | 'trust'
  proto: string // 'udp' | 'dot'
  ips?: string[]
  rcode?: string
  duration_ms: number
  err?: string
  selected: boolean
}
export interface ResolveTestResult {
  name: string
  verdict: string
  reason: string
  probes: ResolveProbe[]
  chosen?: string
  chosen_ips?: string[]
  client_ips?: string[]
}

export interface UpstreamsView { china: string[]; trust: string[] }
export interface ECSView { subnet: string }
export interface TGBotView { admins: number[]; token_set: boolean; running: boolean }
export interface TGBotUpdate { token?: string | null; admins: number[] }

// Bearer-protected daemon projection of mihomo `/version`.
export interface MihomoHealth { version: string; meta?: boolean }

// Short-lived, single-use credential minted by the bearer-protected control
// API before the browser upgrades the read-only mihomo log WebSocket.
export interface MihomoLogTicket { ticket: string }

// One frame of mihomo's ticket-gated `/proxy/logs` WebSocket — mihomo emits
// exactly one JSON object per text frame,
// e.g. `{"type":"info","payload":"..."}`. `type` is a free-form level string
// (info/warning/error/debug/silent) mihomo itself defines, not an enum we
// validate against.
export interface MihomoLogLine { type: string; payload: string }

// mihomo config editor (UP-4 §4; verbatim to cmd/5gpn-dns/api_mihomo_config.go's
// GET /api/mihomo/config response). The operator edits the WHOLE effective
// mihomo config as raw text — there is no daemon-owned region to protect
// (the old structured-egress projection is gone), so this is the single
// source of truth for `/etc/5gpn/mihomo/config.yaml`. `applied_at` is the
// RFC3339 timestamp of the last successful PUT/reset (absent if the on-disk
// config predates this endpoint's bookkeeping); `controller_reachable`
// reflects TCP/HTTP reachability; `controller_authenticated` separately says
// whether the configured secret was accepted (a 401 is reachable but unusable).
export interface MihomoConfig {
  text: string
  applied_at?: string
  controller_reachable: boolean
  controller_authenticated: boolean
}

// ---- Unified policy rules (UP-1; verbatim to cmd/5gpn-dns/policy_rules.go
// json tags). UP-4 made the policy strictly BINARY: a rule carries no selector and the
// fallback carries no default selector — `proxy` means only "steer to the
// gateway"; everything about what happens to that traffic afterwards is the
// operator's mihomo config (see `MihomoConfig` above), never a console field. --
export type MatcherKind = 'domain' | 'domain-suffix' | 'domain-keyword' | 'subscription'
export type Intent = 'block' | 'direct' | 'proxy'
export type FallbackPolicyKind = 'auto' | 'direct' | 'gateway'
export type SubscriptionFormat = 'plain' | 'gfwlist' | 'dnsmasq' | 'hosts'

export interface PolicyMatcher {
  kind: MatcherKind
  value: string // the literal (domain/suffix/keyword) OR the subscription URL
  // format + interval are meaningful only when kind === 'subscription':
  format?: SubscriptionFormat
  interval?: string // Go duration STRING, e.g. "6h0m0s" — NOT a number of ms
}
export interface PolicyRule {
  id: string
  order: number
  matcher: PolicyMatcher
  intent: Intent
  enabled: boolean
}
export interface PolicyFallback {
  policy: FallbackPolicyKind
}
