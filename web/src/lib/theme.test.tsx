import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider, useTheme, type ThemeName } from './theme'

function Probe() {
  const { theme, scheme, setTheme } = useTheme()
  const choices: ThemeName[] = ['light', 'dark', 'ocean', 'forest', 'violet']
  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="scheme">{scheme}</span>
      {choices.map((choice) => <button key={choice} onClick={() => setTheme(choice)}>set {choice}</button>)}
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
  it('defaults to the required light theme', () => {
    render(<ThemeProvider><Probe /></ThemeProvider>)
    expect(screen.getByTestId('theme').textContent).toBe('light')
    expect(screen.getByTestId('scheme').textContent).toBe('light')
  })

  it.each(['dark', 'ocean', 'forest', 'violet'] as const)('applies and persists the %s theme', async (theme) => {
    const user = userEvent.setup()
    render(<ThemeProvider><Probe /></ThemeProvider>)
    await user.click(screen.getByText(`set ${theme}`))
    expect(document.documentElement.dataset.theme).toBe(theme)
    expect(localStorage.getItem('5gpn_theme')).toBe(theme)
    expect(screen.getByTestId('scheme').textContent).toBe(theme === 'dark' ? 'dark' : 'light')
  })

  it('reads a valid initial theme and rejects retired values', () => {
    localStorage.setItem('5gpn_theme', 'system')
    const { unmount } = render(<ThemeProvider><Probe /></ThemeProvider>)
    expect(screen.getByTestId('theme').textContent).toBe('light')
    unmount()

    localStorage.setItem('5gpn_theme', 'forest')
    render(<ThemeProvider><Probe /></ThemeProvider>)
    expect(screen.getByTestId('theme').textContent).toBe('forest')
  })

  it('throws when useTheme is used outside a ThemeProvider', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    expect(() => render(<Probe />)).toThrow(/useTheme must be used within a ThemeProvider/)
    spy.mockRestore()
  })
})
