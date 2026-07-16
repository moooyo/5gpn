import { render, screen, act, waitFor } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import { Toaster, toast } from './toast'

describe('Toaster', () => {
  it('shows a success toast and injects no <style>', async () => {
    const before = document.querySelectorAll('style').length
    render(<Toaster />)
    act(() => {
      toast.success('saved')
    })
    expect(await screen.findByText('saved')).toBeInTheDocument()
    expect(document.querySelectorAll('style').length).toBe(before) // build-time CSS only
  })

  it(
    'auto-dismisses',
    async () => {
      render(<Toaster />)
      act(() => {
        toast.info('bye')
      })
      expect(await screen.findByText('bye')).toBeInTheDocument()
      await waitFor(() => expect(screen.queryByText('bye')).toBeNull(), { timeout: 5000 })
    },
    8000,
  )
})
