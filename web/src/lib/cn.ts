import { clsx, type ClassValue } from 'clsx'
import { extendTailwindMerge } from 'tailwind-merge'

/**
 * The type and radius scales are named steps (`text-body`, `rounded-card`),
 * not Tailwind's built-in words. tailwind-merge classifies an unknown
 * `text-<word>` as a TEXT COLOUR, so without this it treats `text-body` and
 * `text-[var(--md-sys-color-on-primary)]` as the same class group and drops
 * whichever came first — which silently stripped the colour off every filled
 * button and left it inheriting `on-surface` on a `primary` background.
 *
 * Teaching it the scales keeps size and colour in separate groups, so a
 * component can set one without erasing the other.
 */
const TEXT_STEPS = ['meta', 'label', 'body', 'title', 'headline', 'metric', 'hero'] as const
const RADIUS_STEPS = ['chip', 'ctl', 'card', 'dialog', 'pill'] as const
const SPACING_STEPS = ['chip', 'row', 'ctl', 'field'] as const

const twMerge = extendTailwindMerge({
  extend: {
    classGroups: {
      'font-size': [{ text: [...TEXT_STEPS] }],
      rounded: [{ rounded: [...RADIUS_STEPS] }],
      h: [{ h: [...SPACING_STEPS] }],
      'min-h': [{ 'min-h': [...SPACING_STEPS] }],
      w: [{ w: [...SPACING_STEPS] }],
    },
  },
})

export const cn = (...inputs: ClassValue[]) => twMerge(clsx(inputs))
