// ---- Live endpoints (verbatim to Go json tags) ----------------------------
export interface Stats {
  total: number
  block: number
  force_direct: number
  force_proxy: number
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
// `dot_domain` is the derived DoT identity Android users enter as their
// Private DNS provider hostname. It is omitted when the base domain is unset.
// `zash_domain` mirrors cfg.ZashDomain. The console uses it for the zashboard
// deep link instead of deriving a domain from location.host. It is omitted
// when the operator has not configured a zashboard panel.
export interface Status {
  version: string
  uptime_seconds: number
  stats: Stats
  cert?: CertStatus
  dot_domain?: string
  zash_domain?: string
}

export interface ZashboardHandoff {
  url: string
  expires_in_seconds: number
}

export interface QueryLogEntry {
  time: string // RFC3339
  client?: string
  name: string
  qtype: string
  verdict?: string // ONLY {block,direct,proxy}
  reason?: string  // current resolver reason; drives the log decision label and color
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
export type TGBotState = 'disabled' | 'starting' | 'healthy' | 'degraded'
export interface TGBotView {
  admins: number[]
  token_set: boolean
  state: TGBotState
  last_error?: string
}
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

// Verbatim GET /api/mihomo/config response. The operator edits the complete
// effective mihomo config as raw text, so this is the single
// source of truth for `/etc/5gpn/mihomo/config.yaml`. `applied_at` is the
// RFC3339 timestamp of the last successful PUT/reset in this daemon process
// (absent before either operation succeeds); `controller_reachable`
// reflects TCP/HTTP reachability; `controller_authenticated` separately says
// whether the configured secret was accepted (a 401 is reachable but unusable).
// `revision` is the SHA-256 of the exact config bytes and is required by
// PUT/reset to reject stale editors.
export interface MihomoConfig {
  text: string
  revision: string
  applied_at?: string
  controller_reachable: boolean
  controller_authenticated: boolean
}

// Narrow, built-in mihomo ingress modules. These are explicit operator
// actions over the complete config document; they are not a daemon-owned
// generated configuration region.
export type IngressNetwork = 'tcp' | 'udp'
export type IngressSniffer = 'http' | 'tls' | 'quic'
export interface IngressModule {
  id: string
  port: number
  networks: IngressNetwork[]
  sniffers: IngressSniffer[]
  enabled: boolean
  manageable: boolean
  reason?: string
}
export interface IngressModulesView {
  revision: string
  modules: IngressModule[]
}

export interface MITMSettingsView {
  revision: string
  enabled: boolean
  http2: boolean
  quic_fallback_protection: boolean
}

export interface MITMSettingsUpdate {
  revision: string
  enabled: boolean
  http2: boolean
  quic_fallback_protection: boolean
}

export type InterceptSettingType = 'text' | 'select' | 'boolean' | 'number' | 'location'
export interface InterceptLocationValue {
  longitude?: number
  latitude?: number
  accuracy: number
}
export interface InterceptModuleSetting {
  key: string
  type: InterceptSettingType
  label?: string
  description?: string
  required: boolean
  options?: string[]
  min?: number
  max?: number
  default?: unknown
  value?: unknown
}
export interface InterceptActionMatch {
  hosts: string[]
  schemes: string[]
  methods?: string[]
  path_regex: string
  status_codes?: number[]
}
export interface InterceptModuleAction {
  id: string
  phase: 'request' | 'response'
  match: InterceptActionMatch
  script_url?: string
  script_digest: string
  body_mode: 'none' | 'text' | 'binary'
  timeout_ms: number
  max_body_bytes: number
}
export interface InterceptHostMapping { host: string; target: string }
export interface InterceptRoutingRule {
  action: 'reject' | 'direct'
  domain?: string
  domain_suffix?: string
  domain_keywords?: string[]
  all_domain_keywords?: string[]
  ip_cidr?: string
  network?: 'tcp' | 'udp'
  destination_port?: number
}
export type InterceptCaptureDNS = 'trust' | 'china'
export interface InterceptModule {
  id: string
  extension_version: string
  name: string
  description?: string
  enabled: boolean
  ready: boolean
  reason?: string
  capture_hosts: string[]
  // Operator-owned resolver choice for capture-host origin answers. It is
  // persisted outside the immutable manifest and preserved across updates.
  capture_dns: InterceptCaptureDNS
  script_count: number
  actions?: InterceptModuleAction[]
  settings?: InterceptModuleSetting[]
  upstream_mappings?: InterceptHostMapping[]
  routing_rules?: InterceptRoutingRule[]
  persistent_storage: boolean
  source_url?: string
  source_digest: string
  snapshot_digest: string
  imported_at?: string
  execution_order: number
  network_origins: string[]
  egress_group_required: boolean
  egress_group?: string
}
export interface InterceptModulesView {
  revision: string
  catalog_url: string
  modules: InterceptModule[]
  active_capture_hosts: string[]
  execution_order: string[]
  available_egress_groups: string[]
}
export interface InterceptScriptSnapshot {
  id: string
  url?: string
  digest: string
  body: string
}
export interface InterceptModuleSnapshot {
  id: string
  name: string
  source_url?: string
  source_digest: string
  source_body: string
  scripts: InterceptScriptSnapshot[]
}
export interface InterceptModuleImport {
  revision: string
  url?: string
  content?: string
}
export interface InterceptModuleUpdate {
  revision: string
  enabled?: boolean
  settings?: Record<string, unknown>
  egress_group?: string
  capture_dns?: InterceptCaptureDNS
}
export interface InterceptModuleUpdateCheck {
  revision: string
  state: 'unchanged' | 'available'
  candidate?: InterceptModule
}

export interface MarketplaceEntryCapabilities {
  capture_host_count: number
  action_count: number
  setting_count: number
  network_origins: string[]
  persistent_storage: boolean
  upstream_mapping_count: number
  egress_group_required: boolean
  routing_rule_count: number
}
export interface MarketplaceEntryLicense { spdx: string; url?: string }
export interface MarketplaceEntry {
  id: string
  name: string
  version: string
  description?: string
  tags: string[]
  license?: MarketplaceEntryLicense
  documentation_url?: string
  manifest_url: string
  manifest_digest: string
  capabilities: MarketplaceEntryCapabilities
}
export interface MarketplaceSource {
  id: string
  name: string
  display_name?: string
  metadata_name: string
  description?: string
  homepage?: string
  url: string
  final_url: string
  digest: string
  snapshot_digest: string
  fetched_at: string
  entries: MarketplaceEntry[]
}
export interface MarketplacesView {
  revision: string
  recommended_url?: string
  sources: MarketplaceSource[]
}

export interface CitySearchResult {
  place_id: number
  display_name: string
  lat: string
  lon: string
}

// ---- Unified policy rules -----------------------------------------------
// `proxy` means only "steer to the gateway"; application egress belongs to
// the operator-owned mihomo config, never to a DNS-policy field.
export type MatcherKind = 'domain' | 'domain-suffix' | 'domain-keyword' | 'subscription'
export type Intent = 'block' | 'direct' | 'proxy'
export type FallbackPolicyKind = 'auto' | 'direct' | 'gateway'
export type SubscriptionFormat = 'plain' | 'gfwlist' | 'dnsmasq' | 'hosts'

export type PolicyMatcher =
  | {
      kind: Exclude<MatcherKind, 'subscription'>
      value: string
      format?: never
      interval?: never
    }
  | {
      kind: 'subscription'
      value: string
      format: SubscriptionFormat
      interval: string // positive Go duration, e.g. "6h0m0s"
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
