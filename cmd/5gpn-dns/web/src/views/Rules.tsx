import { useEffect, useState, useCallback } from 'react'
import { api, type RuleCategory } from '../api'
import { LANES, laneForCategory } from '../verdicts'
import { Spinner, EmptyState, ErrorNotice } from '../components/states'
import { useToast } from '../components/Toast'

const CATEGORIES: { cat: RuleCategory; blurb: string; placeholder: string }[] = [
  { cat: 'adblock', blurb: 'Answered as NXDOMAIN — these names never resolve.', placeholder: 'ads.example.com' },
  { cat: 'direct', blurb: 'Forced onto the local route regardless of geo classification.', placeholder: 'intranet.example.cn' },
  { cat: 'blacklist', blurb: 'Sinkholed to the gateway.', placeholder: 'blocked.example.com' },
  { cat: 'chnroute', blurb: 'China-route CIDRs — members resolve real and go direct.', placeholder: '203.0.113.0/24' },
]

export function RulesView() {
  const toast = useToast()
  const [reloadKey, setReloadKey] = useState(0)
  const [reloading, setReloading] = useState(false)

  const reloadFromDisk = async () => {
    if (reloading) return
    setReloading(true)
    try {
      await api.reload()
      toast.push('ok', 'Reloaded rules from disk.')
      setReloadKey((k) => k + 1) // re-fetch every panel's list
    } catch (err) {
      toast.push('err', err instanceof Error ? err.message : 'Could not reload rules.')
    } finally {
      setReloading(false)
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <header className="flex items-center gap-3">
        <p className="text-xs" style={{ color: 'var(--muted)' }}>
          Manual entries merge with subscription caches. Edited the files on the box directly?
          Reload to apply them to the live engine.
        </p>
        <button
          className="btn btn-sm ml-auto shrink-0"
          onClick={reloadFromDisk}
          disabled={reloading}
        >
          {reloading ? <Spinner size={12} /> : null}
          Reload from disk
        </button>
      </header>
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        {CATEGORIES.map((c) => (
          <RulePanel
            key={c.cat}
            cat={c.cat}
            blurb={c.blurb}
            placeholder={c.placeholder}
            reloadKey={reloadKey}
          />
        ))}
      </div>
    </div>
  )
}

function RulePanel({
  cat,
  blurb,
  placeholder,
  reloadKey,
}: {
  cat: RuleCategory
  blurb: string
  placeholder: string
  reloadKey: number
}) {
  const toast = useToast()
  const lane = laneForCategory(cat)
  const color = lane ? LANES[lane].color : 'var(--accent)'

  const [entries, setEntries] = useState<string[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [input, setInput] = useState('')
  const [busy, setBusy] = useState(false)
  const [removing, setRemoving] = useState<string | null>(null)

  const load = useCallback(() => {
    api
      .rules(cat)
      .then((e) => {
        setEntries(e)
        setLoadError(null)
      })
      .catch((e) => {
        // Persist a per-panel error so a failed load is visibly distinct from a
        // genuinely empty category (rather than a toast that fades to nothing).
        setLoadError(e instanceof Error ? e.message : 'Load failed.')
      })
  }, [cat])

  useEffect(() => {
    load()
  }, [load, reloadKey])

  const add = async (e: React.FormEvent) => {
    e.preventDefault()
    const v = input.trim()
    if (!v || busy) return
    setBusy(true)
    try {
      await api.addRule(cat, v)
      setInput('')
      toast.push('ok', `Added to ${cat}: ${v}`)
      load()
    } catch (err) {
      toast.push('err', err instanceof Error ? err.message : `Could not add to ${cat}.`)
    } finally {
      setBusy(false)
    }
  }

  const remove = async (entry: string) => {
    setRemoving(entry)
    try {
      await api.removeRule(cat, entry)
      toast.push('ok', `Removed from ${cat}: ${entry}`)
      load()
    } catch (err) {
      toast.push('err', err instanceof Error ? err.message : `Could not remove from ${cat}.`)
    } finally {
      setRemoving(null)
    }
  }

  return (
    <section className="panel flex flex-col" style={{ overflow: 'hidden' }}>
      <header
        className="px-5 py-4"
        style={{ borderBottom: '1px solid var(--border)', borderTop: `3px solid ${color}` }}
      >
        <div className="flex items-center gap-2">
          <span aria-hidden style={{ color }}>
            {lane ? LANES[lane].glyph : '·'}
          </span>
          <h2
            className="font-display text-sm font-semibold uppercase"
            style={{ color, letterSpacing: '0.08em' }}
          >
            {cat}
          </h2>
          <span className="ml-auto font-mono text-xs" style={{ color: 'var(--muted)' }}>
            {loadError ? '!' : entries ? `${entries.length}` : '·'}
          </span>
        </div>
        <p className="mt-1 text-xs" style={{ color: 'var(--muted)' }}>
          {blurb}
        </p>
      </header>

      <div className="flex-1 px-5 py-4">
        {loadError && (!entries || entries.length === 0) ? (
          <ErrorNotice message={`Couldn't load ${cat} — ${loadError}`}>
            <div className="mt-3">
              <button className="btn btn-sm" onClick={load}>
                Retry
              </button>
            </div>
          </ErrorNotice>
        ) : entries === null ? (
          <div className="flex items-center gap-2 py-4" style={{ color: 'var(--muted)' }}>
            <Spinner />
            <span className="font-mono text-xs">Loading…</span>
          </div>
        ) : entries.length === 0 ? (
          <EmptyState
            title={`No manual ${cat} entries yet.`}
            hint={
              cat === 'chnroute'
                ? 'Add a CIDR to force it onto the China route.'
                : 'Add a domain to steer it into this lane.'
            }
          />
        ) : (
          <ul className="flex flex-col">
            {entries.map((entry) => (
              <li
                key={entry}
                className="flex items-center justify-between gap-2 py-1.5"
                style={{ borderBottom: '1px solid var(--border)' }}
              >
                <span className="truncate font-mono text-sm" style={{ color: 'var(--text)' }} title={entry}>
                  {entry}
                </span>
                <button
                  className="btn btn-sm btn-danger"
                  onClick={() => remove(entry)}
                  disabled={removing === entry}
                  style={{ padding: '3px 9px' }}
                >
                  {removing === entry ? <Spinner size={11} /> : 'Remove'}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>

      <form
        onSubmit={add}
        className="flex gap-2 px-5 py-4"
        style={{ borderTop: '1px solid var(--border)' }}
      >
        <input
          className="field"
          placeholder={placeholder}
          value={input}
          onChange={(e) => setInput(e.target.value)}
          spellCheck={false}
          autoCapitalize="off"
          aria-label={`Add a ${cat} entry`}
        />
        <button type="submit" className="btn" disabled={busy || input.trim() === ''}>
          {busy ? <Spinner size={12} /> : null}
          Add entry
        </button>
      </form>
    </section>
  )
}
