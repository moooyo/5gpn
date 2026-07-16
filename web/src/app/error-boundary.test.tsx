import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import i18n from '../i18n'
import { ErrorBoundary } from './ErrorBoundary'

function Bomb(): never {
  throw new Error('kaboom')
}

describe('ErrorBoundary', () => {
  it('renders children normally when nothing throws', () => {
    render(
      <ErrorBoundary>
        <div>all good</div>
      </ErrorBoundary>,
    )
    expect(screen.getByText('all good')).toBeInTheDocument()
  })

  it('catches a render error from a descendant and shows the themed fallback with a reload button, instead of crashing the tree', () => {
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    render(
      <ErrorBoundary>
        <Bomb />
      </ErrorBoundary>,
    )

    expect(screen.getByText(i18n.t('common.errorTitle'))).toBeInTheDocument()
    expect(screen.getByText(i18n.t('common.errorBody'))).toBeInTheDocument()
    const reloadBtn = screen.getByRole('button', { name: i18n.t('common.reload') })
    expect(reloadBtn).toBeInTheDocument()

    consoleErrorSpy.mockRestore()
  })

  it('reload button calls window.location.reload', async () => {
    const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const reloadSpy = vi.fn()
    const originalLocation = window.location
    Object.defineProperty(window, 'location', {
      configurable: true,
      value: { ...originalLocation, reload: reloadSpy },
    })

    render(
      <ErrorBoundary>
        <Bomb />
      </ErrorBoundary>,
    )

    screen.getByRole('button', { name: i18n.t('common.reload') }).click()
    expect(reloadSpy).toHaveBeenCalledTimes(1)

    Object.defineProperty(window, 'location', { configurable: true, value: originalLocation })
    consoleErrorSpy.mockRestore()
  })
})
