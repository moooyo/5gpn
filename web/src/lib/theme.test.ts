import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { THEME_CATALOG } from './theme'

/**
 * The theme picker paints each swatch as an inline `background`, which cannot
 * reference a variable theme.css scopes to `[data-theme='…']` while another
 * theme is active — so the hex is duplicated here on purpose. What made that
 * dangerous was that nothing compared the two: the catalog could keep painting
 * a colour the stylesheet no longer used, and the picker would quietly show a
 * theme that does not exist.
 */
const CSS = readFileSync(resolve(process.cwd(), 'src/styles/theme.css'), 'utf8')

/** `--md-sys-color-primary` from the block that `[data-theme='name']` selects. */
function primaryOf(name: string): string | undefined {
  const selector = name === 'light' ? "[data-theme='light']" : `[data-theme='${name}']`
  const at = CSS.indexOf(selector)
  if (at === -1) return undefined
  const block = CSS.slice(at, CSS.indexOf('\n  }', at))
  return /--md-sys-color-primary:\s*(#[0-9a-fA-F]{6});/.exec(block)?.[1]
}

describe('theme catalog', () => {
  it('lists a swatch that is the theme\'s own primary, so the picker cannot drift', () => {
    const mismatched = THEME_CATALOG.filter((theme) => {
      const declared = primaryOf(theme.name)
      return declared === undefined || declared.toLowerCase() !== theme.swatch.toLowerCase()
    }).map((theme) => `${theme.name}: catalog ${theme.swatch}, theme.css ${primaryOf(theme.name) ?? 'MISSING'}`)
    expect(mismatched).toEqual([])
  })

  it('covers every theme block the stylesheet declares', () => {
    const declared = [...CSS.matchAll(/\[data-theme='([a-z]+)'\]/g)].map(([, name]) => name)
    expect(new Set(declared)).toEqual(new Set(THEME_CATALOG.map((theme) => theme.name)))
  })
})
