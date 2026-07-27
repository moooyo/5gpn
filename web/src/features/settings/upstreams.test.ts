import { describe, expect, it } from 'vitest'
import { createUpstreamSpec, isValidIPPort, isValidServerName, parseUpstreamSpec } from './upstreams'

describe('upstream validation', () => {
  it.each([
    '223.5.5.5',
    '223.5.5.5:53',
  ])('accepts a valid IP endpoint: %s', (value) => {
    expect(isValidIPPort(value)).toBe(true)
  })

  // The daemon is IPv4-only (validIPPort in cmd/5gpn-dns/upstreams.go requires
  // ip.To4() != nil, because the systemd sandbox excludes AF_INET6). Accepting
  // these in the form would only defer the rejection to the API.
  it.each([
    '::1',
    '2001:db8::53',
    '[2001:db8::53]:853',
  ])('rejects an IPv6 upstream the daemon could never dial: %s', (value) => {
    expect(isValidIPPort(value)).toBe(false)
  })

  it.each([
    '',
    'dns.google',
    '223.5.5.5:0',
    '223.5.5.5:65536',
    '223.5.5.5:not-a-port',
    '999.5.5.5',
    '[2001:db8::53]',
    '[not-ipv6]:853',
  ])('rejects an invalid IP endpoint: %s', (value) => {
    expect(isValidIPPort(value)).toBe(false)
  })

  it('validates DoT server names without accepting an endpoint port', () => {
    expect(isValidServerName('dns.google')).toBe(true)
    expect(isValidServerName('8.8.8.8')).toBe(true)
    expect(isValidServerName('bad_name.example')).toBe(false)
    expect(isValidServerName('dns.google:853')).toBe(false)
  })

  it('builds the daemon wire format for UDP and DoT entries', () => {
    expect(createUpstreamSpec({ protocol: 'udp', address: ' 223.5.5.5:53 ' })).toEqual({
      ok: true,
      spec: '223.5.5.5:53',
    })
    expect(
      createUpstreamSpec({
        protocol: 'dot',
        serverName: ' dns.google ',
        address: ' 8.8.8.8 ',
      }),
    ).toEqual({ ok: true, spec: 'dns.google@8.8.8.8' })
  })

  it('reports protocol-specific field errors before an entry can be added', () => {
    expect(createUpstreamSpec({ protocol: 'dot', serverName: '', address: 'dns.google' })).toEqual({
      ok: false,
      errors: { address: 'invalid', serverName: 'required' },
    })
  })

  it('parses existing entries into protocol metadata for the list', () => {
    expect(parseUpstreamSpec('223.5.5.5')).toEqual({ protocol: 'udp', address: '223.5.5.5' })
    expect(parseUpstreamSpec('dns.google@8.8.8.8:853')).toEqual({
      protocol: 'dot',
      serverName: 'dns.google',
      address: '8.8.8.8:853',
    })
  })
})

// DoH shares the @-suffix pinning with DoT: the https:// prefix is what
// distinguishes an endpoint URL from a TLS server name.
describe('DoH upstream specs', () => {
  it('builds an endpoint@address spec', () => {
    const result = createUpstreamSpec({
      protocol: 'doh',
      endpoint: 'https://dns.google/dns-query',
      address: '8.8.8.8',
    })
    expect(result).toEqual({ ok: true, spec: 'https://dns.google/dns-query@8.8.8.8' })
  })

  it('round-trips through parseUpstreamSpec without being mistaken for DoT', () => {
    expect(parseUpstreamSpec('https://dns.google/dns-query@8.8.8.8')).toEqual({
      protocol: 'doh',
      endpoint: 'https://dns.google/dns-query',
      address: '8.8.8.8',
    })
    // A DoT entry must still parse as DoT.
    expect(parseUpstreamSpec('dns.google@8.8.8.8')).toEqual({
      protocol: 'dot',
      serverName: 'dns.google',
      address: '8.8.8.8',
    })
  })

  it.each([
    ['', 'required'],
    ['http://dns.google/dns-query', 'invalid'],
    ['dns.google/dns-query', 'invalid'],
    ['https://dns.google', 'invalid'],
    ['https://dns.google/', 'invalid'],
  ])('rejects endpoint %s', (endpoint, kind) => {
    const result = createUpstreamSpec({ protocol: 'doh', endpoint, address: '8.8.8.8' })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.errors.endpoint).toBe(kind)
  })

  it('still requires a pinned IPv4 dial address', () => {
    const result = createUpstreamSpec({
      protocol: 'doh',
      endpoint: 'https://dns.google/dns-query',
      address: 'dns.google',
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.errors.address).toBe('invalid')
  })

  // Transport is a per-member property, so the same builder serves both
  // groups. A domestic resolver offering DoH is as valid a china member as a
  // plain-UDP one — this is the assertion that used to say the opposite.
  it('builds the same spec regardless of which group it is destined for', () => {
    const result = createUpstreamSpec({
      protocol: 'doh',
      endpoint: 'https://dns.alidns.com/dns-query',
      address: '223.5.5.5',
    })
    expect(result).toEqual({ ok: true, spec: 'https://dns.alidns.com/dns-query@223.5.5.5' })
    expect(parseUpstreamSpec('https://dns.alidns.com/dns-query@223.5.5.5')).toEqual({
      protocol: 'doh',
      endpoint: 'https://dns.alidns.com/dns-query',
      address: '223.5.5.5',
    })
  })
})
