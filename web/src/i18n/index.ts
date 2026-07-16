import i18n from 'i18next'
import { initReactI18next } from 'react-i18next'
import LanguageDetector from 'i18next-browser-languagedetector'
import en from './locales/en'
import zh from './locales/zh'

// Single global instance. Imported for side effects in main.tsx before render.
i18n
  .use(LanguageDetector)
  .use(initReactI18next)
  .init({
    resources: { en: { translation: en }, zh: { translation: zh } },
    // zh is the default for fresh visitors (no saved preference): detection
    // only consults localStorage (navigator dropped), so an unset '5gpn_lang'
    // falls through to fallbackLng. Switching to en persists via the
    // 'localStorage' cache below.
    fallbackLng: 'zh',
    supportedLngs: ['en', 'zh'],
    nonExplicitSupportedLngs: true, // zh-CN / zh-TW / zh-Hans -> zh
    load: 'languageOnly',
    interpolation: { escapeValue: false }, // React already escapes
    detection: {
      order: ['localStorage'],
      caches: ['localStorage'],
      lookupLocalStorage: '5gpn_lang',
    },
  })

if (typeof document !== 'undefined') {
  const setLang = (lng: string) => {
    document.documentElement.lang = lng.startsWith('zh') ? 'zh' : 'en'
  }
  setLang(i18n.language || 'en')
  i18n.on('languageChanged', setLang)
}

export default i18n
