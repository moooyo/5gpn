/*
 * Pure helpers backing the dashboard.
 *
 * `/api/status` (polled by the shared StatusContext) carries a
 * monotonically increasing `total` query counter, never a rate — QPS is
 * derived client-side here as Δtotal / Δt across StatusContext polls, with a
 * capped rolling series feeding the sparkline. Kept dependency-free (no React
 * imports) so it is trivially unit-testable without rendering anything.
 *
 * The dashboard charts are live snapshots recomputed from `status.stats` on
 * every render:
 * `cacheHitRate` (缓存命中率 gauge), `upstreamHealth` (上游健康与延迟 bar
 * chart, china vs trust), `arbitrationSegments` (境内/境外分流比 donut — the
 * chnroute-only half of `decisionCounts`, split out for its own focused card).
 */

export interface QpsPoint {
  total: number
  /** ms epoch, e.g. Date.now(). */
  at: number
}

/** One-shot average QPS estimate from a single stats sample (total queries
 *  since service start / uptime) — used until a second sample lets us derive
 *  a real Δtotal/Δt rate, so the QPS card never reads a bare 0 on first paint. */
export function estimateQps(total: number, uptimeSeconds: number): number {
  if (!Number.isFinite(uptimeSeconds) || uptimeSeconds <= 0) return 0
  return total / uptimeSeconds
}

/** Δtotal / Δt between two samples, clamped to >= 0 (a counter reset or a
 *  clock/ordering edge case must never render a negative rate). Returns null
 *  when the samples are not far enough apart in time to derive a rate. */
export function deriveQps(prev: QpsPoint, next: QpsPoint): number | null {
  const dtSeconds = (next.at - prev.at) / 1000
  if (dtSeconds <= 0) return null
  return Math.max(0, (next.total - prev.total) / dtSeconds)
}

/** Appends `value` to `series`, keeping at most `cap` entries (oldest first). */
export function pushCapped(series: number[], value: number, cap = 48): number[] {
  const next = series.length >= cap ? series.slice(series.length - cap + 1) : series.slice()
  next.push(value)
  return next
}

/** Percentage change between the last two points of a series — backs each
 *  metric card's delta badge. Null when there aren't two points yet, or the
 *  baseline is zero (would be divide-by-zero / infinite%). */
export function pctDelta(series: number[]): number | null {
  if (series.length < 2) return null
  const prev = series[series.length - 2]
  const cur = series[series.length - 1]
  if (prev === 0) return null
  return ((cur - prev) / prev) * 100
}

// ---- 决策分布 (decision donut) ---------------------------------------------

export interface DecisionCounts {
  block: number
  forceDirect: number
  forceProxy: number
  chnrouteCn: number
  chnrouteForeign: number
}

interface StatsLike {
  block: number
  force_direct: number
  force_proxy: number
  chnroute_cn: number
  chnroute_foreign: number
}

/** Lifts the five decision counters from `/api/status`. Tolerates an absent
 *  pre-first-poll `stats` value by zeroing. */
export function decisionCounts(stats?: StatsLike): DecisionCounts {
  return {
    block: stats?.block ?? 0,
    forceDirect: stats?.force_direct ?? 0,
    forceProxy: stats?.force_proxy ?? 0,
    chnrouteCn: stats?.chnroute_cn ?? 0,
    chnrouteForeign: stats?.chnroute_foreign ?? 0,
  }
}

// ---- 缓存命中率 (cache hit rate gauge) --------------------------------------

interface CacheHitStatsLike {
  cache_hits: number
  cache_misses: number
}

/** `cache_hits / (cache_hits + cache_misses) * 100`, as a 0–100 percentage
 *  for the cache-hit-rate gauge. Zero hits+misses (a fresh/idle daemon) is
 *  defined as 0%, never NaN. Tolerates an absent `stats`. */
export function cacheHitRate(stats?: CacheHitStatsLike): number {
  const hits = stats?.cache_hits ?? 0
  const misses = stats?.cache_misses ?? 0
  const total = hits + misses
  if (total <= 0) return 0
  return (hits / total) * 100
}

// ---- 上游健康与延迟 (upstream health & latency) -----------------------------

export interface UpstreamGroupHealth {
  ok: number
  err: number
  avgMs: number
}

export interface UpstreamHealth {
  china: UpstreamGroupHealth
  trust: UpstreamGroupHealth
}

interface UpstreamHealthStatsLike {
  china_ok: number
  china_err: number
  china_avg_ms: number
  trust_ok: number
  trust_err: number
  trust_avg_ms: number
}

/** Lifts the china/trust success+error counters and average latencies off
 *  `/api/status` for the upstream-health bar chart. Tolerates an absent
 *  `stats` (pre-first-poll) by zeroing. */
export function upstreamHealth(stats?: UpstreamHealthStatsLike): UpstreamHealth {
  return {
    china: { ok: stats?.china_ok ?? 0, err: stats?.china_err ?? 0, avgMs: stats?.china_avg_ms ?? 0 },
    trust: { ok: stats?.trust_ok ?? 0, err: stats?.trust_err ?? 0, avgMs: stats?.trust_avg_ms ?? 0 },
  }
}

// ---- 境内/境外分流比 (CN vs foreign arbitration split donut) ----------------

export interface ArbitrationCounts {
  cn: number
  foreign: number
}

interface ArbitrationStatsLike {
  chnroute_cn: number
  chnroute_foreign: number
}

/** Lifts the two chnroute-arbitration outcome counters (直连 vs 代理) off
 *  `/api/status` for the dedicated CN/foreign split donut — narrower than
 *  `decisionCounts` (which also includes block/force-direct/force-proxy).
 *  Tolerates an absent `stats`. */
export function arbitrationSegments(stats?: ArbitrationStatsLike): ArbitrationCounts {
  return {
    cn: stats?.chnroute_cn ?? 0,
    foreign: stats?.chnroute_foreign ?? 0,
  }
}
