/*
 * The verdict-lane signature system — the one bold device in this UI.
 *
 * Two related concepts live here:
 *
 * 1. REASON LANES (the stacked-bar signature). The resolver counts every query
 *    by *why* it reached its verdict, and those five reason counters partition
 *    `total` exactly. Each reason gets its own lane color, glyph, and line. This
 *    is what the Dashboard hero bar, the TopBar mini bar, and the Stats view
 *    render.
 *
 * 2. COARSE VERDICT LANES (tags). The Lookup result tag and Rules category
 *    header show a coarse verdict color (direct / proxy / block / adblock). A
 *    reason folds into one of those families for the tag.
 */

import type { Stats } from './api'

// ---- Reason lanes — the five-way partition of `total` ----------------------

export type ReasonLane =
  | 'chnroute-cn'
  | 'force-direct'
  | 'chnroute-foreign'
  | 'blacklist'
  | 'adblock'

export interface ReasonLaneMeta {
  key: ReasonLane
  label: string
  color: string // a CSS var reference
  glyph: string // a small unicode mark
  statKey: keyof Stats // the reason counter on Stats
}

/**
 * The five reason lanes, in stack order, each a distinct color from the token
 * palette:
 *   chnroute-cn      → mint  (--v-direct)  resolves real, goes direct
 *   force-direct     → teal  (--accent)    also direct, but operator-forced
 *   chnroute-foreign → amber (--v-proxy)   routed via the gateway
 *   blacklist        → rose  (--v-block)   sinkholed
 *   adblock          → violet(--v-adblock) NXDOMAIN
 */
export const REASON_LANES: Record<ReasonLane, ReasonLaneMeta> = {
  'chnroute-cn': {
    key: 'chnroute-cn',
    label: 'China',
    color: 'var(--v-direct)',
    glyph: '→',
    statKey: 'chnroute_cn',
  },
  'force-direct': {
    key: 'force-direct',
    label: 'Forced direct',
    color: 'var(--accent)',
    glyph: '⇱',
    statKey: 'force_direct',
  },
  'chnroute-foreign': {
    key: 'chnroute-foreign',
    label: 'Foreign',
    color: 'var(--v-proxy)',
    glyph: '⇄',
    statKey: 'chnroute_foreign',
  },
  blacklist: {
    key: 'blacklist',
    label: 'Blacklist',
    color: 'var(--v-block)',
    glyph: '⊘',
    statKey: 'blacklist',
  },
  adblock: {
    key: 'adblock',
    label: 'Ad-block',
    color: 'var(--v-adblock)',
    glyph: '∅',
    statKey: 'adblock',
  },
}

/** Reason lanes in stack/legend order — the five that partition `total`. */
export const REASON_ORDER: ReasonLane[] = [
  'chnroute-cn',
  'force-direct',
  'chnroute-foreign',
  'blacklist',
  'adblock',
]

/** The count for a reason lane from the reason-level Stats. */
export function laneValue(stats: Stats, lane: ReasonLane): number {
  return stats[REASON_LANES[lane].statKey]
}

// ---- Coarse verdict lanes — the tag colors ---------------------------------

export type Lane = 'direct' | 'proxy' | 'block' | 'adblock'

export interface LaneMeta {
  key: Lane
  label: string
  color: string
  glyph: string
}

export const LANES: Record<Lane, LaneMeta> = {
  direct: { key: 'direct', label: 'Direct', color: 'var(--v-direct)', glyph: '→' },
  proxy: { key: 'proxy', label: 'Proxy', color: 'var(--v-proxy)', glyph: '⇄' },
  block: { key: 'block', label: 'Block', color: 'var(--v-block)', glyph: '⊘' },
  adblock: { key: 'adblock', label: 'Ad-block', color: 'var(--v-adblock)', glyph: '∅' },
}

/**
 * Map a resolver reason string to its coarse tag lane. The reason vocabulary
 * comes from Controller.Lookup:
 *   force-direct, chnroute-cn -> direct (mint)
 *   chnroute-foreign          -> proxy  (amber)
 *   blacklist                 -> block  (rose)
 *   adblock                   -> adblock(violet)
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
