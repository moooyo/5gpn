import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider, useTheme } from './theme'

function Probe() {
  const { theme, scheme, setTheme } = useTheme()
  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="scheme">{scheme}</span>
      <button onClick={() => setTheme('dark')}>set dark</button>
      <button onClick={() => setTheme('light')}>set light</button>
      <button onClick={() => setTheme('system')}>set system</button>
    </div>
  )
}

beforeEach(() => {
  localStorage.clear()
  delete document.documentElement.dataset.theme
})

afterEach(() => {
  delete document.documentElement.dataset.theme
})

describe('ThemeProvider / useTheme', () => {
  it('defaults to system when nothing is stored', () => {
    render(
      <ThemeProvider>
        <Probe />
      </ThemeProvider>,
    )
    expect(screen.getByTestId('theme').textContent).toBe('system')
  })

  it('setTheme("dark") updates document.documentElement.dataset.theme and persists to localStorage', async () => {
    const user = userEvent.setup()
    render(
      <ThemeProvider>
        <Probe />
      </ThemeProvider>,
    )
    await user.click(screen.getByText('set dark'))
    expect(document.documentElement.dataset.theme).toBe('dark')
    expect(localStorage.getItem('5gpn_theme')).toBe('dark')
    expect(screen.getByTestId('scheme').textContent).toBe('dark')
  })

  it('setTheme("light") updates the dataset attribute and persists', async () => {
    const user = userEvent.setup()
    render(
      <ThemeProvider>
        <Probe />
      </ThemeProvider>,
    )
    await user.click(screen.getByText('set light'))
    expect(document.documentElement.dataset.theme).toBe('light')
    expect(localStorage.getItem('5gpn_theme')).toBe('light')
  })

  it('reads the initial pref from localStorage on mount', () => {
    localStorage.setItem('5gpn_theme', 'dark')
    render(
      <ThemeProvider>
        <Probe />
      </ThemeProvider>,
    )
    expect(screen.getByTestId('theme').textContent).toBe('dark')
    expect(document.documentElement.dataset.theme).toBe('dark')
  })

  it('throws when useTheme is used outside a ThemeProvider', () => {
    // Swallow the expected React error-boundary console.error noise.
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => render(<Probe />)).toThrow(/useTheme must be used within a ThemeProvider/)
    spy.mockRestore()
  })

  it('system pref resolves scheme from matchMedia and listens for changes', () => {
    let changeHandler: (() => void) | undefined
    const mql = {
      matches: true,
      media: '(prefers-color-scheme: dark)',
      addEventListener: (_: string, cb: () => void) => {
        changeHandler = cb
      },
      removeEventListener: () => {},
    }
    const spy = vi.spyOn(window, 'matchMedia').mockReturnValue(mql as unknown as MediaQueryList)

    render(
      <ThemeProvider>
        <Probe />
      </ThemeProvider>,
    )
    expect(screen.getByTestId('scheme').textContent).toBe('dark')

    // Flip the OS preference and fire the listener.
    mql.matches = false
    act(() => {
      changeHandler?.()
    })
    expect(document.documentElement.dataset.theme).toBe('light')

    spy.mockRestore()
  })
})
