import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import en from './locales/en'
import zh from './locales/zh'

/**
 * Every literal `t('…')` key in the source must exist in both catalogs.
 *
 * The sampled check below this one could not catch a missing key that no
 * sample happened to name: `policyRules.title` was called by the policy page's
 * header and had no entry at all, so i18next fell back to echoing the key and
 * the deployed console rendered the literal string "policyRules.title" as its
 * page heading. It was found by looking at a screenshot of the real gateway,
 * which is not a repeatable way to find missing translations.
 *
 * Only literal single-quoted keys are checked. Template keys built at runtime
 * (`t(\`pluginLogs.level.${level}\`)`) are listed as prefixes below with the
 * enum that completes them, so those are verified too rather than skipped.
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

function lookup(catalog: unknown, key: string): unknown {
  return key.split('.').reduce<unknown>(
    (node, part) => (node && typeof node === 'object' ? (node as Record<string, unknown>)[part] : undefined),
    catalog,
  )
}

/** i18next resolves `x` through `x_one`/`x_other` when the call passes a
 *  `count`, so a plural key is present even though the bare name is not. */
const PLURAL_SUFFIXES = ['_one', '_other', '_zero', '_two', '_few', '_many']

function resolves(catalog: unknown, key: string): boolean {
  const direct = lookup(catalog, key)
  if (direct !== undefined && !(typeof direct === 'object' && !Array.isArray(direct))) return true
  return PLURAL_SUFFIXES.some((suffix) => lookup(catalog, `${key}${suffix}`) !== undefined)
}

/** Keys assembled at runtime, with the values that complete them. */
const DYNAMIC: Array<[string, string[]]> = [
  ['pluginLogs.level.', ['info', 'warn', 'error']],
  ['extensions.captureDNS.', ['trust', 'china', 'trustHint', 'chinaHint', 'title', 'badge']],
  ['policyRules.kind.', ['domain', 'domain-suffix', 'domain-keyword', 'subscription']],
  ['policyRules.intent.', ['block', 'direct', 'proxy']],
  ['decision.', ['block', 'forceDirect', 'forceProxy', 'chnrouteCn', 'chnrouteForeign', 'direct', 'proxy']],
  ['resolveTest.steps.', ['block', 'forceDirect', 'forceProxy', 'chnrouteCn', 'chnrouteForeign', 'interceptForceProxy', 'generic']],
  ['settings.ingressReason.', []],
  ['settings.ingressModules.', []],
  ['topbar.sub.', []],
  ['topbar.themeNames.', []],
  ['mihomoConfig.invariants.', []],
  // Flat keys joined by an underscore, not a namespace — the whole set is
  // enumerated because there is no parent object to check for.
  ['settings.tgbotState_', ['disabled', 'starting', 'healthy', 'degraded']],
]

const LITERAL_KEY = /\bt\(\s*'([a-zA-Z][\w.]*?)'/g

function usedKeys(): Map<string, string> {
  const keys = new Map<string, string>()
  for (const file of sourceFiles(SRC)) {
    const text = readFileSync(file, 'utf8')
    for (const match of text.matchAll(LITERAL_KEY)) {
      if (!keys.has(match[1])) keys.set(match[1], relative(SRC, file))
    }
  }
  return keys
}

describe('every translation key a page asks for exists', () => {
  const keys = usedKeys()

  it('finds a meaningful number of literal keys, so a broken matcher cannot pass silently', () => {
    expect(keys.size).toBeGreaterThan(200)
  })

  it.each(['en', 'zh'] as const)('%s resolves every literal key used in src', (language) => {
    const catalog = language === 'en' ? en : zh
    const missing: string[] = []
    for (const [key, file] of keys) {
      // A namespace object is not a usable translation either.
      if (!resolves(catalog, key)) missing.push(`${key} (${file})`)
    }
    expect(missing).toEqual([])
  })

  it.each(['en', 'zh'] as const)('%s resolves every runtime-composed key', (language) => {
    const catalog = language === 'en' ? en : zh
    const missing: string[] = []
    for (const [prefix, suffixes] of DYNAMIC) {
      if (suffixes.length === 0) {
        // Namespace-shaped: the parent object has to exist and be non-empty.
        const base = lookup(catalog, prefix.replace(/\.$/, ''))
        if (!base || typeof base !== 'object' || Object.keys(base).length === 0) {
          missing.push(`${prefix}* (namespace missing or empty)`)
        }
        continue
      }
      for (const suffix of suffixes) {
        if (lookup(catalog, `${prefix}${suffix}`) === undefined) missing.push(`${prefix}${suffix}`)
      }
    }
    expect(missing).toEqual([])
  })
})
