import '@testing-library/jest-dom/vitest'

// Node 22+'s built-in (experimental, opt-in) global `localStorage` accessor
// shadows jsdom's real implementation before it ever gets a chance to run —
// accessing it just warns "--localstorage-file was not provided" and
// evaluates to `undefined`, which breaks every test that touches
// localStorage. Replace it with a minimal in-memory Storage polyfill so
// getItem/setItem/removeItem/clear behave like a real browser.
if (typeof globalThis !== 'undefined' && typeof globalThis.localStorage === 'undefined') {
  class MemoryStorage implements Storage {
    private store = new Map<string, string>()
    get length(): number {
      return this.store.size
    }
    clear(): void {
      this.store.clear()
    }
    getItem(key: string): string | null {
      return this.store.has(key) ? this.store.get(key)! : null
    }
    key(index: number): string | null {
      return Array.from(this.store.keys())[index] ?? null
    }
    removeItem(key: string): void {
      this.store.delete(key)
    }
    setItem(key: string, value: string): void {
      this.store.set(key, String(value))
    }
  }
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    enumerable: true,
    value: new MemoryStorage(),
  })
}

// jsdom does not implement window.matchMedia — provide a minimal stub so
// components that call it in useEffect do not throw.
if (typeof window !== 'undefined' && !window.matchMedia) {
  Object.defineProperty(window, 'matchMedia', {
    writable: true,
    value: (query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      dispatchEvent: () => false,
    }),
  })
}

// jsdom does not implement ResizeObserver — Radix UI primitives (Dialog, Select, etc.) need it.
if (typeof window !== 'undefined' && !window.ResizeObserver) {
  class ResizeObserverStub {
    observe() {}
    unobserve() {}
    disconnect() {}
  }
  Object.defineProperty(window, 'ResizeObserver', {
    writable: true,
    value: ResizeObserverStub,
  })
}

// jsdom does not implement the Pointer Capture API or scrollIntoView — Radix
// Select's pointer-interaction handlers (and its "scroll the highlighted item
// into view on open") call these directly and throw a TypeError without them.
if (typeof Element !== 'undefined') {
  if (!Element.prototype.hasPointerCapture) {
    Element.prototype.hasPointerCapture = () => false
  }
  if (!Element.prototype.setPointerCapture) {
    Element.prototype.setPointerCapture = () => {}
  }
  if (!Element.prototype.releasePointerCapture) {
    Element.prototype.releasePointerCapture = () => {}
  }
  if (!Element.prototype.scrollIntoView) {
    Element.prototype.scrollIntoView = () => {}
  }
}
