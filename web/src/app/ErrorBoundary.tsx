import { Component, type ErrorInfo, type ReactNode } from 'react'
import { withTranslation, type WithTranslation } from 'react-i18next'
import { Button, Card } from '../components/ds'

interface ErrorBoundaryProps extends WithTranslation {
  children: ReactNode
}

interface ErrorBoundaryState {
  error: Error | null
}

/**
 * Top-level render-error catcher. Without this, an uncaught render error
 * anywhere in the tree unmounts the whole React root and leaves a blank SPA.
 *
 * Mounted in main.tsx OUTSIDE the router but INSIDE ThemeProvider, so the
 * fallback card is themed even though the router (and whatever page threw)
 * is gone. The raw error message is shown only under `import.meta.env.DEV` —
 * a production build must never leak stack traces to the fallback UI.
 */
class ErrorBoundaryImpl extends Component<ErrorBoundaryProps, ErrorBoundaryState> {
  state: ErrorBoundaryState = { error: null }

  static getDerivedStateFromError(error: Error): ErrorBoundaryState {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[ErrorBoundary] unhandled render error', error, info.componentStack)
  }

  handleReload = () => {
    window.location.reload()
  }

  render() {
    const { error } = this.state
    if (!error) return this.props.children

    const { t } = this.props
    return (
      <div className="flex h-screen w-screen items-center justify-center bg-bg p-6">
        <Card className="flex w-[380px] flex-col items-center gap-3 p-7 text-center">
          <div className="text-[16px] font-extrabold text-text-strong">{t('common.errorTitle')}</div>
          <p className="text-[12.5px] text-text-faint">{t('common.errorBody')}</p>
          {import.meta.env.DEV ? (
            <pre className="max-h-32 w-full overflow-auto rounded-[8px] border border-input-border bg-input p-2 text-left text-[11px] text-red">
              {error.message}
            </pre>
          ) : null}
          <Button type="button" variant="primary" onClick={this.handleReload} className="mt-1">
            {t('common.reload')}
          </Button>
        </Card>
      </div>
    )
  }
}

export const ErrorBoundary = withTranslation()(ErrorBoundaryImpl)
