import { readFileSync } from 'node:fs'
import { readdirSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

/**
 * The scale guard.
 *
 * Pages used to hand-write fifteen font sizes between 9px and 38px, with 0.5px
 * gaps that no reader can resolve into a hierarchy but that every component
 * had to re-decide, and eight radius literals even though
 * `--radius-card/ctl/chip` were already declared in theme.css and simply
 * bypassed. The tokens exist now (theme.css); this is what keeps a literal
 * from coming back one component at a time.
 *
 * Scoped to `src/**` excluding tests: assertions may legitimately name a
 * literal a component under test renders for a non-scale reason.
 */
const SRC = resolve(process.cwd(), 'src')

function sourceFiles(dir: string): string[] {
  const out: string[] = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name)
    if (entry.isDirectory()) {
      out.push(...sourceFiles(full))
      continue
    }
    if (!/\.tsx?$/.test(entry.name)) continue
    if (/\.test\.tsx?$/.test(entry.name)) continue
    out.push(full)
  }
  return out
}

const FILES = sourceFiles(SRC)

function offenders(pattern: RegExp): string[] {
  const hits: string[] = []
  for (const file of FILES) {
    const text = readFileSync(file, 'utf8')
    for (const [index, line] of text.split('\n').entries()) {
      // A comment explaining what a literal used to be is not a literal.
      const code = line.replace(/\/\/.*$/, '').replace(/\/\*.*?\*\//g, '')
      const match = pattern.exec(code)
      pattern.lastIndex = 0
      if (match) hits.push(`${relative(SRC, file)}:${index + 1} ${match[0]}`)
    }
  }
  return hits
}

describe('type and radius scale', () => {
  it('declares exactly the seven type steps, all at least 11px', () => {
    const css = readFileSync(resolve(SRC, 'styles/theme.css'), 'utf8')
    const steps = [...css.matchAll(/^\s*--text-([a-z]+):\s*(\d+)px;/gm)].map(([, name, px]) => [name, Number(px)] as const)
    expect(steps).toEqual([
      ['meta', 11],
      ['label', 12],
      ['body', 13],
      ['title', 15],
      ['headline', 20],
      ['metric', 28],
      ['hero', 40],
    ])
  })

  it('declares five radius steps', () => {
    const css = readFileSync(resolve(SRC, 'styles/theme.css'), 'utf8')
    // Only the Tailwind theme block: the per-theme blocks below it also carry
    // DaisyUI's own --radius-selector/field/box, which are a different
    // namespace and not utilities pages can reach for.
    const themeBlock = css.slice(0, css.indexOf('@layer theme'))
    const names = [...themeBlock.matchAll(/^\s*--radius-([a-z]+):/gm)].map(([, name]) => name)
    expect(names).toEqual(['card', 'ctl', 'chip', 'dialog', 'pill'])
  })

  it('uses no bare font-size literal outside the scale', () => {
    expect(offenders(/\btext-\[\d+(?:\.\d+)?px\]/)).toEqual([])
  })

  it('uses no bare border-radius literal outside the scale', () => {
    // `rounded-[18px]`-style values were the way the declared tokens got
    // bypassed in the first place.
    expect(offenders(/\brounded-\[\d+px\]/)).toEqual([])
  })
})
