import { useEffect, useState } from 'react'

const STORAGE_KEY = '5gpn_mitm_ca_acknowledged'
const CHANGE_EVENT = '5gpn:mitm-ca-acknowledgement'

function readAcknowledgement(): boolean {
  if (typeof localStorage === 'undefined') return false
  try {
    return localStorage.getItem(STORAGE_KEY) === 'true'
  } catch {
    return false
  }
}

export function useMITMTrustAcknowledgement() {
  const [acknowledged, setAcknowledgedState] = useState(readAcknowledgement)

  useEffect(() => {
    const sync = () => setAcknowledgedState(readAcknowledgement())
    window.addEventListener('storage', sync)
    window.addEventListener(CHANGE_EVENT, sync)
    return () => {
      window.removeEventListener('storage', sync)
      window.removeEventListener(CHANGE_EVENT, sync)
    }
  }, [])

  const setAcknowledged = (next: boolean) => {
    setAcknowledgedState(next)
    try {
      localStorage.setItem(STORAGE_KEY, String(next))
      window.dispatchEvent(new Event(CHANGE_EVENT))
    } catch {
      // The acknowledgement remains available for the current page session.
    }
  }

  return { acknowledged, setAcknowledged }
}
