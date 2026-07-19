import { describe, expect, it } from 'vitest'
import i18n from './index'
import en from './locales/en'
import zh from './locales/zh'

/** Flattens a translation catalog to dot-path leaf keys. Arrays (e.g.
 *  `resolveTest.steps.block`) are treated as leaves — their key path is
 *  recorded once, the array contents themselves are not walked — since both
 *  catalogs use arrays only for parallel step-list values, not as a place
 *  where a whole sub-key could silently go missing. */
function flattenKeys(obj: unknown, prefix = ''): string[] {
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    return [prefix]
  }
  return Object.entries(obj as Record<string, unknown>).flatMap(([key, value]) =>
    flattenKeys(value, prefix ? `${prefix}.${key}` : key),
  )
}

// A representative sample spanning every namespace actually used by the
// current pages (see i18n/locales/{en,zh}.ts). Not
// exhaustive (a full "every key resolves" check would just re-implement
// i18next), but catches the common failure mode: a key present in one
// catalog resolving to the raw key string in the other (missing translation)
// or to an empty string.
const SAMPLE_KEYS = [
  'common.save',
  'common.cancel',
  'common.errorTitle',
  'common.errorBody',
  'common.reload',
  'nav.overview',
  'nav.setupGuide',
  'nav.logs',
  'nav.resolveTest',
  'nav.policyRules',
  'nav.extensions',
  'nav.settings',
  'nav.primary',
  'nav.group.rules',
  'topbar.logout',
  'topbar.language',
  'topbar.theme',
  'topbar.sub.overview',
  'topbar.sub.setupGuide',
  'topbar.sub.policyRules',
  'topbar.sub.extensions',
  'overview.qps',
  'overview.decisionDistribution',
  'overview.decision.block',
  'setupGuide.ios.download',
  'setupGuide.android.hostnameLabel',
  'logs.searchPlaceholder',
  'logs.colTime',
  'logs.decision.forceProxy',
  'resolveTest.domainLabel',
  'resolveTest.run',
  'resolveTest.label.chnrouteCn',
  'policyRules.newRule',
  'policyRules.apply',
  'policyRules.kind.domain-suffix',
  'policyRules.intent.proxy',
  'policyRules.dialog.addTitle',
  'policyRules.table.colMatcher',
  'policyRules.fallback.title',
  'policyRules.fallback.policy.auto',
  'settings.upstreams',
  'settings.tgbot',
  'settings.dotService',
  'auth.title',
  'auth.submit',
  'errors.network',
  'verdicts.noVerdict',
]

describe('i18n catalogs', () => {
  it('zh and en expose the identical (deep) key set', () => {
    const enKeys = flattenKeys(en).sort()
    const zhKeys = flattenKeys(zh).sort()
    expect(zhKeys).toEqual(enKeys)
  })

  it('a representative sample of nav/common/page keys resolves to a non-empty, translated string in both languages', async () => {
    const originalLanguage = i18n.language
    try {
      for (const lng of ['en', 'zh'] as const) {
        await i18n.changeLanguage(lng)
        for (const key of SAMPLE_KEYS) {
          const value = i18n.t(key)
          expect(value, `${lng}:${key} should not fall back to the raw key`).not.toBe(key)
          expect(value.trim().length, `${lng}:${key} should not be empty`).toBeGreaterThan(0)
        }
      }
    } finally {
      await i18n.changeLanguage(originalLanguage)
    }
  })
})
