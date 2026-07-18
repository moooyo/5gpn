import { Dialog } from '@base-ui/react/dialog'
import { useTranslation } from 'react-i18next'
import { Sidebar } from './Sidebar'

export interface MobileNavigationProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

export default function MobileNavigation({ open, onOpenChange }: MobileNavigationProps) {
  const { t } = useTranslation()
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop className="zds-dialog-backdrop md:hidden" />
        <Dialog.Popup
          id="mobile-navigation"
          aria-describedby={undefined}
          className="zds-navigation-drawer md:hidden"
          data-testid="mobile-sidebar-drawer"
        >
          <Dialog.Title className="sr-only">{t('nav.primary')}</Dialog.Title>
          <Sidebar
            className="h-full w-full"
            onNavigate={() => onOpenChange(false)}
            onClose={() => onOpenChange(false)}
          />
        </Dialog.Popup>
      </Dialog.Portal>
    </Dialog.Root>
  )
}
