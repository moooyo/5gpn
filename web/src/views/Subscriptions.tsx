import { useEffect, useState, useCallback } from 'react'
import { api, type Subscription, type SubscriptionView, type UpdateResult, type RuleCategory } from '../api'
import { Panel } from '../components/ui'
import { Loading, EmptyState, ErrorNotice, Spinner } from '../components/states'
import { useToast } from '../components/Toast'
import { relativeTime, fmtInt } from '../format'

const CATEGORIES: RuleCategory[] = ['adblock', 'direct', 'blacklist', 'chnroute']
const FORMATS = ['plain', 'gfwlist', 'dnsmasq', 'adblock', 'hosts', 'cidr']
const DOMAIN_FORMATS = ['plain', 'gfwlist', 'dnsmasq', 'adblock', 'hosts']

// A Go-duration shape: 6h, 30m, 1h30m, 1.5s, 500ms, … one or more
// number+unit segments, no spaces.
const GO_DURATION = /^\d+(\.\d+)?(ns|us|µs|ms|s|m|h)([0-9.]+(ns|us|µs|ms|s|m|h))*$/

function blankSub(): Subscription {
  return { id: '', category: 'adblock', name: '', url: '', format: 'plain', enabled: true, interval: '6h' }
}

export function SubscriptionsView() {
  const toast = useToast()
  const [subs, setSubs] = useState<SubscriptionView[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [editing, setEditing] = useState<Subscription | null>(null)
  const [isNew, setIsNew] = useState(false)
  const [busyAll, setBusyAll] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  // Inline per-row last update result from a manual update this session — takes
  // precedence over the persisted health until the next list reload.
  const [results, setResults] = useState<Record<string, UpdateResult>>({})

  const load = useCallback(() => {
    api
      .subscriptions()
      .then((s) => {
        setSubs(s)
        setError(null)
      })
      .catch((e) => setError(e.message))
  }, [])

  useEffect(() => {
    load()
  }, [load])

  const applyResults = (rs: UpdateResult[]) => {
    setResults((prev) => {
      const next = { ...prev }
      for (const r of rs) next[r.id] = r
      return next
    })
    for (const r of rs) {
      if (r.ok) toast.push('ok', `${r.id}: ${r.entries} entries`)
      else toast.push('err', `${r.id}: ${r.err || 'update failed'}`)
    }
  }

  const updateOne = async (id: string) => {
    setBusyId(id)
    try {
      const rs = await api.update(id)
      applyResults(rs)
    } catch (e) {
      toast.push('err', e instanceof Error ? e.message : 'Update failed.')
    } finally {
      setBusyId(null)
    }
  }

  const updateAll = async () => {
    setBusyAll(true)
    try {
      const rs = await api.update()
      applyResults(rs)
      load()
    } catch (e) {
      toast.push('err', e instanceof Error ? e.message : 'Update failed.')
    } finally {
      setBusyAll(false)
    }
  }

  const remove = async (sub: SubscriptionView) => {
    if (!window.confirm(`Delete subscription "${sub.id}"? Its cached rule list will be removed.`)) return
    try {
      await api.deleteSubscription(sub.id)
      toast.push('ok', `Deleted ${sub.id}`)
      load()
    } catch (e) {
      toast.push('err', e instanceof Error ? e.message : 'Delete failed.')
    }
  }

  // Saves and returns the server result to the form; the form decides whether
  // to close (fetch ok) or stay open with a distinct notice (saved, fetch
  // failed). Reloads the list either way so the new row + health appear.
  const save = async (sub: Subscription): Promise<UpdateResult> => {
    const res = isNew ? await api.addSubscription(sub) : await api.replaceSubscription(sub.id, sub)
    setResults((prev) => ({ ...prev, [res.id]: res }))
    load()
    return res
  }

  if (error && !subs) return <ErrorNotice message={error} />
  if (!subs) return <Loading label="Reading subscriptions…" />

  return (
    <div className="flex flex-col gap-4">
      <Panel
        eyebrow="Auto-update"
        title="Subscriptions"
        right={
          <>
            <button className="btn" onClick={updateAll} disabled={busyAll || subs.length === 0}>
              {busyAll ? <Spinner size={12} /> : null}
              Update all
            </button>
            <button
              className="btn btn-primary"
              onClick={() => {
                setEditing(blankSub())
                setIsNew(true)
              }}
            >
              Add subscription
            </button>
          </>
        }
      >
        {subs.length === 0 ? (
          <EmptyState
            title="No subscriptions yet."
            hint="Add one to auto-update a rule list from a remote source on its own interval."
          />
        ) : (
          <div className="overflow-x-auto">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Category</th>
                  <th>URL</th>
                  <th>Format</th>
                  <th>Interval</th>
                  <th>Enabled</th>
                  <th>Last update</th>
                  <th className="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {subs.map((s) => (
                  <tr key={s.id}>
                    <td>
                      <div style={{ color: 'var(--text)' }}>{s.name}</div>
                      <div className="text-xs" style={{ color: 'var(--muted)' }}>
                        {s.id}
                      </div>
                    </td>
                    <td style={{ color: 'var(--muted)' }}>{s.category}</td>
                    <td>
                      <span
                        className="block max-w-[260px] truncate"
                        style={{ color: 'var(--muted)' }}
                        title={s.url}
                      >
                        {s.url}
                      </span>
                    </td>
                    <td style={{ color: 'var(--muted)' }}>{s.format}</td>
                    <td style={{ color: 'var(--muted)' }}>{s.interval}</td>
                    <td>
                      <span style={{ color: s.enabled ? 'var(--v-direct)' : 'var(--muted)' }}>
                        {s.enabled ? 'on' : 'off'}
                      </span>
                    </td>
                    <td>
                      <LastUpdateCell sub={s} result={results[s.id]} />
                    </td>
                    <td>
                      <div className="flex justify-end gap-1.5">
                        <button
                          className="btn btn-sm"
                          onClick={() => updateOne(s.id)}
                          disabled={busyId === s.id}
                        >
                          {busyId === s.id ? <Spinner size={11} /> : 'Update now'}
                        </button>
                        <button
                          className="btn btn-sm"
                          onClick={() => {
                            setEditing(s)
                            setIsNew(false)
                          }}
                        >
                          Edit
                        </button>
                        <button className="btn btn-sm btn-danger" onClick={() => remove(s)}>
                          Delete
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Panel>

      {editing && (
        <SubForm
          key={editing.id || 'new'}
          initial={editing}
          isNew={isNew}
          onCancel={() => setEditing(null)}
          onSave={save}
          onDone={() => setEditing(null)}
        />
      )}
    </div>
  )
}

/**
 * The "Last update" cell. A fresh manual-update result this session wins; else
 * the persisted health from the list read; else "pending" for a sub that has
 * never been fetched.
 */
function LastUpdateCell({ sub, result }: { sub: SubscriptionView; result?: UpdateResult }) {
  // Normalize the two sources into one shape.
  const view = result
    ? { ok: result.ok, entries: result.entries, err: result.err, at: undefined as string | undefined }
    : sub.health
      ? { ok: sub.health.ok, entries: sub.health.entries, err: sub.health.err, at: sub.health.at }
      : null

  if (!view) {
    return <span style={{ color: 'var(--muted)' }}>— pending</span>
  }

  const color = view.ok ? 'var(--v-direct)' : 'var(--danger)'
  return (
    <div className="flex flex-col gap-0.5">
      <div className="flex items-center gap-1.5">
        <span aria-hidden style={{ color }}>
          {view.ok ? '✓' : '✗'}
        </span>
        <span style={{ color }}>{view.ok ? `${fmtInt(view.entries)} entries` : 'failed'}</span>
        {view.at && (
          <span className="text-xs" style={{ color: 'var(--muted)' }} title={view.at}>
            {relativeTime(view.at)}
          </span>
        )}
      </div>
      {!view.ok && view.err && (
        <span className="max-w-[220px] truncate text-xs" style={{ color: 'var(--danger)' }} title={view.err}>
          {view.err}
        </span>
      )}
    </div>
  )
}

// ---- Client-side validation ------------------------------------------------

type FieldErrors = Partial<Record<'url' | 'interval' | 'format' | 'category', string>>

function validate(sub: Subscription): FieldErrors {
  const errs: FieldErrors = {}

  // URL must be http/https.
  try {
    const u = new URL(sub.url)
    if (u.protocol !== 'http:' && u.protocol !== 'https:') {
      errs.url = 'Use an http:// or https:// URL.'
    }
  } catch {
    errs.url = 'Enter a valid http:// or https:// URL.'
  }

  // Interval must be a Go-duration shape.
  if (!GO_DURATION.test(sub.interval.trim())) {
    errs.interval = 'Use a Go duration like 6h, 30m, or 1h30m — not "6 hours".'
  }

  // Category ↔ format sanity.
  if (sub.category === 'chnroute') {
    if (sub.format !== 'cidr') {
      errs.format = 'chnroute needs the cidr format.'
    }
  } else {
    if (!DOMAIN_FORMATS.includes(sub.format)) {
      errs.format = `${sub.category} needs a domain format (${DOMAIN_FORMATS.join(', ')}) — not cidr.`
    }
  }

  return errs
}

function SubForm({
  initial,
  isNew,
  onCancel,
  onSave,
  onDone,
}: {
  initial: Subscription
  isNew: boolean
  onCancel: () => void
  onSave: (s: Subscription) => Promise<UpdateResult>
  onDone: () => void
}) {
  const [sub, setSub] = useState<Subscription>(initial)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)
  const [fieldErrs, setFieldErrs] = useState<FieldErrors>({})
  // Distinct "saved, but first fetch failed" notice (not an error).
  const [savedWarning, setSavedWarning] = useState<string | null>(null)

  const set = <K extends keyof Subscription>(k: K, v: Subscription[K]) =>
    setSub((s) => ({ ...s, [k]: v }))

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setErr(null)
    setSavedWarning(null)

    const fe = validate(sub)
    setFieldErrs(fe)
    if (Object.keys(fe).length > 0) return

    setBusy(true)
    try {
      const res = await onSave(sub)
      if (res.ok) {
        onDone()
      } else {
        // Saved, but the first fetch failed. Keep the form up and explain — the
        // sub exists and will retry on its interval.
        setSavedWarning(
          `Saved — but the first fetch failed${res.err ? ` (${res.err})` : ''}. It will retry on its interval.`,
        )
      }
    } catch (e2) {
      setErr(e2 instanceof Error ? e2.message : 'Save failed.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <Panel eyebrow={isNew ? 'New' : 'Edit'} title={isNew ? 'Add subscription' : `Edit ${sub.id}`}>
      <form onSubmit={submit} className="grid grid-cols-1 gap-4 sm:grid-cols-2">
        <label className="flex flex-col gap-1.5">
          <span className="eyebrow">ID</span>
          <input
            className="field"
            value={sub.id}
            onChange={(e) => set('id', e.target.value)}
            disabled={!isNew}
            placeholder="gfwlist-main"
            required
          />
        </label>
        <label className="flex flex-col gap-1.5">
          <span className="eyebrow">Name</span>
          <input
            className="field"
            value={sub.name}
            onChange={(e) => set('name', e.target.value)}
            placeholder="gfwlist"
            required
          />
        </label>
        <label className="flex flex-col gap-1.5 sm:col-span-2">
          <span className="eyebrow">URL</span>
          <input
            className="field"
            value={sub.url}
            onChange={(e) => set('url', e.target.value)}
            placeholder="https://example.com/list.txt"
            aria-invalid={fieldErrs.url ? true : undefined}
            required
          />
          <FieldError message={fieldErrs.url} />
        </label>
        <label className="flex flex-col gap-1.5">
          <span className="eyebrow">Category</span>
          <select
            className="field"
            value={sub.category}
            onChange={(e) => set('category', e.target.value as RuleCategory)}
          >
            {CATEGORIES.map((c) => (
              <option key={c} value={c}>
                {c}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1.5">
          <span className="eyebrow">Format</span>
          <select
            className="field"
            value={sub.format}
            onChange={(e) => set('format', e.target.value)}
            aria-invalid={fieldErrs.format ? true : undefined}
          >
            {FORMATS.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
          <FieldError message={fieldErrs.format} />
        </label>
        <label className="flex flex-col gap-1.5">
          <span className="eyebrow">Interval</span>
          <input
            className="field"
            value={sub.interval}
            onChange={(e) => set('interval', e.target.value)}
            placeholder="6h"
            aria-invalid={fieldErrs.interval ? true : undefined}
          />
          <FieldError message={fieldErrs.interval} />
        </label>
        <label className="flex items-center gap-2 self-end pb-2">
          <input
            type="checkbox"
            checked={sub.enabled}
            onChange={(e) => set('enabled', e.target.checked)}
            style={{ accentColor: 'var(--accent)', width: 16, height: 16 }}
          />
          <span className="eyebrow">Enabled</span>
        </label>

        {savedWarning && (
          <div className="sm:col-span-2">
            <SavedNotice message={savedWarning} />
          </div>
        )}
        {err && (
          <div className="sm:col-span-2">
            <ErrorNotice message={err} />
          </div>
        )}

        <div className="flex gap-2 sm:col-span-2">
          {savedWarning ? (
            <button type="button" className="btn btn-primary" onClick={onDone}>
              Done
            </button>
          ) : (
            <button type="submit" className="btn btn-primary" disabled={busy}>
              {busy ? <Spinner size={12} /> : null}
              {isNew ? 'Add & fetch' : 'Save changes'}
            </button>
          )}
          <button type="button" className="btn" onClick={onCancel} disabled={busy}>
            {savedWarning ? 'Close' : 'Cancel'}
          </button>
        </div>
      </form>
    </Panel>
  )
}

/** A small inline field error line, in the danger color. */
function FieldError({ message }: { message?: string }) {
  if (!message) return null
  return (
    <span className="font-mono text-xs" style={{ color: 'var(--danger)' }} role="alert">
      {message}
    </span>
  )
}

/** A distinct "saved, but…" notice — amber, NOT the rose error strip. */
function SavedNotice({ message }: { message: string }) {
  return (
    <div
      className="rounded-panel px-4 py-3 text-xs"
      style={{
        border: '1px solid var(--v-proxy)',
        background: 'color-mix(in srgb, var(--v-proxy) 12%, transparent)',
        color: 'var(--text)',
      }}
      role="status"
    >
      <span className="font-mono">{message}</span>
    </div>
  )
}
