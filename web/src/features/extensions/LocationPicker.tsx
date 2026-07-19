import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import type * as Leaflet from 'leaflet'
import { Button, Input } from '../../components/ds'
import { LocationIcon, MyLocationIcon, SearchIcon } from '../../components/icons'
import { api } from '../../lib/api/client'
import './LocationPicker.css'

const DEFAULT_CENTER: [number, number] = [35.8617, 104.1954]
const TILE_URL = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'

interface CityResult {
  place_id: number
  display_name: string
  lat: string
  lon: string
}

export interface LocationPoint {
  longitude?: number
  latitude?: number
  accuracy: number
}

function validPoint(value: LocationPoint): value is LocationPoint & { longitude: number; latitude: number } {
  return Number.isFinite(value.longitude) && Number.isFinite(value.latitude)
}

function rounded(value: number): number {
  return Number(value.toFixed(6))
}

export function LocationPicker({
  value,
  disabled,
  onChange,
}: {
  value: LocationPoint
  disabled?: boolean
  onChange: (value: LocationPoint) => void
}) {
  const { t, i18n } = useTranslation()
  const containerRef = useRef<HTMLDivElement>(null)
  const leafletRef = useRef<typeof Leaflet | null>(null)
  const mapRef = useRef<Leaflet.Map | null>(null)
  const markerRef = useRef<Leaflet.Marker | null>(null)
  const circleRef = useRef<Leaflet.Circle | null>(null)
  const onChangeRef = useRef(onChange)
  const valueRef = useRef(value)
  const [query, setQuery] = useState('')
  const [results, setResults] = useState<CityResult[]>([])
  const [searching, setSearching] = useState(false)
  const [searchError, setSearchError] = useState(false)
  const [mapFailed, setMapFailed] = useState(false)

  onChangeRef.current = onChange
  valueRef.current = value

  const syncPoint = useCallback((point: LocationPoint, fly = false) => {
    const L = leafletRef.current
    const map = mapRef.current
    if (!L || !map || !validPoint(point)) return
    const latLng: Leaflet.LatLngExpression = [point.latitude, point.longitude]
    if (!markerRef.current) {
      const icon = L.divIcon({ className: 'extension-location-pin', iconSize: [28, 36], iconAnchor: [14, 34] })
      const marker = L.marker(latLng, { draggable: true, icon, keyboard: true, title: t('extensions.location.selected') }).addTo(map)
      marker.on('dragend', () => {
        const next = marker.getLatLng()
        onChangeRef.current({ ...valueRef.current, longitude: rounded(next.lng), latitude: rounded(next.lat) })
      })
      markerRef.current = marker
    } else {
      markerRef.current.setLatLng(latLng)
    }
    if (!circleRef.current) {
      circleRef.current = L.circle(latLng, {
        radius: point.accuracy,
        color: 'var(--md-sys-color-primary)',
        fillColor: 'var(--md-sys-color-primary-container)',
        fillOpacity: 0.24,
        weight: 2,
      }).addTo(map)
    } else {
      circleRef.current.setLatLng(latLng).setRadius(point.accuracy)
    }
    if (fly) map.flyTo(latLng, Math.max(map.getZoom(), 13), { duration: 0.6 })
  }, [t])

  useEffect(() => {
    let cancelled = false
    let observer: ResizeObserver | undefined
    void import('leaflet').then((L) => {
      if (cancelled || !containerRef.current) return
      leafletRef.current = L
      const initial = validPoint(valueRef.current)
        ? [valueRef.current.latitude, valueRef.current.longitude] as [number, number]
        : DEFAULT_CENTER
      const map = L.map(containerRef.current, { zoomControl: true, attributionControl: true }).setView(initial, validPoint(valueRef.current) ? 13 : 4)
      mapRef.current = map
      L.tileLayer(TILE_URL, {
        maxZoom: 19,
        referrerPolicy: 'origin',
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      }).addTo(map)
      map.on('click', (event: Leaflet.LeafletMouseEvent) => {
        if (disabled) return
        const next = { ...valueRef.current, longitude: rounded(event.latlng.lng), latitude: rounded(event.latlng.lat) }
        onChangeRef.current(next)
        syncPoint(next)
      })
      syncPoint(valueRef.current)
      requestAnimationFrame(() => map.invalidateSize())
      observer = new ResizeObserver(() => map.invalidateSize())
      observer.observe(containerRef.current)
    }).catch(() => {
      if (!cancelled) setMapFailed(true)
    })
    return () => {
      cancelled = true
      observer?.disconnect()
      markerRef.current = null
      circleRef.current = null
      mapRef.current?.remove()
      mapRef.current = null
      leafletRef.current = null
    }
  }, [disabled, syncPoint])

  useEffect(() => {
    syncPoint(value)
  }, [syncPoint, value])

  async function search(event: FormEvent) {
    event.preventDefault()
    const term = query.trim()
    if (!term || searching) return
    setSearching(true)
    setSearchError(false)
    try {
      const body = await api.searchCities(term, i18n.language)
      setResults(body.filter((item) => Number.isFinite(Number(item.lat)) && Number.isFinite(Number(item.lon))))
    } catch {
      setResults([])
      setSearchError(true)
    } finally {
      setSearching(false)
    }
  }

  function choose(result: CityResult) {
    const next = { ...value, longitude: rounded(Number(result.lon)), latitude: rounded(Number(result.lat)) }
    onChange(next)
    syncPoint(next, true)
    setResults([])
    setQuery(result.display_name)
  }

  function locate() {
    if (!navigator.geolocation || disabled) return
    navigator.geolocation.getCurrentPosition((position) => {
      const next = {
        ...valueRef.current,
        longitude: rounded(position.coords.longitude),
        latitude: rounded(position.coords.latitude),
        accuracy: Math.max(1, Math.round(position.coords.accuracy || valueRef.current.accuracy)),
      }
      onChangeRef.current(next)
      syncPoint(next, true)
    })
  }

  return (
    <div className="space-y-3" data-testid="extension-location-picker">
      <form onSubmit={(event) => void search(event)} className="flex gap-2">
        <div className="relative min-w-0 flex-1">
          <SearchIcon className="pointer-events-none absolute left-3.5 top-1/2 h-4 w-4 -translate-y-1/2 text-text-faint" aria-hidden="true" />
          <Input value={query} onChange={(event) => setQuery(event.target.value)} className="pl-10" aria-label={t('extensions.location.citySearch')} placeholder={t('extensions.location.cityPlaceholder')} disabled={disabled || searching} />
        </div>
        <Button type="submit" variant="tonal" size="sm" disabled={disabled || searching || !query.trim()}>{searching ? t('common.loading') : t('extensions.location.search')}</Button>
        <Button type="button" variant="secondary" size="sm" className="w-10 px-0" aria-label={t('extensions.location.useCurrent')} title={t('extensions.location.useCurrent')} onClick={locate} disabled={disabled}>
          <MyLocationIcon className="h-4 w-4" aria-hidden="true" />
        </Button>
      </form>

      {results.length > 0 ? (
        <div className="max-h-40 overflow-y-auto rounded-[14px] bg-surface-container-low p-1.5" role="listbox" aria-label={t('extensions.location.results')}>
          {results.map((result) => (
            <button key={result.place_id} type="button" role="option" aria-selected="false" onClick={() => choose(result)} className="zds-state-layer flex w-full items-start gap-2 rounded-[10px] px-3 py-2.5 text-left text-[11.5px] text-text-mid">
              <LocationIcon className="mt-0.5 h-4 w-4 shrink-0 text-primary" aria-hidden="true" />
              <span>{result.display_name}</span>
            </button>
          ))}
        </div>
      ) : null}
      {searchError ? <p role="alert" className="text-[11px] text-red">{t('extensions.location.searchFailed')}</p> : null}

      <div className="relative overflow-hidden rounded-[18px] border border-divider">
        <div ref={containerRef} className="extension-location-map" role="region" aria-label={t('extensions.location.map')} />
        {!validPoint(value) && !mapFailed ? (
          <div className="pointer-events-none absolute inset-x-4 bottom-4 rounded-full bg-card/90 px-4 py-2 text-center text-[11px] text-text-soft shadow-[var(--md-sys-elevation-1)]">
            {t('extensions.location.pickHint')}
          </div>
        ) : null}
        {mapFailed ? <div className="absolute inset-0 grid place-items-center bg-surface-container-low p-6 text-center text-[11px] text-text-faint">{t('extensions.location.mapFailed')}</div> : null}
      </div>
      <p className="text-[10px] leading-4 text-text-faint">{t('extensions.location.provider')}</p>
    </div>
  )
}
