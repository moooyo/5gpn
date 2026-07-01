/*
 * The verdict-lane signature system — the one bold device in this UI. A
 * verdict/reason from the resolver maps to a consistent lane color, glyph, and
 * plain-English line, reused on the lane bar, the Lookup result tag, and the
 * Rules category headers.
 */

export type Lane = 'direct' | 'proxy' | 'block' | 'adblock'

export interface LaneMeta {
  key: Lane
  label: string
  color: string // the CSS var reference
  glyph: string // a small unicode mark
}

export const LANES: Record<Lane, LaneMeta> = {
  direct: { key: 'direct', label: 'Direct', color: 'var(--v-direct)', glyph: '→' },
  proxy: { key: 'proxy', label: 'Proxy', color: 'var(--v-proxy)', glyph: '⇄' },
  block: { key: 'block', label: 'Block', color: 'var(--v-block)', glyph: '⊘' },
  adblock: { key: 'adblock', label: 'Ad-block', color: 'var(--v-adblock)', glyph: '∅' },
}

// The three lanes that partition `total` in the stacked lane bar. adblock
// (NXDOMAIN) isn't a distinct engine counter, so it isn't part of the total
// partition — it still gets a lane color for tags/headers.
export const BAR_LANES: Lane[] = ['direct', 'proxy', 'block']

/**
 * Map a resolver reason string to its lane. The reason vocabulary comes from
 * Controller.Lookup:
 *   force-direct, chnroute-cn  -> direct (mint)
 *   chnroute-foreign           -> proxy  (amber)
 *   blacklist                  -> block  (rose)
 *   adblock                    -> adblock(violet)
 */
export function laneForReason(reason: string): Lane | null {
  switch (reason) {
    case 'force-direct':
    case 'chnroute-cn':
      return 'direct'
    case 'chnroute-foreign':
      return 'proxy'
    case 'blacklist':
      return 'block'
    case 'adblock':
      return 'adblock'
    default:
      return null
  }
}

/** Map a verdict string (direct|proxy|block|...) to its lane, best-effort. */
export function laneForVerdict(verdict: string): Lane | null {
  switch (verdict) {
    case 'direct':
      return 'direct'
    case 'proxy':
      return 'proxy'
    case 'block':
      return 'block'
    case 'adblock':
      return 'adblock'
    default:
      return null
  }
}

/** Plain-English explanation of a reason, from the operator's side. */
export function reasonExplained(reason: string): string {
  switch (reason) {
    case 'force-direct':
      return 'Forced direct — a manual direct rule keeps this name on the local route.'
    case 'chnroute-cn':
      return 'China — resolves to a China-route IP, so the client goes direct.'
    case 'chnroute-foreign':
      return 'Foreign — routed through the gateway.'
    case 'blacklist':
      return 'Blacklisted — sinkholed to the gateway.'
    case 'adblock':
      return 'Ad-block — answered as NXDOMAIN, so it never resolves.'
    case '':
      return 'No verdict — the name did not resolve to any address.'
    default:
      return reason
  }
}

/** The lane color for a category header on the Rules view. */
export function laneForCategory(cat: string): Lane | null {
  switch (cat) {
    case 'adblock':
      return 'adblock'
    case 'direct':
      return 'direct'
    case 'blacklist':
      return 'block'
    case 'chnroute':
      return 'direct' // chnroute members resolve real and go direct
    default:
      return null
  }
}
