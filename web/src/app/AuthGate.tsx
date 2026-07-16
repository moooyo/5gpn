import { useEffect, useState, type ReactNode } from 'react'
import { getToken } from '../lib/api/http'
import { LoginPage } from '../features/auth/LoginPage'

/** Gates the app shell behind a bearer token in localStorage. Re-reads the
 *  token on the '5gpn:auth-changed' event (dispatched by http.ts's
 *  setToken/clearToken — including the 401 -> clearToken path) and on the
 *  cross-tab 'storage' event, so a 401 anywhere in the app flips straight
 *  back to the login screen without a manual reload. */
export function AuthGate({ children }: { children: ReactNode }) {
  const [token, setTokenState] = useState<string | null>(() => getToken())

  useEffect(() => {
    const sync = () => setTokenState(getToken())
    window.addEventListener('5gpn:auth-changed', sync)
    window.addEventListener('storage', sync)
    return () => {
      window.removeEventListener('5gpn:auth-changed', sync)
      window.removeEventListener('storage', sync)
    }
  }, [])

  if (!token) return <LoginPage />
  return <>{children}</>
}
