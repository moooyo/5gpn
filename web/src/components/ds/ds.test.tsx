import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import {
  Badge,
  Button,
  Card,
  CardBody,
  CardHeader,
  Chip,
  ConfirmDialog,
  DataLine,
  Field,
  Input,
  Label,
  SectionLabel,
  SegmentedControl,
  StatusDot,
  Tabs,
  Toggle,
} from './index'

describe('Button', () => {
  it('renders children and the variant class, and fires onClick', async () => {
    const user = userEvent.setup()
    const onClick = vi.fn()
    render(
      <Button variant="secondary" onClick={onClick}>
        Save
      </Button>,
    )
    const btn = screen.getByRole('button', { name: 'Save' })
    expect(btn.className).toContain('border-outline')
    expect(btn.className).toContain('rounded-full')
    await user.click(btn)
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('blocks click when disabled', async () => {
    const user = userEvent.setup()
    const onClick = vi.fn()
    render(
      <Button disabled onClick={onClick}>
        Save
      </Button>,
    )
    await user.click(screen.getByRole('button', { name: 'Save' }))
    expect(onClick).not.toHaveBeenCalled()
  })
})

describe('Card', () => {
  it('renders Card/CardHeader/CardBody with key classes and content', () => {
    render(
      <Card data-testid="card">
        <CardHeader title="Overview" />
        <CardBody>hello</CardBody>
      </Card>,
    )
    expect(screen.getByTestId('card').className).toContain('zds-card')
    expect(screen.getByText('Overview')).toBeInTheDocument()
    expect(screen.getByText('hello')).toBeInTheDocument()
  })
})

describe('Field', () => {
  it('renders label, control and error text', () => {
    render(
      <Field label="Domain" error="required">
        <Input placeholder="example.com" />
      </Field>,
    )
    expect(screen.getByText('Domain')).toBeInTheDocument()
    expect(screen.getByPlaceholderText('example.com')).toBeInTheDocument()
    expect(screen.getByText('required')).toBeInTheDocument()
  })

  it('Label applies expected class', () => {
    render(<Label>Name</Label>)
    expect(screen.getByText('Name').className).toContain('font-medium')
  })
})

describe('Badge / Chip / StatusDot', () => {
  it('Badge renders children with tone class', () => {
    render(<Badge tone="green">Healthy</Badge>)
    const badge = screen.getByText('Healthy')
    expect(badge.className).toContain('success-container')
  })

  it('Chip renders label + value', () => {
    render(<Chip label="q" value="42" />)
    expect(screen.getByText('q')).toBeInTheDocument()
    expect(screen.getByText('42')).toBeInTheDocument()
  })

  it('StatusDot applies inline color style and pulse class', () => {
    const { container } = render(<StatusDot color="#16a34a" pulse />)
    const dot = container.firstElementChild as HTMLElement
    expect(dot.style.background).toBe('rgb(22, 163, 74)')
    expect(dot.className).toContain('ds-pulse')
  })
})

describe('SegmentedControl', () => {
  it('calls onChange with the clicked option value', async () => {
    const user = userEvent.setup()
    const onChange = vi.fn()
    render(
      <SegmentedControl
        value="a"
        onChange={onChange}
        options={[
          { value: 'a', label: 'A' },
          { value: 'b', label: 'B' },
        ]}
      />,
    )
    await user.click(screen.getByRole('tab', { name: 'B' }))
    expect(onChange).toHaveBeenCalledWith('b')
  })
})

describe('DataLine / SectionLabel', () => {
  it('renders label, sub and the control children', () => {
    render(
      <DataLine label="Cache size" sub="entries">
        <span>1024</span>
      </DataLine>,
    )
    expect(screen.getByText('Cache size')).toBeInTheDocument()
    expect(screen.getByText('entries')).toBeInTheDocument()
    expect(screen.getByText('1024')).toBeInTheDocument()
  })

  it('SectionLabel renders its text', () => {
    render(<SectionLabel>Upstreams</SectionLabel>)
    expect(screen.getByText('Upstreams').className).toContain('tracking-[.06em]')
  })
})

describe('Toggle', () => {
  it('calls onCheckedChange(true) when clicked while unchecked', async () => {
    const user = userEvent.setup()
    const onCheckedChange = vi.fn()
    render(<Toggle checked={false} onCheckedChange={onCheckedChange} aria-label="enable" />)
    const toggle = screen.getByRole('switch')
    expect(toggle.className).toContain('h-8')
    expect(toggle.className).toContain('data-checked:bg-primary')
    await user.click(toggle)
    expect(onCheckedChange).toHaveBeenCalledWith(true)
  })
})

describe('ConfirmDialog', () => {
  it('associates its safety description with the dialog', () => {
    render(
      <ConfirmDialog
        open
        onOpenChange={() => {}}
        title="Open a public port?"
        description="Restrict the source before continuing."
        confirmLabel="Continue"
        cancelLabel="Cancel"
        onConfirm={() => {}}
      />,
    )
    const dialog = screen.getByRole('dialog')
    const descriptionId = dialog.getAttribute('aria-describedby')
    expect(descriptionId).toBeTruthy()
    expect(document.getElementById(descriptionId!)).toHaveTextContent('Restrict the source')
  })
})

describe('Tabs', () => {
  it('calls onValueChange with the clicked trigger value', async () => {
    const user = userEvent.setup()
    const onValueChange = vi.fn()
    render(
      <Tabs
        value="one"
        onValueChange={onValueChange}
        items={[
          { value: 'one', label: 'One' },
          { value: 'two', label: 'Two' },
        ]}
      />,
    )
    await user.click(screen.getByRole('tab', { name: 'Two' }))
    expect(onValueChange).toHaveBeenCalledWith('two')
  })
})
