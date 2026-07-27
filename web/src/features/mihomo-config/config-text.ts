/**
 * Two small text facts the config editor needs, kept out of the component so
 * they can be tested without mounting a textarea.
 */

/**
 * The line number `mihomo -t` names in its stderr, e.g.
 * `yaml: line 42: mapping values are not allowed in this context`.
 *
 * The page already showed that message verbatim in a banner, so the number was
 * on screen the whole time — as plain text, next to an editor with no line
 * numbers, leaving the operator to count. One regex turns it into a
 * destination.
 *
 * Returns a 1-based line, or null when the message names none.
 */
export function parseErrorLine(message: string | null | undefined): number | null {
  if (!message) return null
  const match = /\bline (\d+)/i.exec(message)
  if (!match) return null
  const line = Number.parseInt(match[1], 10)
  return Number.isFinite(line) && line > 0 ? line : null
}

export interface LineDiff {
  added: number
  removed: number
}

/**
 * How many lines the editor has gained and lost against the persisted text.
 *
 * This is a multiset comparison, not an LCS diff: a moved line is neither added
 * nor removed, and an edited line counts as one of each. That is exactly what
 * the `+N −N` readout should say, and it costs one pass instead of a diff
 * algorithm running on every keystroke of a several-hundred-line document.
 */
export function lineDiff(persisted: string, current: string): LineDiff {
  const counts = new Map<string, number>()
  for (const line of persisted.split('\n')) counts.set(line, (counts.get(line) ?? 0) + 1)
  let added = 0
  for (const line of current.split('\n')) {
    const remaining = counts.get(line) ?? 0
    if (remaining > 0) counts.set(line, remaining - 1)
    else added += 1
  }
  let removed = 0
  for (const remaining of counts.values()) removed += remaining
  return { added, removed }
}

/** Character offsets of a 1-based line within `text`, clamped to its bounds.
 *  Used to select and reveal the line the validator complained about. */
export function lineRange(text: string, line: number): { start: number; end: number } {
  const lines = text.split('\n')
  const index = Math.min(Math.max(line, 1), lines.length) - 1
  let start = 0
  for (let i = 0; i < index; i += 1) start += lines[i].length + 1
  return { start, end: start + lines[index].length }
}
