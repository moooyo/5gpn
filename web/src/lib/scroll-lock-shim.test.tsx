import { it, expect } from 'vitest'
import { render } from '@testing-library/react'
import { RemoveScroll } from './scroll-lock-shim'

it('renders children without a wrapper node and toggles the body class', () => {
  const { unmount, container } = render(<RemoveScroll as="div"><p>hi</p></RemoveScroll>)
  // fragment: <p> is a direct child of the render container (no extra wrapper div)
  expect(container.firstElementChild?.tagName).toBe('P')
  expect(document.body.classList.contains('ds-scroll-locked')).toBe(true)
  unmount()
  expect(document.body.classList.contains('ds-scroll-locked')).toBe(false)
})

it('ref-counts nested locks', () => {
  const a = render(<RemoveScroll><span>a</span></RemoveScroll>)
  const b = render(<RemoveScroll><span>b</span></RemoveScroll>)
  expect(document.body.classList.contains('ds-scroll-locked')).toBe(true)
  a.unmount()
  expect(document.body.classList.contains('ds-scroll-locked')).toBe(true) // b still open
  b.unmount()
  expect(document.body.classList.contains('ds-scroll-locked')).toBe(false)
})
