/**
 * A fixed-capacity circular buffer optimized for appending newest values.
 * Materialization is intentionally explicit so hot-path appends never copy
 * the retained history.
 */
export class BoundedNewestFirstRing<T> {
  private values: Array<T | undefined>
  private nextIndex = 0
  private retained = 0

  constructor(capacity: number) {
    BoundedNewestFirstRing.assertCapacity(capacity)
    this.values = new Array(capacity)
  }

  private static assertCapacity(capacity: number): void {
    if (!Number.isInteger(capacity) || capacity < 1) {
      throw new RangeError('Ring capacity must be a positive integer')
    }
  }

  get capacity(): number {
    return this.values.length
  }

  get size(): number {
    return this.retained
  }

  push(value: T): void {
    this.values[this.nextIndex] = value
    this.nextIndex = (this.nextIndex + 1) % this.capacity
    if (this.retained < this.capacity) this.retained += 1
  }

  resize(capacity: number): void {
    BoundedNewestFirstRing.assertCapacity(capacity)
    if (capacity === this.capacity) return
    const retained = this.toNewestFirst().slice(0, capacity)
    this.values = new Array(capacity)
    this.nextIndex = 0
    this.retained = 0
    for (let index = retained.length - 1; index >= 0; index -= 1) {
      this.push(retained[index])
    }
  }

  toNewestFirst(): T[] {
    const result = new Array<T>(this.retained)
    for (let offset = 0; offset < this.retained; offset += 1) {
      const index = (this.nextIndex - 1 - offset + this.capacity) % this.capacity
      result[offset] = this.values[index] as T
    }
    return result
  }
}
