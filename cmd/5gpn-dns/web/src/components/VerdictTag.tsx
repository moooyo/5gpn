import type { ReactNode } from 'react'
import { LANES, type Lane } from '../verdicts'

interface VerdictTagProps {
  lane: Lane | null
  children: ReactNode
  size?: 'sm' | 'lg'
}

/**
 * A lane-colored verdict tag: outlined in the lane color with the lane glyph.
 * `sm` is the inline table/list variant; `lg` is the big Lookup result tag.
 */
export function VerdictTag({ lane, children, size = 'sm' }: VerdictTagProps) {
  const color = lane ? LANES[lane].color : 'var(--muted)'
  const glyph = lane ? LANES[lane].glyph : '·'

  if (size === 'lg') {
    return (
      <span
        className="tag"
        style={{
          color,
          borderColor: color,
          fontSize: 20,
          padding: '10px 18px',
          letterSpacing: '0.04em',
          background: 'color-mix(in srgb, currentColor 10%, transparent)',
        }}
      >
        <span aria-hidden>{glyph}</span>
        {children}
      </span>
    )
  }

  return (
    <span className="tag" style={{ color, borderColor: color }}>
      <span aria-hidden>{glyph}</span>
      {children}
    </span>
  )
}
