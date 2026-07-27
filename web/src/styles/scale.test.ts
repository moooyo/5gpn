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
const DS_FILES = FILES.filter((file) => relative(SRC, file).replace(/\\/g, '/').startsWith('components/ds/'))

function offenders(pattern: RegExp, files: string[] = FILES): string[] {
  const hits: string[] = []
  for (const file of files) {
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

  it('declares five control-height steps', () => {
    const css = readFileSync(resolve(SRC, 'styles/theme.css'), 'utf8')
    const themeBlock = css.slice(0, css.indexOf('@layer theme'))
    const steps = [...themeBlock.matchAll(/^\s*--spacing-([a-z]+):\s*([\d.]+)rem;/gm)]
      .map(([, name, rem]) => [name, Number(rem) * 16] as const)
    expect(steps).toEqual([
      ['chip', 32],
      ['row', 36],
      ['ctl', 40],
      ['field', 44],
      ['action', 48],
    ])
  })

  /**
   * The type and radius steps were declared AND adopted; the control heights
   * were declared and then bypassed by the design system itself — `Field` was
   * `h-11`, `Toggle` and `Pagination` were `h-8`. That is the same defect the
   * tokens exist to prevent, one layer lower, and it made two documents wrong:
   * both AGENTS.md and architecture.md said components reference the token.
   *
   * Scoped to `components/ds`, which is where the claim applies and where a
   * bypass propagates to every page at once. A feature-level `h-12 w-12` is
   * usually a decorative circle around an icon rather than a control, and no
   * regex can tell those apart — the primitives are what must hold the line.
   */
  it('lets no design-system control carry a bare height in the control range', () => {
    // 28px–56px is where a control lives. Icon sizes (h-4/h-5) sit below it and
    // container boxes (h-40) above, and neither is on this scale.
    expect(offenders(/\b(?:min-)?h-(?:7|8|9|10|11|12|13|14)\b/, DS_FILES)).toEqual([])
  })

  /**
   * Every page branches its mobile layout on `(max-width: 767px)`, but Tailwind's
   * `sm` starts at 640px. A height that steps down at `sm:` therefore shrinks to
   * its desktop size in the 640–767px band while the page is still rendering its
   * mobile layout — a 32px chip sitting beside a 44px input in the same row.
   * Height steps use `md:` so the two agree.
   */
  it('steps control heights down at md, the breakpoint the pages branch on', () => {
    expect(offenders(/\bsm:(?:min-)?h-(?:chip|row|ctl|field|action)\b/)).toEqual([])
  })

  /**
   * Spacing is Tailwind's default 4px grid. About two dozen call sites had left
   * it for arbitrary pixel values — 18px was the most common, and `px-[18px]`
   * sat directly beside a grid-correct `px-3.5` in the same class list, so the
   * two were being chosen at random rather than for a reason.
   */
  it('keeps padding, margin and gap on the 4px grid', () => {
    expect(offenders(/\b(?:p|px|py|pt|pb|pl|pr|m|mx|my|mt|mb|ml|mr|gap|gap-x|gap-y)-\[\d+px\]/)).toEqual([])
  })
})
