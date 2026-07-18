import { useTranslation } from 'react-i18next'
import { ChevronDownIcon, LanguageIcon, LogoutIcon, ShieldFilledIcon } from '../components/icons'
import { DropdownItem, DropdownMenu, DropdownSeparator, SectionLabel, SegmentedControl } from '../components/ds'
import { THEME_CATALOG, useTheme, type ThemeName } from '../lib/theme'
import { clearToken } from '../lib/api/http'

export interface ProfileMenuProps {
  onLogout?: () => void
}

function ConsoleAvatar({ size }: { size: number }) {
  return (
    <div
      className="grid shrink-0 place-items-center rounded-full bg-primary text-[var(--md-sys-color-on-primary)]"
      style={{ width: size, height: size }}
    >
      <ShieldFilledIcon style={{ width: size * .56, height: size * .56 }} aria-hidden="true" />
    </div>
  )
}

export function ProfileMenu({ onLogout }: ProfileMenuProps) {
  const { t, i18n } = useTranslation()
  const { theme, setTheme } = useTheme()
  const language = i18n.language.startsWith('zh') ? 'zh' : 'en'

  const handleLogout = () => {
    clearToken()
    if (onLogout) onLogout()
    else window.location.reload()
  }

  return (
    <DropdownMenu
      className="w-[296px]"
      trigger={
        <button
          type="button"
          aria-label={t('topbar.openProfile')}
          className="zds-state-layer flex h-11 items-center gap-2 rounded-full px-1.5 pr-3 text-text-mid"
        >
          <ConsoleAvatar size={34} />
          <span className="hidden text-[12.5px] font-medium sm:inline">{t('topbar.consoleAccess')}</span>
          <ChevronDownIcon className="h-4 w-4 text-text-faint" aria-hidden="true" />
        </button>
      }
    >
      <div className="flex items-center gap-3 px-2 py-2.5">
        <ConsoleAvatar size={42} />
        <div className="flex min-w-0 flex-col leading-tight">
          <span className="text-[13.5px] font-medium text-text-strong">{t('topbar.consoleAccess')}</span>
          <span className="mt-1 text-[11px] text-text-faint">{t('topbar.authenticated')}</span>
        </div>
      </div>

      <DropdownSeparator />

      <div className="px-1 pb-3">
        <SectionLabel className="mb-2 flex items-center gap-1.5 px-2">
          <LanguageIcon className="h-4 w-4" aria-hidden="true" />
          {t('topbar.language')}
        </SectionLabel>
        <SegmentedControl
          value={language}
          onChange={(value) => void i18n.changeLanguage(value)}
          options={[
            { value: 'zh', label: '中文' },
            { value: 'en', label: 'English' },
          ]}
          ariaLabel={t('topbar.language')}
        />
      </div>

      <div className="px-1 pb-2">
        <SectionLabel className="mb-2 px-2">{t('topbar.theme')}</SectionLabel>
        <SegmentedControl
          value={theme}
          onChange={(value) => setTheme(value as ThemeName)}
          options={THEME_CATALOG.map((item) => ({
            value: item.name,
            label: t(`topbar.themeNames.${item.name}`),
            swatch: item.swatch,
          }))}
          className="grid-cols-2"
          ariaLabel={t('topbar.theme')}
        />
      </div>

      <DropdownSeparator />

      <DropdownItem danger onSelect={handleLogout}>
        <LogoutIcon className="h-5 w-5" aria-hidden="true" />
        {t('topbar.logout')}
      </DropdownItem>
    </DropdownMenu>
  )
}
