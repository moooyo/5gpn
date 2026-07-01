import { useState } from 'react'
import { api, AuthError, setToken, type Status } from '../api'
import { Spinner } from '../components/states'

interface LoginProps {
  theme: 'dark' | 'light'
  onToggleTheme: () => void
  onConnected: (s: Status) => void
}

/**
 * Login — a centered card on the dark field. The token is stored, then
 * verified via GET /api/status: 200 -> Dashboard; 401 -> inline error. The
 * token value is never logged.
 */
export function LoginView({ onConnected }: LoginProps) {
  const [token, setTokenInput] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    const t = token.trim()
    if (!t || busy) return
    setBusy(true)
    setError(null)
    // Store first so the verifying request carries the bearer header.
    setToken(t)
    try {
      const s = await api.status()
      onConnected(s)
    } catch (err) {
      if (err instanceof AuthError) {
        setError('Token rejected — check the value printed by install.sh.')
      } else {
        setError('Could not reach the control server. Confirm it is running on :9443.')
      }
      setBusy(false)
    }
  }

  return (
    <div className="flex h-full items-center justify-center px-4" style={{ background: 'var(--bg)' }}>
      <div className="w-full max-w-sm">
        <div className="mb-6 flex items-center justify-center gap-3">
          <svg width="26" height="26" viewBox="0 0 18 18" fill="none" aria-hidden>
            <rect x="1" y="10" width="3" height="6" rx="1" fill="var(--v-block)" />
            <rect x="6" y="6" width="3" height="10" rx="1" fill="var(--v-proxy)" />
            <rect x="11" y="2" width="3" height="14" rx="1" fill="var(--v-direct)" />
          </svg>
          <span className="font-display text-2xl font-bold" style={{ letterSpacing: '0.02em' }}>
            5gpn-dns
          </span>
        </div>

        <form onSubmit={submit} className="panel panel-pad">
          <div className="eyebrow mb-1">Control console</div>
          <p className="mb-5 text-xs" style={{ color: 'var(--muted)' }}>
            China-route DNS gateway. Sign in with the API token to inspect verdicts, rules, and
            subscriptions.
          </p>

          <label className="eyebrow mb-1.5 block" htmlFor="token">
            API token
          </label>
          <input
            id="token"
            type="password"
            className="field"
            autoComplete="current-password"
            placeholder="paste the token from install.sh"
            value={token}
            onChange={(e) => setTokenInput(e.target.value)}
            autoFocus
          />

          {error && (
            <div className="mt-3 font-mono text-xs" style={{ color: 'var(--danger)' }} role="alert">
              {error}
            </div>
          )}

          <button
            type="submit"
            className="btn btn-primary mt-5 w-full"
            disabled={busy || token.trim() === ''}
            style={{ padding: '10px 14px' }}
          >
            {busy ? <Spinner /> : null}
            {busy ? 'Connecting…' : 'Connect'}
          </button>
        </form>
      </div>
    </div>
  )
}
