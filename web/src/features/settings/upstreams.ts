export type UpstreamGroup = 'china' | 'trust'
export type UpstreamProtocol = 'udp' | 'dot'

export type UpstreamFieldError = 'required' | 'invalid'

export interface UpstreamInputErrors {
  protocol?: 'invalid'
  address?: UpstreamFieldError
  serverName?: UpstreamFieldError
}

export type UpstreamSpecResult =
  | { ok: true; spec: string }
  | { ok: false; errors: UpstreamInputErrors }

export interface UpstreamSpecInput {
  group: UpstreamGroup
  protocol: UpstreamProtocol
  address: string
  serverName?: string
}

export interface ParsedUpstreamSpec {
  protocol: UpstreamProtocol
  address: string
  serverName?: string
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

/** Mirrors the daemon's IP-with-optional-port grammar. */
export function isValidIPPort(value: string): boolean {
  if (isValidIP(value)) return true

  const bracketed = /^\[([^\]]+)]:(.+)$/.exec(value)
  if (bracketed) return isIPv6(bracketed[1]) && isValidPort(bracketed[2])

  const separator = value.lastIndexOf(':')
  if (separator <= 0 || value.indexOf(':') !== separator) return false
  return isIPv4(value.slice(0, separator)) && isValidPort(value.slice(separator + 1))
}

/** Mirrors the daemon's accepted DoT TLS server-name grammar. */
export function isValidServerName(value: string): boolean {
  return hostnameRE.test(value) || isValidIP(value)
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

  if (Object.keys(errors).length > 0) return { ok: false, errors }
  return { ok: true, spec: input.protocol === 'dot' ? `${serverName}@${address}` : address }
}

export function parseUpstreamSpec(group: UpstreamGroup, raw: string): ParsedUpstreamSpec {
  const spec = raw.trim()
  const separator = group === 'trust' ? spec.lastIndexOf('@') : -1
  if (separator > 0) {
    return {
      protocol: 'dot',
      serverName: spec.slice(0, separator),
      address: spec.slice(separator + 1),
    }
  }
  return { protocol: 'udp', address: spec }
}
