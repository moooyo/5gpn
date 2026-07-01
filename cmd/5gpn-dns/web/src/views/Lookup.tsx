import { useState } from 'react'
import { api, type LookupResult } from '../api'
import { Panel } from '../components/ui'
import { VerdictTag } from '../components/VerdictTag'
import { Spinner, ErrorNotice } from '../components/states'
import { laneForReason, laneForVerdict, reasonExplained } from '../verdicts'

export function LookupView() {
  const [domain, setDomain] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [result, setResult] = useState<LookupResult | null>(null)

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    const d = domain.trim()
    if (!d || busy) return
    setBusy(true)
    setError(null)
    try {
      const r = await api.lookup(d)
      setResult(r)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Lookup failed.')
      setResult(null)
    } finally {
      setBusy(false)
    }
  }

  const lane = result ? (laneForReason(result.reason) ?? laneForVerdict(result.verdict)) : null
  const ips = result?.ips ?? []

  return (
    <div className="flex flex-col gap-4">
      <Panel eyebrow="Classify" title="Look up a name">
        <p className="mb-4 text-xs" style={{ color: 'var(--muted)' }}>
          Runs the same classification the resolver uses. Nothing is cached; each lookup performs a
          fresh query.
        </p>
        <form onSubmit={submit} className="flex gap-2">
          <input
            className="field"
            placeholder="example.com"
            value={domain}
            onChange={(e) => setDomain(e.target.value)}
            spellCheck={false}
            autoCapitalize="off"
            autoFocus
          />
          <button type="submit" className="btn btn-primary" disabled={busy || domain.trim() === ''}>
            {busy ? <Spinner /> : null}
            Look up
          </button>
        </form>
      </Panel>

      {error && <ErrorNotice message={error} />}

      {result && (
        <Panel eyebrow="Result" title={<span className="font-mono">{result.name}</span>}>
          <div className="flex flex-col gap-5">
            <div>
              <VerdictTag lane={lane} size="lg">
                {result.verdict || 'no verdict'}
              </VerdictTag>
              <p className="mt-3 max-w-prose text-sm" style={{ color: 'var(--text)' }}>
                {reasonExplained(result.reason)}
              </p>
            </div>

            <div className="grid grid-cols-1 gap-5 sm:grid-cols-2">
              <div>
                <div className="eyebrow mb-2">Resolved addresses</div>
                {ips.length > 0 ? (
                  <ul className="flex flex-col gap-1">
                    {ips.map((ip) => (
                      <li key={ip} className="font-mono text-sm" style={{ color: 'var(--text)' }}>
                        {ip}
                      </li>
                    ))}
                  </ul>
                ) : (
                  <span className="font-mono text-sm" style={{ color: 'var(--muted)' }}>
                    —
                  </span>
                )}
              </div>
              <div>
                <div className="eyebrow mb-2">Upstream</div>
                <span className="font-mono text-sm" style={{ color: 'var(--text)' }}>
                  {result.upstream || '—'}
                </span>
                <div className="eyebrow mb-2 mt-4">Reason code</div>
                <span className="font-mono text-sm" style={{ color: 'var(--muted)' }}>
                  {result.reason || '—'}
                </span>
              </div>
            </div>
          </div>
        </Panel>
      )}
    </div>
  )
}
