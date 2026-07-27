import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { LogSearchField, LogSurface, logSurfaceHeight } from './LogSurface'

/**
 * The three log pages had three of everything: three toolbars at different
 * padding, three empty/list ternaries, three footers, three hand-tuned height
 * clamps and three search inputs at three heights (31/36/44px). These pin the
 * contracts the extraction depends on — especially the DOM shape, which an
 * e2e test asserts from the outside and which no page-level unit test would
 * notice breaking.
 */
describe('LogSurface', () => {
  const body = (height: string) => <div data-testid="list" data-height={height} />

  it('emits neither chrome row when the page supplies none, so the list stays a direct child of the card', () => {
    const { container } = render(
      <LogSurface chrome={330} footer="42 lines">{body}</LogSurface>,
    )
    const card = container.querySelector('.card')!
    // e2e/mobile-plugin-logs.spec.ts asserts `virtual-scroll`'s parent carries
    // `card`. An empty bordered div in either chrome slot would still satisfy
    // that, but it would draw a stray divider — and a wrapper around the body
    // would break it outright.
    expect(card.firstElementChild).toBe(screen.getByTestId('list'))
    expect(card.children).toHaveLength(2) // list + footer
  })

  it('hands the computed height to the list rather than sizing a wrapper', () => {
    render(<LogSurface chrome={320}>{body}</LogSurface>)
    expect(screen.getByTestId('list')).toHaveAttribute('data-height', logSurfaceHeight(320))
  })

  it('puts actions on the title row when there is a title', () => {
    render(
      <LogSurface chrome={310} title="Live output" count={7} actions={<button type="button">pause</button>}>
        {body}
      </LogSurface>,
    )
    const title = screen.getByText('Live output').parentElement!
    expect(title).toContainElement(screen.getByRole('button', { name: 'pause' }))
  })

  it('puts actions on the toolbar row when there is no title', () => {
    render(
      <LogSurface chrome={320} search={<input aria-label="search" />} actions={<button type="button">pause</button>}>
        {body}
      </LogSurface>,
    )
    const toolbar = screen.getByLabelText('search').closest('div')!.parentElement!
    expect(toolbar).toContainElement(screen.getByRole('button', { name: 'pause' }))
  })

  // Right after a clear the count is 0, and the pill has to say so rather than
  // disappear or leak a bare `0` text node.
  it('renders a zero count', () => {
    render(<LogSurface chrome={310} title="Live output" count={0}>{body}</LogSurface>)
    expect(screen.getByText('0')).toBeInTheDocument()
  })

  it('replaces the list with the empty state, and does not give it the fixed height', () => {
    render(
      <LogSurface chrome={310} isEmpty empty={<div data-testid="empty" />}>{body}</LogSurface>,
    )
    expect(screen.getByTestId('empty')).toBeInTheDocument()
    expect(screen.queryByTestId('list')).not.toBeInTheDocument()
  })

  it('renders the status slot verbatim, with no wrapper to break its full-bleed background', () => {
    const { container } = render(
      <LogSurface chrome={310} status={<div data-testid="banner" />}>{body}</LogSurface>,
    )
    expect(screen.getByTestId('banner').parentElement).toBe(container.querySelector('.card'))
  })
})

describe('LogSearchField', () => {
  it('always has an accessible name, not just a placeholder', () => {
    render(<LogSearchField value="" onChange={() => {}} label="Search payload" placeholder="payload…" />)
    expect(screen.getByRole('textbox', { name: 'Search payload' })).toBeInTheDocument()
  })

  /**
   * The pages branch on `md` (767px) while Tailwind's `sm` is 640px, so a
   * responsive height step here would render 32px between those two widths
   * inside a mobile row whose other controls are all 44px.
   */
  it('keeps one flat 44px height with no responsive step', () => {
    render(<LogSearchField value="" onChange={() => {}} label="Search" placeholder="…" />)
    const input = screen.getByRole('textbox', { name: 'Search' })
    expect(input.className).toContain('h-field')
    expect(input.className).not.toMatch(/sm:h-/)
  })

  it('leaves row sizing to the caller so a fixed width is not fought by a base flex-1', () => {
    render(<LogSearchField className="w-full sm:w-64" value="" onChange={() => {}} label="Search" placeholder="…" />)
    const root = screen.getByRole('textbox', { name: 'Search' }).parentElement!
    expect(root.className).toContain('sm:w-64')
    expect(root.className).not.toContain('flex-1')
  })

  it('reports changes as plain values', async () => {
    const onChange = vi.fn()
    render(<LogSearchField value="" onChange={onChange} label="Search" placeholder="…" />)
    const { default: userEvent } = await import('@testing-library/user-event')
    await userEvent.setup().type(screen.getByRole('textbox', { name: 'Search' }), 'a')
    expect(onChange).toHaveBeenCalledWith('a')
  })
})
