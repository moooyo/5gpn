import { useEffect, useState, useCallback } from 'react'
import { api, type Subscription, type UpdateResult, type RuleCategory } from '../api'
import { Panel } from '../components/ui'
import { Loading, EmptyState, ErrorNotice, Spinner } from '../components/states'
import { useToast } from '../components/Toast'

const CATEGORIES: RuleCategory[] = ['adblock', 'direct', 'blacklist', 'chnroute']
const FORMATS = ['plain', 'gfwlist', 'dnsmasq', 'adblock', 'hosts', 'cidr']

function blankSub(): Subscription {
  return { id: '', category: 'adblock', name: '', url: '', format: 'plain', enabled: true, interval: '6h' }
}

export function SubscriptionsView() {
  const toast = useToast()
  const [subs, setSubs] = useState<Subscription[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [editing, setEditing] = useState<Subscription | null>(null)
  const [isNew, setIsNew] = useState(false)
  const [busyAll, setBusyAll] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  // Inline per-row last update result.
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
    } catch (e) {
      toast.push('err', e instanceof Error ? e.message : 'Update failed.')
    } finally {
      setBusyAll(false)
    }
  }

  const remove = async (sub: Subscription) => {
    if (!window.confirm(`Delete subscription "${sub.id}"? Its cached rule list will be removed.`)) return
    try {
      await api.deleteSubscription(sub.id)
      toast.push('ok', `Deleted ${sub.id}`)
      load()
    } catch (e) {
      toast.push('err', e instanceof Error ? e.message : 'Delete failed.')
    }
  }

  const save = async (sub: Subscription) => {
    try {
      const res = isNew ? await api.addSubscription(sub) : await api.replaceSubscription(sub.id, sub)
      applyResults([res])
      setEditing(null)
      load()
    } catch (e) {
      // Surface the error inside the form (thrown to caller).
      throw e
    }
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
                {subs.map((s) => {
                  const r = results[s.id]
                  return (
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
                        <span
                          style={{ color: s.enabled ? 'var(--v-direct)' : 'var(--muted)' }}
                        >
                          {s.enabled ? 'on' : 'off'}
                        </span>
                      </td>
                      <td>
                        {r ? (
                          <span style={{ color: r.ok ? 'var(--v-direct)' : 'var(--danger)' }} title={r.err}>
                            {r.ok ? `${r.entries} entries` : 'failed'}
                          </span>
                        ) : (
                          <span style={{ color: 'var(--muted)' }}>—</span>
                        )}
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
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </Panel>

      {editing && (
        <SubForm
          initial={editing}
          isNew={isNew}
          onCancel={() => setEditing(null)}
          onSave={save}
        />
      )}
    </div>
  )
}

function SubForm({
  initial,
  isNew,
  onCancel,
  onSave,
}: {
  initial: Subscription
  isNew: boolean
  onCancel: () => void
  onSave: (s: Subscription) => Promise<void>
}) {
  const [sub, setSub] = useState<Subscription>(initial)
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState<string | null>(null)

  const set = <K extends keyof Subscription>(k: K, v: Subscription[K]) =>
    setSub((s) => ({ ...s, [k]: v }))

  const submit = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setErr(null)
    try {
      await onSave(sub)
    } catch (e2) {
      setErr(e2 instanceof Error ? e2.message : 'Save failed.')
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
            required
          />
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
          <select className="field" value={sub.format} onChange={(e) => set('format', e.target.value)}>
            {FORMATS.map((f) => (
              <option key={f} value={f}>
                {f}
              </option>
            ))}
          </select>
        </label>
        <label className="flex flex-col gap-1.5">
          <span className="eyebrow">Interval</span>
          <input
            className="field"
            value={sub.interval}
            onChange={(e) => set('interval', e.target.value)}
            placeholder="6h"
          />
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

        {err && <div className="sm:col-span-2"><ErrorNotice message={err} /></div>}

        <div className="flex gap-2 sm:col-span-2">
          <button type="submit" className="btn btn-primary" disabled={busy}>
            {busy ? <Spinner size={12} /> : null}
            {isNew ? 'Add & fetch' : 'Save changes'}
          </button>
          <button type="button" className="btn" onClick={onCancel} disabled={busy}>
            Cancel
          </button>
        </div>
      </form>
    </Panel>
  )
}
