export interface Point {
  x: number
  y: number
}

export function clamp(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) return min
  return Math.min(max, Math.max(min, value))
}

export function chartPoints(data: number[], width: number, height: number, padding = 3): Point[] {
  const values = data.length > 0 ? data.map((value) => (Number.isFinite(value) ? value : 0)) : [0]
  const min = Math.min(...values)
  const max = Math.max(...values)
  const span = max - min || 1
  const usableWidth = Math.max(1, width - padding * 2)
  const usableHeight = Math.max(1, height - padding * 2)
  return values.map((value, index) => ({
    x: padding + (values.length === 1 ? usableWidth / 2 : (index / (values.length - 1)) * usableWidth),
    y: padding + (1 - (value - min) / span) * usableHeight,
  }))
}

export function linePath(points: Point[]): string {
  return points.map((point, index) => `${index === 0 ? 'M' : 'L'} ${point.x.toFixed(2)} ${point.y.toFixed(2)}`).join(' ')
}
