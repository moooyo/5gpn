import { useState } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { DropdownItem, DropdownMenu, DropdownSeparator, Modal, Select } from './index'

// Count of <style> elements anywhere in the document — the CSP proxy assertion.
// Base UI positioning uses inline style attributes (allowed by style-src-attr),
// while the Select wrapper disables Base UI's optional scrollbar style element.
const styleCount = () => document.querySelectorAll('style').length

describe('Modal', () => {
  it('opens content, locks body scroll, and injects no <style>', async () => {
    const user = userEvent.setup()
    const before = styleCount()

    function Harness() {
      const [open, setOpen] = useState(false)
      return (
        <>
          <button onClick={() => setOpen(true)}>open</button>
          <Modal open={open} onOpenChange={setOpen} title="Confirm">
            <p>body content</p>
          </Modal>
        </>
      )
    }
    render(<Harness />)

    expect(document.body.classList.contains('ds-scroll-locked')).toBe(false)
    await user.click(screen.getByText('open'))
    expect(await screen.findByText('body content')).toBeInTheDocument()
    expect(screen.getByText('Confirm')).toBeInTheDocument()
    expect(document.body.classList.contains('ds-scroll-locked')).toBe(true)
    expect(styleCount()).toBe(before)
  })

  it('closes via the close button and unlocks scroll', async () => {
    const user = userEvent.setup()

    function Harness() {
      const [open, setOpen] = useState(true)
      return (
        <Modal open={open} onOpenChange={setOpen} title="Confirm">
          <p>body content</p>
        </Modal>
      )
    }
    render(<Harness />)

    expect(await screen.findByText('body content')).toBeInTheDocument()
    expect(document.body.classList.contains('ds-scroll-locked')).toBe(true)
    await user.click(screen.getByLabelText('Close'))
    expect(screen.queryByText('body content')).not.toBeInTheDocument()
    expect(document.body.classList.contains('ds-scroll-locked')).toBe(false)
  })
})

describe('Select', () => {
  it('opens on trigger click, shows all option labels, and injects ZERO <style>', async () => {
    const user = userEvent.setup()
    const before = styleCount()
    const onValueChange = vi.fn()

    render(
      <Select
        value="a"
        onValueChange={onValueChange}
        items={[
          { value: 'a', label: 'Alpha' },
          { value: 'b', label: 'Beta' },
        ]}
      />,
    )

    await user.click(screen.getByRole('combobox'))
    expect(await screen.findByRole('option', { name: 'Alpha' })).toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Beta' })).toBeInTheDocument()

    // The DS wrapper sets Base UI's CSPProvider disableStyleElements flag, so
    // the optional scrollbar-hider style never appears under strict CSP.
    expect(styleCount()).toBe(before)
  })

  it('fires onValueChange when an option is picked and the trigger reflects the new label', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()

    function Harness() {
      const [value, setValue] = useState('a')
      return (
        <Select
          value={value}
          onValueChange={(next) => {
            onValueChange(next)
            setValue(next)
          }}
          items={[
            { value: 'a', label: 'Alpha' },
            { value: 'b', label: 'Beta' },
          ]}
        />
      )
    }
    render(<Harness />)

    expect(screen.getByRole('combobox')).toHaveTextContent('Alpha')
    await user.click(screen.getByRole('combobox'))
    await user.click(await screen.findByRole('option', { name: 'Beta' }))
    expect(onValueChange).toHaveBeenCalledWith('b')
    expect(screen.getByRole('combobox')).toHaveTextContent('Beta')
  })
})

describe('DropdownMenu', () => {
  it('opens items, injects no <style>', async () => {
    const user = userEvent.setup()
    const before = styleCount()
    const onSelect = vi.fn()

    render(
      <DropdownMenu trigger={<button>profile</button>}>
        <DropdownItem onSelect={onSelect}>Settings</DropdownItem>
        <DropdownSeparator />
        <DropdownItem danger>Sign out</DropdownItem>
      </DropdownMenu>,
    )

    await user.click(screen.getByText('profile'))
    expect(await screen.findByText('Settings')).toBeInTheDocument()
    expect(screen.getByText('Sign out')).toBeInTheDocument()
    expect(styleCount()).toBe(before)
  })

  it('fires onSelect when an item is picked', async () => {
    const user = userEvent.setup()
    const onSelect = vi.fn()

    render(
      <DropdownMenu trigger={<button>profile</button>}>
        <DropdownItem onSelect={onSelect}>Settings</DropdownItem>
      </DropdownMenu>,
    )

    await user.click(screen.getByText('profile'))
    await user.click(await screen.findByText('Settings'))
    expect(onSelect).toHaveBeenCalledTimes(1)
  })
})
