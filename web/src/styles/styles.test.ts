import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const stylePath = (name: string) => resolve(process.cwd(), 'src', 'styles', name)
const indexCss = readFileSync(stylePath('index.css'), 'utf8')
const themeCss = readFileSync(stylePath('theme.css'), 'utf8')
const zdsCss = readFileSync(stylePath('zds.css'), 'utf8')

describe('M3 cascade and theme contract', () => {
  it('orders DaisyUI below zds while leaving direct utilities above both', () => {
    expect(indexCss).toContain('@layer utilities.daisyui, utilities.zds;')
    expect(indexCss.indexOf("@plugin 'daisyui'")).toBeLessThan(indexCss.indexOf("@import './zds.css'"))
    expect(zdsCss.trimStart()).toMatch(/^@layer utilities\.zds/)
  })

  it('defines exactly the required five persisted themes with light as the root scheme', () => {
    for (const name of ['light', 'dark', 'ocean', 'forest', 'violet']) {
      expect(themeCss).toContain(`[data-theme='${name}']`)
    }
    expect(themeCss).toMatch(/:root,\s*\[data-theme='light'\]/)
  })

  it('uses local assets only', () => {
    expect(`${indexCss}\n${themeCss}\n${zdsCss}`).not.toMatch(/fonts\.googleapis|fonts\.gstatic|unpkg\.com|cdn\.jsdelivr/)
  })
})
