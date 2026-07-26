export type UpstreamGroup = 'china' | 'trust'
export type UpstreamProtocol = 'udp' | 'dot' | 'doh'

export type UpstreamFieldError = 'required' | 'invalid'

export interface UpstreamInputErrors {
  protocol?: 'invalid'
  address?: UpstreamFieldError
  serverName?: UpstreamFieldError
  endpoint?: UpstreamFieldError
}

export type UpstreamSpecResult =
  | { ok: true; spec: string }
  | { ok: false; errors: UpstreamInputErrors }

export interface UpstreamSpecInput {
  group: UpstreamGroup
  protocol: UpstreamProtocol
  address: string
  serverName?: string
  /** DoH only: the absolute https:// endpoint, e.g. https://dns.google/dns-query */
  endpoint?: string
}

export interface ParsedUpstreamSpec {
  protocol: UpstreamProtocol
  address: string
  serverName?: string
  endpoint?: string
}

const hostnameRE = /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/

function isIPv4(value: string): boolean {
  const parts = value.split('.')
  if (parts.length !== 4) return false

  return parts.every((part) => {
    if (!/^(0|[1-9][0-9]{0,2})$/.test(part)) return false
    const octet = Number(part)
    return octet >= 0 && octet <= 255
  })
}

function isIPv6(value: string): boolean {
  if (!value.includes(':') || value.includes('%') || value.includes('[') || value.includes(']')) return false

  try {
    const parsed = new URL(`http://[${value}]/`)
    return parsed.hostname.startsWith('[') && parsed.hostname.endsWith(']')
  } catch {
    return false
  }
}

export function isValidIP(value: string): boolean {
  return isIPv4(value) || isIPv6(value)
}

function isValidPort(value: string): boolean {
  if (!/^[0-9]+$/.test(value)) return false
  const port = Number(value)
  return Number.isInteger(port) && port >= 1 && port <= 65_535
}

/**
 * Mirrors the daemon's IP-with-optional-port grammar, which is IPv4-only:
 * validIPPort in cmd/5gpn-dns/upstreams.go requires `ip.To4() != nil` because
 * the 5gpn-dns systemd sandbox excludes AF_INET6, so an IPv6 upstream could
 * never be dialled even if it were stored. Accepting one here would only move
 * the rejection from this form to the API response.
 *
 * isValidIP (IPv4 or IPv6) is deliberately still used by isValidServerName:
 * the daemon accepts `hostnameRE || net.ParseIP` there, and that value is only
 * ever a TLS SNI, never a dial target.
 */
export function isValidIPPort(value: string): boolean {
  if (isIPv4(value)) return true

  const separator = value.lastIndexOf(':')
  if (separator <= 0 || value.indexOf(':') !== separator) return false
  return isIPv4(value.slice(0, separator)) && isValidPort(value.slice(separator + 1))
}

/** Mirrors the daemon's accepted DoT TLS server-name grammar. */
export function isValidServerName(value: string): boolean {
  return hostnameRE.test(value) || isValidIP(value)
}

/**
 * Mirrors the daemon's DoH endpoint grammar (ValidateUpstreams in
 * cmd/5gpn-dns/upstreams.go): an absolute https:// URL with a real host and a
 * non-root path. The path matters — every DoH resolver publishes one
 * (/dns-query by convention) and a bare origin would POST to "/".
 */
export function isValidDoHEndpoint(value: string): boolean {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    return false
  }
  if (url.protocol !== 'https:' || !url.hostname) return false
  if (url.pathname === '' || url.pathname === '/') return false
  return hostnameRE.test(url.hostname) || isValidIP(url.hostname)
}

export function createUpstreamSpec(input: UpstreamSpecInput): UpstreamSpecResult {
  const address = input.address.trim()
  const serverName = input.serverName?.trim() ?? ''
  const errors: UpstreamInputErrors = {}

  if (input.group === 'china' && input.protocol !== 'udp') errors.protocol = 'invalid'
  if (!address) errors.address = 'required'
  else if (!isValidIPPort(address)) errors.address = 'invalid'

  if (input.protocol === 'dot') {
    if (!serverName) errors.serverName = 'required'
    else if (!isValidServerName(serverName)) errors.serverName = 'invalid'
  }

  const endpoint = input.endpoint?.trim() ?? ''
  if (input.protocol === 'doh') {
    if (!endpoint) errors.endpoint = 'required'
    else if (!isValidDoHEndpoint(endpoint)) errors.endpoint = 'invalid'
  }

  if (Object.keys(errors).length > 0) return { ok: false, errors }
  if (input.protocol === 'doh') return { ok: true, spec: `${endpoint}@${address}` }
  if (input.protocol === 'dot') return { ok: true, spec: `${serverName}@${address}` }
  return { ok: true, spec: address }
}

export function parseUpstreamSpec(group: UpstreamGroup, raw: string): ParsedUpstreamSpec {
  const spec = raw.trim()
  const separator = group === 'trust' ? spec.lastIndexOf('@') : -1
  if (separator > 0) {
    const head = spec.slice(0, separator)
    const address = spec.slice(separator + 1)
    // The https:// prefix is what distinguishes a DoH endpoint from a DoT
    // server name; both use the same @-suffix to pin the dial address.
    if (head.startsWith('https://')) return { protocol: 'doh', endpoint: head, address }
    return { protocol: 'dot', serverName: head, address }
  }
  return { protocol: 'udp', address: spec }
}
