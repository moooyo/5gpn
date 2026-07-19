// Derived from the MIT-licensed FFF686868/proxypin-wloc-spoofer project.
// See THIRD_PARTY_NOTICES.md for attribution and license details.

function concatBytes(parts) {
  let length = 0
  for (const part of parts) length += part.length
  const output = new Uint8Array(length)
  let offset = 0
  for (const part of parts) {
    output.set(part, offset)
    offset += part.length
  }
  return output
}

function bytesEqual(left, right) {
  if (left.length !== right.length) return false
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false
  }
  return true
}

function decodeVarint(bytes, offset) {
  let value = 0n
  for (let index = 0; index < 10; index += 1) {
    if (offset + index >= bytes.length) throw new Error('unexpected end of protobuf varint')
    const byte = bytes[offset + index]
    if (index === 9 && byte > 1) throw new Error('protobuf varint overflows uint64')
    value |= BigInt(byte & 0x7f) << BigInt(7 * index)
    if (byte < 0x80) return { value, length: index + 1 }
  }
  throw new Error('protobuf varint is too long')
}

function encodeVarint(input) {
  let value = BigInt.asUintN(64, input)
  const output = []
  while (value >= 0x80n) {
    output.push(Number(value & 0x7fn) | 0x80)
    value >>= 7n
  }
  output.push(Number(value))
  return new Uint8Array(output)
}

function encodeVarintField(number, value) {
  return concatBytes([encodeVarint(BigInt(number) << 3n), encodeVarint(value)])
}

function encodeLengthField(number, value) {
  return concatBytes([
    encodeVarint((BigInt(number) << 3n) | 2n),
    encodeVarint(BigInt(value.length)),
    value,
  ])
}

function parseFields(bytes) {
  const fields = []
  let offset = 0
  while (offset < bytes.length) {
    const start = offset
    const key = decodeVarint(bytes, offset)
    offset += key.length
    const number = Number(key.value >> 3n)
    const wireType = Number(key.value & 7n)
    if (number === 0) throw new Error('protobuf field number is zero')
    let valueStart = offset
    let valueEnd = offset
    if (wireType === 0) {
      const value = decodeVarint(bytes, offset)
      valueEnd = offset + value.length
    } else if (wireType === 1) {
      valueEnd = offset + 8
    } else if (wireType === 2) {
      const length = decodeVarint(bytes, offset)
      offset += length.length
      valueStart = offset
      valueEnd = offset + Number(length.value)
    } else if (wireType === 5) {
      valueEnd = offset + 4
    } else {
      throw new Error(`unsupported protobuf wire type ${wireType}`)
    }
    if (valueEnd > bytes.length) throw new Error('unexpected end of protobuf field')
    offset = valueEnd
    fields.push({
      number,
      wireType,
      value: bytes.slice(valueStart, valueEnd),
      raw: bytes.slice(start, offset),
    })
  }
  return fields
}

function isMAC(bytes) {
  if (bytes.length !== 17) return false
  for (let index = 0; index < bytes.length; index += 1) {
    const byte = bytes[index]
    if (index % 3 === 2) {
      if (byte !== 58) return false
      continue
    }
    const decimal = byte >= 48 && byte <= 57
    const lower = byte >= 97 && byte <= 102
    const upper = byte >= 65 && byte <= 70
    if (!decimal && !lower && !upper) return false
  }
  return true
}

function patchLocation(bytes, target, stats) {
  const fields = parseFields(bytes)
  const hasLatitude = fields.some((field) => field.number === 1 && field.wireType === 0)
  const hasLongitude = fields.some((field) => field.number === 2 && field.wireType === 0)
  if (!hasLatitude || !hasLongitude) return bytes
  const latitude = BigInt.asUintN(64, BigInt(Math.round(target.latitude * 1e8)))
  const longitude = BigInt.asUintN(64, BigInt(Math.round(target.longitude * 1e8)))
  const parts = fields.map((field) => {
    if (field.number === 1 && field.wireType === 0) return encodeVarintField(1, latitude)
    if (field.number === 2 && field.wireType === 0) return encodeVarintField(2, longitude)
    if (field.number === 3 && field.wireType === 0) return encodeVarintField(3, BigInt(target.accuracy))
    return field.raw
  })
  stats.locations += 1
  return concatBytes(parts)
}

