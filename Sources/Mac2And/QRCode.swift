import AppKit
import Foundation

/// Minimal QR Code encoder (byte mode, error-correction level M, versions 1–6)
/// plus an AppKit renderer. Versions 1–6 hold up to ~106 bytes, which covers any
/// pairing URL; longer input returns nil (the caller falls back to showing the
/// URL as text). Implemented in Swift so the app does not depend on CoreImage.
///
/// The Reed–Solomon and matrix layout follow the ISO/IEC 18004 algorithm; the
/// generator-polynomial and remainder routines mirror Nayuki's reference design.
enum QRCode {
  // MARK: Public API

  /// Renders `text` as a QR image, or nil if it does not fit in versions 1–6.
  static func image(for text: String, moduleSize: Int = 8, quietZone: Int = 4) -> NSImage? {
    guard let modules = matrix(for: text) else { return nil }
    let count = modules.count
    let pixels = (count + quietZone * 2) * moduleSize
    guard
      pixels > 0,
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      )
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    NSColor.black.setFill()
    for row in 0..<count {
      for col in 0..<count where modules[row][col] {
        let x = (col + quietZone) * moduleSize
        // Bitmap origin is bottom-left; flip so row 0 is at the top.
        let y = (count - 1 - row + quietZone) * moduleSize
        NSRect(x: x, y: y, width: moduleSize, height: moduleSize).fill()
      }
    }
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.addRepresentation(rep)
    return image
  }

  /// The module matrix (`true` = dark), or nil if `text` exceeds version 6.
  static func matrix(for text: String) -> [[Bool]]? {
    let bytes = Array(text.utf8)
    guard let version = chooseVersion(byteCount: bytes.count) else { return nil }
    let data = buildDataCodewords(bytes: bytes, version: version)
    let codewords = interleave(dataCodewords: data, version: version)
    return layout(codewords: codewords, version: version)
  }

  // MARK: Tables (error-correction level M)

  private static let dataCodewordCount = [0, 16, 28, 44, 64, 86, 108]   // by version
  private static let ecPerBlock        = [0, 10, 16, 26, 18, 24, 16]
  private static let blockGroups: [[(blocks: Int, dataPerBlock: Int)]] = [
    [], [(1, 16)], [(1, 28)], [(1, 44)], [(2, 32)], [(2, 43)], [(4, 27)],
  ]
  private static let alignmentCenter = [0, 0, 18, 22, 26, 30, 34]       // 0 = none

  private static func chooseVersion(byteCount: Int) -> Int? {
    for version in 1...6 where 4 + 8 + 8 * byteCount <= dataCodewordCount[version] * 8 {
      return version
    }
    return nil
  }

  // MARK: Data codewords

  private static func buildDataCodewords(bytes: [UInt8], version: Int) -> [UInt8] {
    var bits = BitBuffer()
    bits.append(0b0100, length: 4)            // byte mode
    bits.append(bytes.count, length: 8)       // character count (8 bits, versions 1–9)
    for byte in bytes { bits.append(Int(byte), length: 8) }

    let capacityBits = dataCodewordCount[version] * 8
    bits.append(0, length: min(4, capacityBits - bits.count))   // terminator
    if bits.count % 8 != 0 { bits.append(0, length: 8 - bits.count % 8) }

    var bytesOut = bits.bytes()
    var pad: UInt8 = 0xEC
    while bytesOut.count < dataCodewordCount[version] {
      bytesOut.append(pad)
      pad = pad == 0xEC ? 0x11 : 0xEC
    }
    return bytesOut
  }

  // MARK: Reed–Solomon and block interleaving

  private static func interleave(dataCodewords: [UInt8], version: Int) -> [UInt8] {
    let ecCount = ecPerBlock[version]
    var dataBlocks: [[UInt8]] = []
    var ecBlocks: [[UInt8]] = []
    var index = 0
    for group in blockGroups[version] {
      for _ in 0..<group.blocks {
        let block = Array(dataCodewords[index ..< index + group.dataPerBlock])
        index += group.dataPerBlock
        dataBlocks.append(block)
        ecBlocks.append(reedSolomon(block, ecCount: ecCount))
      }
    }

    var result: [UInt8] = []
    let maxData = dataBlocks.map(\.count).max() ?? 0
    for i in 0..<maxData {
      for block in dataBlocks where i < block.count { result.append(block[i]) }
    }
    for i in 0..<ecCount {
      for block in ecBlocks { result.append(block[i]) }
    }
    return result
  }

  private static func reedSolomon(_ data: [UInt8], ecCount: Int) -> [UInt8] {
    let divisor = generatorPolynomial(degree: ecCount)
    var remainder = [UInt8](repeating: 0, count: ecCount)
    for byte in data {
      let factor = byte ^ remainder.removeFirst()
      remainder.append(0)
      for i in 0..<ecCount { remainder[i] ^= gfMultiply(divisor[i], factor) }
    }
    return remainder
  }

  private static func generatorPolynomial(degree: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: degree)
    result[degree - 1] = 1
    var root: UInt8 = 1
    for _ in 0..<degree {
      for j in 0..<degree {
        result[j] = gfMultiply(result[j], root)
        if j + 1 < degree { result[j] ^= result[j + 1] }
      }
      root = gfMultiply(root, 0x02)
    }
    return result
  }

  /// Carry-less multiply in GF(256) reduced by 0x11D (the QR field polynomial).
  private static func gfMultiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
    var z = 0
    for i in stride(from: 7, through: 0, by: -1) {
      z = (z << 1) ^ ((z >> 7) * 0x11D)
      z ^= Int((y >> i) & 1) * Int(x)
    }
    return UInt8(z & 0xFF)
  }

  // MARK: Matrix layout

  private static func layout(codewords: [UInt8], version: Int) -> [[Bool]] {
    let size = version * 4 + 17
    var modules = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)
    var function = [[Bool]](repeating: [Bool](repeating: false, count: size), count: size)

    func setFunction(_ row: Int, _ col: Int, _ dark: Bool) {
      guard row >= 0, row < size, col >= 0, col < size else { return }
      modules[row][col] = dark
      function[row][col] = true
    }

    // Timing patterns (drawn first; finders overwrite their corners).
    for i in 0..<size {
      setFunction(6, i, i % 2 == 0)
      setFunction(i, 6, i % 2 == 0)
    }

    // Finder patterns + separators (the dist-4 ring is the white separator).
    for center in [(3, 3), (3, size - 4), (size - 4, 3)] {
      for dr in -4...4 {
        for dc in -4...4 {
          let dist = max(abs(dr), abs(dc))
          setFunction(center.0 + dr, center.1 + dc, dist != 2 && dist != 4)
        }
      }
    }

    // Single alignment pattern (versions 2–6 have exactly one not over a finder).
    if version >= 2 {
      let center = alignmentCenter[version]
      for dr in -2...2 {
        for dc in -2...2 {
          setFunction(center + dr, center + dc, max(abs(dr), abs(dc)) != 1)
        }
      }
    }

    // Always-dark module.
    setFunction(size - 8, 8, true)

    // Reserve the format-information modules so data placement skips them.
    let formatCells = formatBitCells(size: size)
    for (a, b) in formatCells { function[a.0][a.1] = true; function[b.0][b.1] = true }

    // Place data bits in the upward/downward zigzag, skipping function modules.
    let bits = bitStream(codewords)
    var bitIndex = 0
    var col = size - 1
    while col >= 1 {
      if col == 6 { col = 5 }                       // skip the vertical timing column
      for vert in 0..<size {
        for j in 0..<2 {
          let c = col - j
          let upward = ((col + 1) & 2) == 0
          let r = upward ? (size - 1 - vert) : vert
          if !function[r][c] {
            if bitIndex < bits.count { modules[r][c] = bits[bitIndex]; bitIndex += 1 }
          }
        }
      }
      col -= 2
    }

    // Try all 8 masks; keep the one with the lowest penalty.
    var best: [[Bool]] = modules
    var bestPenalty = Int.max
    for mask in 0..<8 {
      var candidate = modules
      for r in 0..<size {
        for c in 0..<size where !function[r][c] && maskCondition(r, c, mask) {
          candidate[r][c].toggle()
        }
      }
      applyFormat(&candidate, mask: mask, cells: formatCells)
      let score = penalty(candidate)
      if score < bestPenalty { bestPenalty = score; best = candidate }
    }
    return best
  }

  /// The two physical copies of each of the 15 format bits, indexed by bit.
  private static func formatBitCells(size: Int) -> [(a: (Int, Int), b: (Int, Int))] {
    var copy1: [(Int, Int)] = []
    for i in 0...5 { copy1.append((i, 8)) }
    copy1.append((7, 8)); copy1.append((8, 8)); copy1.append((8, 7))
    for i in 9...14 { copy1.append((8, 14 - i)) }

    var copy2: [(Int, Int)] = []
    for i in 0...7 { copy2.append((8, size - 1 - i)) }
    for i in 8...14 { copy2.append((size - 15 + i, 8)) }

    return (0...14).map { (copy1[$0], copy2[$0]) }
  }

  private static func applyFormat(_ modules: inout [[Bool]], mask: Int, cells: [(a: (Int, Int), b: (Int, Int))]) {
    let data = mask                                  // level M format bits = 0, so value == mask
    var rem = data
    for _ in 0..<10 { rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537) }
    let bits = ((data << 10) | rem) ^ 0x5412         // 15-bit BCH, masked
    for i in 0...14 {
      let dark = (bits >> i) & 1 == 1
      let (a, b) = cells[i]
      modules[a.0][a.1] = dark
      modules[b.0][b.1] = dark
    }
  }

  private static func maskCondition(_ row: Int, _ col: Int, _ mask: Int) -> Bool {
    switch mask {
    case 0: return (row + col) % 2 == 0
    case 1: return row % 2 == 0
    case 2: return col % 3 == 0
    case 3: return (row + col) % 3 == 0
    case 4: return (row / 2 + col / 3) % 2 == 0
    case 5: return (row * col) % 2 + (row * col) % 3 == 0
    case 6: return ((row * col) % 2 + (row * col) % 3) % 2 == 0
    default: return ((row + col) % 2 + (row * col) % 3) % 2 == 0
    }
  }

  // MARK: Penalty scoring

  private static func penalty(_ m: [[Bool]]) -> Int {
    let size = m.count
    var score = 0

    // Rule 1: runs of 5+ same-colored modules in each row and column.
    for i in 0..<size {
      score += runPenalty(m[i])
      score += runPenalty((0..<size).map { m[$0][i] })
    }

    // Rule 2: 2x2 blocks of one color.
    for r in 0..<size - 1 {
      for c in 0..<size - 1 where m[r][c] == m[r][c + 1] && m[r][c] == m[r + 1][c] && m[r][c] == m[r + 1][c + 1] {
        score += 3
      }
    }

    // Rule 3: finder-like 1:1:3:1:1 patterns with four light modules beside them.
    let p1: [Bool] = [true, false, true, true, true, false, true, false, false, false, false]
    let p2 = Array(p1.reversed())
    for i in 0..<size {
      let row = m[i]
      let colVals = (0..<size).map { m[$0][i] }
      for start in 0...(size - 11) {
        if Array(row[start..<start + 11]) == p1 || Array(row[start..<start + 11]) == p2 { score += 40 }
        if Array(colVals[start..<start + 11]) == p1 || Array(colVals[start..<start + 11]) == p2 { score += 40 }
      }
    }

    // Rule 4: deviation of dark-module proportion from 50%.
    let dark = m.reduce(0) { $0 + $1.lazy.filter { $0 }.count }
    let percent = Double(dark) / Double(size * size) * 100
    let prev = Int(floor(percent / 5)) * 5
    let k = min(abs(prev - 50), abs(prev + 5 - 50)) / 5
    score += k * 10

    return score
  }

  private static func runPenalty(_ line: [Bool]) -> Int {
    var score = 0
    var runColor = line[0]
    var runLength = 1
    for i in 1..<line.count {
      if line[i] == runColor {
        runLength += 1
      } else {
        if runLength >= 5 { score += 3 + (runLength - 5) }
        runColor = line[i]
        runLength = 1
      }
    }
    if runLength >= 5 { score += 3 + (runLength - 5) }
    return score
  }

  private static func bitStream(_ codewords: [UInt8]) -> [Bool] {
    var bits: [Bool] = []
    bits.reserveCapacity(codewords.count * 8)
    for byte in codewords {
      for i in stride(from: 7, through: 0, by: -1) { bits.append((byte >> i) & 1 == 1) }
    }
    return bits
  }
}

/// Accumulates bits most-significant-first.
private struct BitBuffer {
  private var bits: [Bool] = []
  var count: Int { bits.count }

  mutating func append(_ value: Int, length: Int) {
    guard length > 0 else { return }
    for i in stride(from: length - 1, through: 0, by: -1) {
      bits.append((value >> i) & 1 == 1)
    }
  }

  func bytes() -> [UInt8] {
    var out: [UInt8] = []
    var current: UInt8 = 0
    var filled = 0
    for bit in bits {
      current = (current << 1) | (bit ? 1 : 0)
      filled += 1
      if filled == 8 { out.append(current); current = 0; filled = 0 }
    }
    if filled > 0 { out.append(current << (8 - filled)) }
    return out
  }
}
