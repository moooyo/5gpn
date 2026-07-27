import { describe, expect, it } from 'vitest'
import { cn } from './cn'

/**
 * tailwind-merge classifies an unknown `text-<word>` as a text COLOUR. With
 * the type scale expressed as named steps, that put `text-body` and
 * `text-[var(--md-sys-color-on-primary)]` in one group and dropped whichever
 * came first — which stripped the colour off every filled button and left it
 * inheriting on-surface on a primary background, at 2.58:1. The merge config
 * has to know the scales; these pin that it does, in both directions.
 */
describe('cn', () => {
  it('keeps a text colour and a named type step together', () => {
    const out = cn('text-[var(--md-sys-color-on-primary)]', 'text-body')
    expect(out).toContain('text-[var(--md-sys-color-on-primary)]')
    expect(out).toContain('text-body')
  })

  it('lets a later type step override an earlier one', () => {
    expect(cn('text-body', 'text-title')).toBe('text-title')
  })

  it('lets a later radius step override an earlier one', () => {
    expect(cn('rounded-card', 'rounded-pill')).toBe('rounded-pill')
  })

  it('lets a later control height override an earlier one', () => {
    expect(cn('h-chip', 'h-field')).toBe('h-field')
  })

  it('still merges the built-in groups it always did', () => {
    expect(cn('px-2', 'px-4')).toBe('px-4')
    expect(cn('text-red-500', 'text-blue-500')).toBe('text-blue-500')
  })
})