function patchWiFi(bytes, target, stats) {
  const fields = parseFields(bytes)
  if (!fields.some((field) => field.number === 1 && field.wireType === 2 && isMAC(field.value))) return bytes
  let changed = false
  const parts = fields.map((field) => {
    if (field.number !== 2 || field.wireType !== 2) return field.raw
    const patched = patchLocation(field.value, target, stats)
    if (!bytesEqual(patched, field.value)) changed = true
    return encodeLengthField(field.number, patched)
  })
  if (changed) stats.wifi += 1
  return concatBytes(parts)
}

function patchCell(bytes, target, stats) {
  const fields = parseFields(bytes)
  let changed = false
  const parts = fields.map((field) => {
    if (field.number !== 5 || field.wireType !== 2) return field.raw
    const patched = patchLocation(field.value, target, stats)
    if (!bytesEqual(patched, field.value)) changed = true
    return encodeLengthField(field.number, patched)
  })
  if (changed) stats.cell += 1
  return concatBytes(parts)
}

function patchRoot(bytes, target, stats) {
  const fields = parseFields(bytes)
  const parts = fields.map((field) => {
    if (field.number === 2 && field.wireType === 2) {
      return encodeLengthField(field.number, patchWiFi(field.value, target, stats))
    }
    if ((field.number === 22 || field.number === 24) && field.wireType === 2) {
      return encodeLengthField(field.number, patchCell(field.value, target, stats))
    }
    return field.raw
  })
  return concatBytes(parts)
}

function patchFramed(bytes, offset, target, stats) {
  if (offset < 0 || offset + 10 > bytes.length) throw new Error('body is too short for framed WLOC')
  const length = bytes[offset + 8] * 256 + bytes[offset + 9]
  if (length <= 0 || offset + 10 + length > bytes.length) throw new Error('invalid framed WLOC length')
  const payload = bytes.slice(offset + 10, offset + 10 + length)
  const patched = patchRoot(payload, target, stats)
  if (stats.locations === 0 || bytesEqual(payload, patched)) throw new Error('framed payload has no patchable location')
  if (patched.length > 65535) throw new Error('patched framed payload is too large')
  return concatBytes([
    bytes.slice(0, offset + 8),
    new Uint8Array([patched.length >> 8, patched.length & 0xff]),
    patched,
    bytes.slice(offset + 10 + length),
  ])
}

function patchWLOC(bytes, target) {
  if (!(bytes instanceof Uint8Array) || bytes.length === 0) throw new Error('empty WLOC response')
  const offsets = []
  for (const offset of [0, 2, 4, 6, 8, 10, 12, 14, 16]) {
    if (offset + 10 <= bytes.length) offsets.push(offset)
  }
  const framedLimit = Math.min(96, bytes.length - 10)
  for (let offset = 0; offset <= framedLimit; offset += 1) {
    if (!offsets.includes(offset)) offsets.push(offset)
  }
  for (const offset of offsets) {
    const stats = { wifi: 0, cell: 0, locations: 0 }
    try {
      const body = patchFramed(bytes, offset, target, stats)
      return { body, stats }
    } catch (_) {
      // Continue with the next bounded framing candidate.
    }
  }
  const rootLimit = Math.min(256, bytes.length - 1)
  for (let offset = 0; offset <= rootLimit; offset += 1) {
    const stats = { wifi: 0, cell: 0, locations: 0 }
    try {
      const suffix = bytes.slice(offset)
      const patched = patchRoot(suffix, target, stats)
      if (stats.locations > 0 && !bytesEqual(suffix, patched)) {
        return { body: concatBytes([bytes.slice(0, offset), patched]), stats }
      }
    } catch (_) {
      // Continue with the next bounded root candidate.
    }
  }
  throw new Error('no patchable WLOC payload found')
}

function transform(context) {
  const location = context.settings.location
  const failClosed = context.settings.failClosed !== false
  if (!location || location.longitude == null || location.latitude == null) {
    throw new Error('target location is not configured')
  }
  try {
    const patched = patchWLOC(context.response.body, location)
    console.info(`patched locations=${patched.stats.locations} wifi=${patched.stats.wifi} cell=${patched.stats.cell}`)
    return { response: { body: patched.body } }
  } catch (error) {
    if (failClosed) throw error
    console.warn(`skipped WLOC response: ${error}`)
    return null
  }
}
