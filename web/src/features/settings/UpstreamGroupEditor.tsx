import { useState } from 'react'
import { AddIcon, DeleteIcon } from '../../components/icons'
import { useTranslation } from 'react-i18next'
import { Badge, Button, Field, Input, Modal } from '../../components/ds'
import {
  createUpstreamSpec,
  parseUpstreamSpec,
  type UpstreamGroup,
  type UpstreamInputErrors,
  type UpstreamProtocol,
} from './upstreams'

interface UpstreamGroupEditorProps {
  group: UpstreamGroup
  entries: string[]
  disabled?: boolean
  onChange: (entries: string[]) => void
}

function initialProtocol(group: UpstreamGroup): UpstreamProtocol {
  return group === 'trust' ? 'dot' : 'udp'
}

function fieldError(
  errors: UpstreamInputErrors,
  field: 'address' | 'serverName',
  requiredMessage: string,
  invalidMessage: string,
): string | undefined {
  if (errors[field] === 'required') return requiredMessage
  if (errors[field] === 'invalid') return invalidMessage
  return undefined
}

function UpstreamAddDialog({
  group,
  entries,
  open,
  onOpenChange,
  onAdd,
}: {
  group: UpstreamGroup
  entries: string[]
  open: boolean
  onOpenChange: (open: boolean) => void
  onAdd: (entry: string) => void
}) {
  const { t } = useTranslation()
  const [protocol, setProtocol] = useState<UpstreamProtocol>(() => initialProtocol(group))
  const [serverName, setServerName] = useState('')
  const [address, setAddress] = useState('')
  const [errors, setErrors] = useState<UpstreamInputErrors>({})
  const [formError, setFormError] = useState<string | null>(null)
  const formId = `upstream-add-${group}-form`

  function reset() {
    setProtocol(initialProtocol(group))
    setServerName('')
    setAddress('')
    setErrors({})
    setFormError(null)
  }

  function handleOpenChange(next: boolean) {
    if (!next) reset()
    onOpenChange(next)
  }

  function handleProtocolChange(next: UpstreamProtocol) {
    setProtocol(next)
    setErrors({})
    setFormError(null)
  }

  function handleAdd() {
    const result = createUpstreamSpec({ group, protocol, address, serverName })
    if (!result.ok) {
      setErrors(result.errors)
      setFormError(null)
      return
    }
    if (entries.some((entry) => entry.trim().toLowerCase() === result.spec.toLowerCase())) {
      setErrors({})
      setFormError(t('settings.upstreamsDuplicate'))
      return
    }

    onAdd(result.spec)
    handleOpenChange(false)
  }

  const addressError = fieldError(
    errors,
    'address',
    t('settings.upstreamsAddressRequired'),
    t('settings.upstreamsAddressInvalid'),
  )
  const serverNameError = fieldError(
    errors,
    'serverName',
    t('settings.upstreamsServerNameRequired'),
    t('settings.upstreamsServerNameInvalid'),
  )

  return (
    <Modal
      open={open}
      onOpenChange={handleOpenChange}
      title={group === 'china' ? t('settings.upstreamsAddChina') : t('settings.upstreamsAddTrust')}
      footer={
        <>
          <Button type="button" variant="secondary" size="sm" onClick={() => handleOpenChange(false)}>
            {t('common.cancel')}
          </Button>
          <Button type="submit" form={formId} size="sm" data-testid={`upstreams-add-${group}-confirm`}>
            {t('common.add')}
          </Button>
        </>
      }
    >
      <form
        id={formId}
        className="flex flex-col gap-3"
        onSubmit={(event) => {
          event.preventDefault()
          handleAdd()
        }}
      >
        <Field label={t('settings.upstreamsProtocol')}>
          {group === 'trust' ? (
            <div className="grid grid-cols-2 gap-1 rounded-[12px] bg-surface-container p-1" role="radiogroup" aria-label={t('settings.upstreamsProtocol')}>
              {(['dot', 'udp'] as const).map((value) => (
                <button
                  key={value}
                  type="button"
                  role="radio"
                  aria-checked={protocol === value}
                  data-testid={`upstreams-protocol-${value}`}
                  onClick={() => handleProtocolChange(value)}
                  className={
                    protocol === value
                      ? 'zds-state-layer rounded-[9px] bg-card px-3 py-2 text-[12px] font-medium text-primary shadow-[var(--md-sys-elevation-1)]'
                      : 'zds-state-layer rounded-[9px] px-3 py-2 text-[12px] text-text-soft'
                  }
                >
                  {value === 'dot' ? t('settings.upstreamsProtocolDot') : t('settings.upstreamsProtocolUdp')}
                </button>
              ))}
            </div>
          ) : (
            <div className="flex items-center gap-2 rounded-[12px] bg-surface-container-low px-3 py-2.5">
              <Badge tone="cyan">{t('settings.upstreamsProtocolUdp')}</Badge>
              <span className="text-[11px] text-text-faint">{t('settings.upstreamsUdpDescription')}</span>
            </div>
          )}
        </Field>

        {protocol === 'dot' ? (
          <Field label={t('settings.upstreamsServerName')} error={serverNameError}>
            <Input
              mono
              autoFocus
              autoComplete="off"
              spellCheck={false}
              value={serverName}
              onChange={(event) => {
                setServerName(event.target.value)
                setErrors((current) => ({ ...current, serverName: undefined }))
                setFormError(null)
              }}
              placeholder="dns.google"
              aria-label={t('settings.upstreamsServerName')}
              aria-invalid={serverNameError !== undefined}
              className={serverNameError ? 'border-red/55 focus-visible:ring-2 focus-visible:ring-red/20' : undefined}
              data-testid="upstreams-server-name"
            />
            <span className="text-[10.5px] text-text-faint">{t('settings.upstreamsServerNameHint')}</span>
          </Field>
        ) : null}

        <Field
          label={protocol === 'dot' ? t('settings.upstreamsDialAddress') : t('settings.upstreamsAddress')}
          error={addressError}
        >
          <Input
            mono
            autoFocus={protocol === 'udp'}
            autoComplete="off"
            spellCheck={false}
            value={address}
            onChange={(event) => {
              setAddress(event.target.value)
              setErrors((current) => ({ ...current, address: undefined }))
              setFormError(null)
            }}
            placeholder={protocol === 'dot' ? '8.8.8.8' : '223.5.5.5'}
            aria-label={protocol === 'dot' ? t('settings.upstreamsDialAddress') : t('settings.upstreamsAddress')}
            aria-invalid={addressError !== undefined}
            className={addressError ? 'border-red/55 focus-visible:ring-2 focus-visible:ring-red/20' : undefined}
            data-testid="upstreams-address"
          />
          <span className="text-[10.5px] text-text-faint">
            {protocol === 'dot' ? t('settings.upstreamsDotAddressHint') : t('settings.upstreamsUdpAddressHint')}
          </span>
        </Field>

        {formError ? <div role="alert" className="text-[11px] text-red">{formError}</div> : null}
      </form>
    </Modal>
  )
}

