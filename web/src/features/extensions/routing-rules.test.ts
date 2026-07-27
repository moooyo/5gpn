import { describe, expect, it } from 'vitest'
import type { InterceptRoutingRule } from '../../lib/api/types'
import { describeRoutingRule } from './routing-rules'

/**
 * These rules used to render as `JSON.stringify(rule)` in a 9.5px monospace
 * block — in the card and in each of the three dialogs. They are also what the
 * single enable confirmation is required to state exactly, so the formatter
 * must not drop a field: every branch below is one the manifest can declare.
 */
describe('describeRoutingRule', () => {
  const rule = (extra: Partial<InterceptRoutingRule>): InterceptRoutingRule => ({ action: 'reject', ...extra })

  it('names an exact domain match', () => {
    expect(describeRoutingRule(rule({ domain: 'geo.example.org', action: 'direct' }))).toEqual({
      kind: 'DOMAIN',
      value: 'geo.example.org',
      action: 'DIRECT',
      constraints: [],
    })
  })

  it('names a suffix match', () => {
    expect(describeRoutingRule(rule({ domain_suffix: 'ads.example.com' }))).toMatchObject({
      kind: 'DOMAIN-SUFFIX',
      value: 'ads.example.com',
      action: 'REJECT',
    })
  })

  // Any-of and all-of are materially different rules and must not read alike.
  it('distinguishes any-keyword from all-keyword matches', () => {
    expect(describeRoutingRule(rule({ domain_keywords: ['ads', 'track'] }))).toMatchObject({
      kind: 'DOMAIN-KEYWORD',
      value: 'ads, track',
    })
    expect(describeRoutingRule(rule({ all_domain_keywords: ['ads', 'track'] }))).toMatchObject({
      kind: 'DOMAIN-KEYWORD-ALL',
      value: 'ads + track',
    })
  })

  it('names an IP CIDR match', () => {
    expect(describeRoutingRule(rule({ ip_cidr: '10.0.0.0/8' }))).toMatchObject({
      kind: 'IP-CIDR',
      value: '10.0.0.0/8',
    })
  })

  it('keeps the narrowing constraints a rule declares', () => {
    expect(describeRoutingRule(rule({ domain_suffix: 'x.example', network: 'udp', destination_port: 443 })).constraints)
      .toEqual(['UDP', ':443'])
  })

  it('maps both actions, and only those two — these rules cannot name a proxy group', () => {
    expect(describeRoutingRule(rule({ domain: 'a.example', action: 'reject' })).action).toBe('REJECT')
    expect(describeRoutingRule(rule({ domain: 'a.example', action: 'direct' })).action).toBe('DIRECT')
  })
})
