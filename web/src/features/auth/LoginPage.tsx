import { useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { Shield } from 'lucide-react'
import { Card, Field, Input, Button, toast } from '../../components/ds'
import { api } from '../../lib/api/client'
import { setToken, clearToken, AuthError, ApiError } from '../../lib/api/http'

/** Restyled (ds-tokens) login screen. Submitting stores the token, then
 *  probes it with a live call — a bad token throws AuthError, which we
 *  surface as a toast and roll back (clearToken keeps AuthGate on the login
 *  screen). A good token needs no further action here: setToken already
 *  dispatched '5gpn:auth-changed', which flips AuthGate to the app shell. */
export function LoginPage() {
  const { t } = useTranslation()
  const [value, setValue] = useState('')
  const [submitting, setSubmitting] = useState(false)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const token = value.trim()
    if (!token || submitting) return

    setSubmitting(true)
    setToken(token)
    try {
      await api.getStatus()
    } catch (err) {
      if (err instanceof AuthError) {
        clearToken()
        toast.error(t('errors.tokenRejected'))
      } else if (err instanceof ApiError) {
        toast.error(err.message)
      } else {
        toast.error(t('errors.network'))
      }
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="flex h-screen w-screen items-center justify-center bg-bg">
      <Card className="w-[360px] p-7">
        <div className="mb-6 flex flex-col items-center gap-3 text-center">
          <div
            className="flex h-12 w-12 items-center justify-center rounded-[12px]"
            style={{ background: 'linear-gradient(135deg,#3b82f6,#2563eb)' }}
          >
            <Shield className="h-6 w-6 text-white" strokeWidth={2} />
          </div>
          <div className="text-[17px] font-extrabold text-text-strong">{t('auth.title')}</div>
          <p className="text-[12px] text-text-faint">{t('auth.hint')}</p>
        </div>

        <form className="flex flex-col gap-4" onSubmit={handleSubmit}>
          <Field label={t('auth.tokenLabel')}>
            <Input
              type="password"
              autoFocus
              autoComplete="off"
              value={value}
              onChange={(e) => setValue(e.target.value)}
              placeholder={t('auth.tokenLabel')}
            />
          </Field>
          <Button type="submit" variant="primary" disabled={submitting || !value.trim()}>
            {t('auth.submit')}
          </Button>
        </form>
      </Card>
    </div>
  )
}
