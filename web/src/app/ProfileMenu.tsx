import { useTranslation } from 'react-i18next'
import { ChevronDown, LogOut } from 'lucide-react'
import { DropdownItem, DropdownMenu, DropdownSeparator, SectionLabel, SegmentedControl } from '../components/ds'
import { useTheme, type ThemePref } from '../lib/theme'
import { clearToken } from '../lib/api/http'
import { cn } from '../lib/cn'

export interface ProfileMenuProps {
  /** Called after the token is cleared. Defaults to a full-page reload. */
  onLogout?: () => void
}

function Avatar({ size, className }: { size: number; className?: string }) {
  return (
    <div
      className={cn('flex shrink-0 items-center justify-center rounded-full font-bold text-white', className)}
      style={{ width: size, height: size, background: 'linear-gradient(135deg,#3b82f6,#2563eb)', fontSize: size * 0.42 }}
    >
      A
    </div>
  )
}

export function ProfileMenu({ onLogout }: ProfileMenuProps) {
  const { t, i18n } = useTranslation()
  const { theme, setTheme } = useTheme()

  const lang = i18n.language.startsWith('zh') ? 'zh' : 'en'

  const handleLogout = () => {
    clearToken()
    if (onLogout) onLogout()
    else window.location.reload()
  }

  return (
    <DropdownMenu
      trigger={
        <button
          type="button"
          className="flex items-center gap-2 rounded-full border border-border px-2 py-1 text-text-mid"
        >
          <Avatar size={30} />
          <span className="text-[12.5px] font-semibold">{t('topbar.admin')}</span>
          <ChevronDown className="h-3.5 w-3.5 text-text-faint" />
        </button>
      }
    >
      <div className="flex items-center gap-3 px-2 py-2">
        <Avatar size={36} />
        <div className="flex flex-col leading-tight">
          <span className="text-[13px] font-bold text-text-strong">{t('topbar.admin')}</span>
          <span className="text-[11px] text-text-faint">{t('topbar.superAdmin')}</span>
        </div>
      </div>

      <DropdownSeparator />

      <div className="px-1 pb-2">
        <SectionLabel className="mb-1.5 px-1.5">{t('topbar.language')}</SectionLabel>
        <SegmentedControl
          value={lang}
          onChange={(v) => {
            void i18n.changeLanguage(v)
          }}
          options={[
            { value: 'zh', label: '中文' },
            { value: 'en', label: 'English' },
          ]}
        />
      </div>

      <div className="px-1 pb-2">
        <SectionLabel className="mb-1.5 px-1.5">{t('topbar.theme')}</SectionLabel>
        <SegmentedControl
          value={theme}
          onChange={(v) => setTheme(v as ThemePref)}
          options={[
            { value: 'light', label: t('topbar.light') },
            { value: 'dark', label: t('topbar.dark') },
            { value: 'system', label: t('topbar.system') },
          ]}
        />
      </div>

      <DropdownSeparator />

      <DropdownItem danger onSelect={handleLogout}>
        <LogOut className="h-4 w-4" />
        {t('topbar.logout')}
      </DropdownItem>
    </DropdownMenu>
  )
}
