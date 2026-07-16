import { describe, expect, it } from 'vitest'
import { arbitrationSegments, cacheHitRate, decisionCounts, upstreamHealth } from './metrics'

describe('decisionCounts', () => {
  it('maps the current force_proxy stats field', () => {
    expect(decisionCounts({
      block: 1,
      force_direct: 2,
      force_proxy: 3,
      chnroute_cn: 4,
      chnroute_foreign: 5,
    })).toEqual({ block: 1, forceDirect: 2, forceProxy: 3, chnrouteCn: 4, chnrouteForeign: 5 })
  })
})

describe('cacheHitRate', () => {
  it('computes hits / (hits + misses) * 100', () => {
    expect(cacheHitRate({ cache_hits: 3, cache_misses: 1 })).toBe(75)
  })

  it('returns 0, not NaN, when hits + misses === 0', () => {
    expect(cacheHitRate({ cache_hits: 0, cache_misses: 0 })).toBe(0)
  })

  it('returns 0 when stats is absent (pre-first-poll)', () => {
    expect(cacheHitRate(undefined)).toBe(0)
  })

  it('is 100 when there are only hits and 0 when there are only misses', () => {
    expect(cacheHitRate({ cache_hits: 5, cache_misses: 0 })).toBe(100)
    expect(cacheHitRate({ cache_hits: 0, cache_misses: 5 })).toBe(0)
  })
})

describe('upstreamHealth', () => {
  it('lifts china/trust ok/err counts and avg latencies off stats', () => {
    const health = upstreamHealth({
      china_ok: 10,
      china_err: 2,
      china_avg_ms: 5,
      trust_ok: 8,
      trust_err: 1,
      trust_avg_ms: 40,
    })
    expect(health).toEqual({
      china: { ok: 10, err: 2, avgMs: 5 },
      trust: { ok: 8, err: 1, avgMs: 40 },
    })
  })

  it('zeroes everything when stats is absent (pre-first-poll)', () => {
    expect(upstreamHealth(undefined)).toEqual({
      china: { ok: 0, err: 0, avgMs: 0 },
      trust: { ok: 0, err: 0, avgMs: 0 },
    })
  })
})

describe('arbitrationSegments', () => {
  it('lifts the chnroute cn/foreign counters off stats', () => {
    expect(arbitrationSegments({ chnroute_cn: 500, chnroute_foreign: 300 })).toEqual({ cn: 500, foreign: 300 })
  })

  it('zeroes both counts when stats is absent (pre-first-poll)', () => {
    expect(arbitrationSegments(undefined)).toEqual({ cn: 0, foreign: 0 })
  })
})