export function UpstreamGroupEditor({ group, entries, disabled, onChange }: UpstreamGroupEditorProps) {
  const { t } = useTranslation()
  const [addOpen, setAddOpen] = useState(false)
  const title = group === 'china' ? t('settings.upstreamsChina') : t('settings.upstreamsTrust')

  return (
    <section className="flex min-w-0 flex-col gap-2" aria-label={title}>
      <div className="flex items-center justify-between gap-3">
        <div className="flex min-w-0 items-center gap-2">
          <h3 className="truncate text-[12px] font-semibold text-text-mid">{title}</h3>
          <Badge tone="neutral" aria-label={t('settings.upstreamsCount', { count: entries.length })}>
            {entries.length}
          </Badge>
        </div>
        <Button
          type="button"
          variant="secondary"
          size="sm"
          disabled={disabled}
          onClick={() => setAddOpen(true)}
          data-testid={`upstreams-add-${group}`}
        >
          <AddIcon className="h-4 w-4" aria-hidden="true" />
          {t('common.add')}
        </Button>
      </div>

      <div className="overflow-hidden rounded-[14px] bg-surface-container-low">
        {entries.length > 0 ? (
          <ol>
            {entries.map((entry, index) => {
              const parsed = parseUpstreamSpec(group, entry)
              return (
                <li
                  key={`${entry}-${index}`}
                  className="grid min-h-[58px] grid-cols-[32px_minmax(0,1fr)_32px] items-center gap-2 border-b border-divider px-3 py-2.5 last:border-b-0"
                >
                  <span className="font-mono text-[10px] font-semibold tabular-nums text-text-faint" aria-hidden="true">
                    {String(index + 1).padStart(2, '0')}
                  </span>
                  <div className="flex min-w-0 items-center gap-2">
                    <Badge tone={parsed.protocol === 'dot' ? 'blue' : 'cyan'} className="shrink-0 px-2 py-0.5">
                      {parsed.protocol === 'dot'
                        ? t('settings.upstreamsProtocolDot')
                        : t('settings.upstreamsProtocolUdp')}
                    </Badge>
                    <code className="min-w-0 truncate font-mono text-[11.5px] text-text-strong" title={entry}>
                      {entry}
                    </code>
                  </div>
                  <button
                    type="button"
                    disabled={disabled}
                    className="zds-state-layer inline-flex h-9 w-9 items-center justify-center rounded-full text-text-faint hover:text-red disabled:cursor-not-allowed disabled:opacity-50"
                    aria-label={t('settings.upstreamsDelete', { entry })}
                    title={t('common.delete')}
                    onClick={() => onChange(entries.filter((_, entryIndex) => entryIndex !== index))}
                    data-testid={`upstreams-delete-${group}-${index}`}
                  >
                    <DeleteIcon className="h-4 w-4" aria-hidden="true" />
                  </button>
                </li>
              )
            })}
          </ol>
        ) : (
          <div
            role={disabled ? 'status' : 'alert'}
            className={`flex min-h-[58px] items-center px-3 text-[11px] ${disabled ? 'text-text-faint' : 'text-red'}`}
          >
            {disabled ? t('common.loading') : t('settings.upstreamsEmpty')}
          </div>
        )}
      </div>

      <UpstreamAddDialog
        group={group}
        entries={entries}
        open={addOpen}
        onOpenChange={setAddOpen}
        onAdd={(entry) => onChange([...entries, entry])}
      />
    </section>
  )
}
