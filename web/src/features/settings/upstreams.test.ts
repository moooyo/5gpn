import { describe, expect, it } from 'vitest'
import { createUpstreamSpec, isValidIPPort, isValidServerName, parseUpstreamSpec } from './upstreams'

describe('upstream validation', () => {
  it.each([
    '223.5.5.5',
    '223.5.5.5:53',
    '::1',
    '2001:db8::53',
    '[2001:db8::53]:853',
  ])('accepts a valid IP endpoint: %s', (value) => {
    expect(isValidIPPort(value)).toBe(true)
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
    expect(createUpstreamSpec({ group: 'china', protocol: 'udp', address: ' 223.5.5.5:53 ' })).toEqual({
      ok: true,
      spec: '223.5.5.5:53',
    })
    expect(
      createUpstreamSpec({
        group: 'trust',
        protocol: 'dot',
        serverName: ' dns.google ',
        address: ' 8.8.8.8 ',
      }),
    ).toEqual({ ok: true, spec: 'dns.google@8.8.8.8' })
  })

  it('reports protocol-specific field errors before an entry can be added', () => {
    expect(createUpstreamSpec({ group: 'trust', protocol: 'dot', serverName: '', address: 'dns.google' })).toEqual({
      ok: false,
      errors: { address: 'invalid', serverName: 'required' },
    })
    expect(createUpstreamSpec({ group: 'china', protocol: 'dot', serverName: 'dns.google', address: '8.8.8.8' })).toEqual({
      ok: false,
      errors: { protocol: 'invalid' },
    })
  })

  it('parses existing entries into protocol metadata for the list', () => {
    expect(parseUpstreamSpec('china', '223.5.5.5')).toEqual({ protocol: 'udp', address: '223.5.5.5' })
    expect(parseUpstreamSpec('trust', 'dns.google@8.8.8.8:853')).toEqual({
      protocol: 'dot',
      serverName: 'dns.google',
      address: '8.8.8.8:853',
    })
  })
})
