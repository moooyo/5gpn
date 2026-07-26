import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The categorical chart slots used to be aliases of semantic UI roles
 * (--color-green -> success, --color-cyan -> trace, --color-indigo ->
 * tertiary, --color-primary -> primary). Several themes give those roles
 * byte-identical values — forest sets primary and success both to #146c2e and
 * tertiary and trace both to #38656a, ocean sets primary and trace both to
 * #006a6a — so distinct decision-donut segments and distinct query-log
 * decisions rendered in exactly the same colour, with no way for a reader to
 * tell them apart.
 *
 * These tests pin the property that actually matters and is invisible in a
 * component test: within every theme, the five slots are five different
 * colours. A future theme added without its own ramp fails here rather than
 * silently collapsing two series.
 */
const CSS = readFileSync(resolve(process.cwd(), 'src/styles/theme.css'), 'utf8')

const SLOTS = [1, 2, 3, 4, 5] as const

function themeBlocks(): Array<{ name: string; body: string }> {
  // Each theme is a `[data-theme='name'] { … }` block inside @layer theme.
  const blocks: Array<{ name: string; body: string }> = []
  const re = /\[data-theme='([a-z]+)'\]\s*\{([\s\S]*?)\n {2}\}/g
  let match: RegExpExecArray | null
  while ((match = re.exec(CSS)) !== null) blocks.push({ name: match[1], body: match[2] })
  return blocks
}

function slotValues(body: string): Record<number, string | undefined> {
  const out: Record<number, string | undefined> = {}
  for (const slot of SLOTS) {
    out[slot] = new RegExp(`--chart-cat-${slot}:\\s*(#[0-9a-fA-F]{6})\\s*;`).exec(body)?.[1]?.toLowerCase()
  }
  return out
}

describe('theme.css categorical chart slots', () => {
  const blocks = themeBlocks()

  it('finds every declared theme', () => {
    expect(blocks.map((b) => b.name).sort()).toEqual(['dark', 'forest', 'light', 'ocean', 'violet'])
  })

  it.each(blocks.map((b) => [b.name, b.body] as const))('%s defines all five slots', (_name, body) => {
    const values = slotValues(body)
    for (const slot of SLOTS) expect(values[slot]).toMatch(/^#[0-9a-f]{6}$/)
  })

  it.each(blocks.map((b) => [b.name, b.body] as const))('%s keeps all five slots distinct', (_name, body) => {
    const values = SLOTS.map((slot) => slotValues(body)[slot])
    expect(new Set(values).size).toBe(SLOTS.length)
  })

  it('does not resurrect a semantic UI role as a chart slot', () => {
    // The aliasing bug came back through `var(--md-sys-color-*)` indirection,
    // so a slot must be a literal hex chosen for the chart surface.
    expect(CSS).not.toMatch(/--chart-cat-\d:\s*var\(/)
  })

  it('gives the dark theme its own steps rather than reusing the light ones', () => {
    const light = slotValues(blocks.find((b) => b.name === 'light')!.body)
    const dark = slotValues(blocks.find((b) => b.name === 'dark')!.body)
    for (const slot of SLOTS) expect(dark[slot]).not.toBe(light[slot])
  })
})
