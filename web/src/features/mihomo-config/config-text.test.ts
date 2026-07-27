import { describe, expect, it } from 'vitest'
import { lineDiff, lineRange, parseErrorLine } from './config-text'

/**
 * `mihomo -t`'s stderr already carried the line number; the page printed it
 * verbatim as plain text next to an editor with no line numbers, so the
 * operator had to count. These pin the one regex that turns it into a
 * destination, plus the offsets used to reveal it.
 */
describe('parseErrorLine', () => {
  it('extracts the line from a yaml parse error', () => {
    expect(parseErrorLine('yaml: line 42: mapping values are not allowed in this context')).toBe(42)
  })

  it('extracts the line regardless of surrounding text or case', () => {
    expect(parseErrorLine('validation failed: Line 7 near "proxies"')).toBe(7)
  })

  it('returns null when the message names no line', () => {
    expect(parseErrorLine('missing required infrastructure: external-controller')).toBeNull()
    expect(parseErrorLine('')).toBeNull()
    expect(parseErrorLine(null)).toBeNull()
  })

  it('ignores a line number of zero rather than pointing at nothing', () => {
    expect(parseErrorLine('yaml: line 0: bad')).toBeNull()
  })
})

describe('lineRange', () => {
  const text = 'a\nbb\nccc'

  it('spans exactly the requested 1-based line', () => {
    expect(lineRange(text, 1)).toEqual({ start: 0, end: 1 })
    expect(lineRange(text, 2)).toEqual({ start: 2, end: 4 })
    expect(lineRange(text, 3)).toEqual({ start: 5, end: 8 })
  })

  it('clamps a line beyond either end to the nearest real line', () => {
    expect(lineRange(text, 0)).toEqual({ start: 0, end: 1 })
    expect(lineRange(text, 99)).toEqual({ start: 5, end: 8 })
  })
})

/**
 * A multiset comparison rather than an LCS diff: a moved line is neither added
 * nor removed, an edited line is one of each. That is what the `+N −N` readout
 * should say, and it runs on every keystroke.
 */
describe('lineDiff', () => {
  it('reports nothing for identical text', () => {
    expect(lineDiff('a\nb', 'a\nb')).toEqual({ added: 0, removed: 0 })
  })

  it('counts an appended line', () => {
    expect(lineDiff('a\nb', 'a\nb\nc')).toEqual({ added: 1, removed: 0 })
  })

  it('counts a deleted line', () => {
    expect(lineDiff('a\nb\nc', 'a\nc')).toEqual({ added: 0, removed: 1 })
  })

  it('counts an edited line as one of each', () => {
    expect(lineDiff('a\nb', 'a\nB')).toEqual({ added: 1, removed: 1 })
  })

  it('treats a reordered line as unchanged', () => {
    expect(lineDiff('a\nb\nc', 'c\nb\na')).toEqual({ added: 0, removed: 0 })
  })
})
