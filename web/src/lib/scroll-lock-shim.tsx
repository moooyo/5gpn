import { useEffect } from 'react'

let lockCount = 0
export function useBodyScrollLock() {
  useEffect(() => {
    lockCount++
    document.body.classList.add('ds-scroll-locked')
    return () => {
      lockCount = Math.max(0, lockCount - 1)
      if (lockCount === 0) document.body.classList.remove('ds-scroll-locked')
    }
  }, [])
}

// Drop-in for react-remove-scroll's <RemoveScroll>. Props-tolerant Fragment:
// accepts and ignores as/allowPinchZoom/shards/enabled/className/forwardProps/etc.
// A Fragment is the DOM-equivalent of Radix's `as={Slot}` (no wrapper node) and,
// crucially, injects NO runtime <style> (which style-src-elem 'self' would block).
export const RemoveScroll = ({ children }: any) => {
  useBodyScrollLock()
  return <>{children}</>
}
// Some code paths reference RemoveScroll.classNames.* — provide inert stubs so a
// member access never throws or breaks the build.
;(RemoveScroll as any).classNames = { fullWidth: '', zeroRight: '' }

export default RemoveScroll
// react-remove-scroll's named surface that consumers might import (all inert here):
export const fullWidthClassName = ''
export const zeroRightClassName = ''
