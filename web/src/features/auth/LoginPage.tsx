import { useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { ShieldLockIcon } from '../../components/icons'
import { Button, Card, Field, Input, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import { ApiError, AuthError, clearToken, setToken } from '../../lib/api/http'

export function LoginPage() {
  const { t } = useTranslation()
  const [value, setValue] = useState('')
  const [submitting, setSubmitting] = useState(false)

  async function handleSubmit(event: FormEvent) {
    event.preventDefault()
    const token = value.trim()
    if (!token || submitting) return

    setSubmitting(true)
    setToken(token)
    try {
      await api.getStatus()
    } catch (error) {
      if (error instanceof AuthError) {
        clearToken()
        toast.error(t('errors.tokenRejected'))
      } else if (error instanceof ApiError) {
        toast.error(error.message)
      } else {
        toast.error(t('errors.network'))
      }
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="grid min-h-dvh w-full place-items-center bg-bg p-4" data-testid="login-page">
      <Card className="w-full max-w-[410px] rounded-[28px] border-0 p-7 shadow-[var(--md-sys-elevation-2)] sm:p-9">
        <div className="mb-7 flex flex-col items-center text-center">
          <div className="mb-4 grid h-16 w-16 place-items-center rounded-full bg-primary-container text-on-primary-container">
            <ShieldLockIcon className="h-8 w-8" aria-hidden="true" />
          </div>
          <h1 className="text-[23px] font-medium tracking-[-.01em] text-text-strong">{t('auth.title')}</h1>
          <p className="mt-2 max-w-[300px] text-[12.5px] leading-5 text-text-faint">{t('auth.hint')}</p>
        </div>

        <form className="flex flex-col gap-5" onSubmit={handleSubmit}>
          <Field label={t('auth.tokenLabel')} supportingText={t('auth.tokenSupporting')}>
            <Input
              type="password"
              autoFocus
              autoComplete="off"
              value={value}
              onChange={(event) => setValue(event.target.value)}
              placeholder={t('auth.tokenPlaceholder')}
              mono
            />
          </Field>
          <Button type="submit" variant="primary" className="w-full" disabled={submitting || !value.trim()}>
            {submitting ? t('common.loading') : t('auth.submit')}
          </Button>
        </form>

        <div className="mt-7 flex items-center justify-center gap-2 text-[10.5px] text-text-faint">
          <span className="h-2 w-2 rounded-full bg-green" />
          {t('auth.apiBoundary')}
        </div>
      </Card>
    </main>
  )
}
