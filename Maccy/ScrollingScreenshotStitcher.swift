import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct ScrollingScreenshotStitcher {
  let width: Int
  let frameHeight: Int
  let maximumHeight: Int
  private(set) var pixels: [UInt8] = []
  private var signatures = RowSignatures()
  private(set) var capReached = false
  var height: Int { width > 0 ? pixels.count / (width * 4) : 0 }

  private struct RowSignatures {
    var values: [UInt8] = []
    var hashes: [[UInt64]] = [[], []]
    var informative: [Bool] = []
  }

  private var binCount: Int { min(width, 256) }

  private func rowSignatures(_ rgba: [UInt8]) -> RowSignatures {
    let bins = binCount
    var result = RowSignatures()
    result.values.reserveCapacity(frameHeight * bins)
    rgba.withUnsafeBufferPointer { bytes in
      for y in 0..<frameHeight {
        let start = result.values.count
        var minimum = 255
        var maximum = 0
        var total = 0
        for bin in 0..<bins {
          let left = bin * width / bins
          let right = (bin + 1) * width / bins
          var sum = 0
          var offset = (y * width + left) * 4
          let end = (y * width + right) * 4
          while offset < end {
            sum += Int(bytes[offset]) * 77 + Int(bytes[offset + 1]) * 150 + Int(bytes[offset + 2]) * 29
            offset += 4
          }
          let value = sum / ((right - left) * 256)
          result.values.append(UInt8(value))
          minimum = min(minimum, value)
          maximum = max(maximum, value)
          total += value
        }
        let mean = total / bins
        let hashBins = min(bins, 32)
        for grid in 0..<2 {
          var hash: UInt64 = 14_695_981_039_346_656_037
          for bin in 0..<hashBins {
            let left = bin * bins / hashBins
            let right = (bin + 1) * bins / hashBins
            var sum = 0
            for column in left..<right { sum += Int(result.values[start + column]) }
            let normalized = sum / (right - left) - mean + 256 + grid * 8
            hash = (hash ^ UInt64(normalized / 16)) &* 1_099_511_628_211
          }
          result.hashes[grid].append(hash)
        }
        result.informative.append(maximum - minimum >= 8)
      }
    }
    return result
  }

  private func rowsMatch(_ old: Int, _ new: Int, in next: RowSignatures) -> Bool {
    let bins = binCount
    return signatures.values.withUnsafeBufferPointer { lhs in
      next.values.withUnsafeBufferPointer { rhs in
        var a = old * bins
        var b = new * bins
        let end = a + bins
        while a < end {
          if abs(Int(lhs[a]) - Int(rhs[b])) > 2 { return false }
          a += 1
          b += 1
        }
        return true
      }
    }
  }

  private func candidateShifts(in next: RowSignatures, header: Int, end: Int, maximumShift: Int) -> Set<Int> {
    var candidates: Set<Int> = []
    for grid in 0..<2 {
      var previousRows: [UInt64: [Int]] = [:]
      var newRows: [UInt64: [Int]] = [:]
      for row in header..<end where next.informative[row] {
        newRows[next.hashes[grid][row], default: []].append(row)
      }
      for row in header..<end where signatures.informative[row] {
        previousRows[signatures.hashes[grid][row], default: []].append(row)
      }
      let anchors = (header..<end).filter {
        next.informative[$0] && newRows[next.hashes[grid][$0]]?.count == 1
      }
      guard !anchors.isEmpty else { continue }
      for index in 0..<min(16, anchors.count) {
        let row = anchors[index * anchors.count / min(16, anchors.count)]
        guard let positions = previousRows[next.hashes[grid][row]] else { continue }
        for previousRow in positions {
          let shift = previousRow - row
          if shift > 0, shift <= maximumShift { candidates.insert(shift) }
          if candidates.count > 32 { return [] }
        }
      }
    }
    return candidates
  }

  init(width: Int, height: Int, maximumPixels: Int) {
    self.width = width
    frameHeight = height
    maximumHeight = width > 0 ? maximumPixels / width : 0
  }

  @discardableResult
  mutating func append(rgba: [UInt8]) -> Bool {
    guard width > 0, frameHeight > 0, maximumHeight >= frameHeight,
          width <= Int.max / 4 / frameHeight, rgba.count == width * frameHeight * 4,
          !capReached else { return false }
    let keys = rowSignatures(rgba)
    if pixels.isEmpty {
      pixels = rgba
      signatures = keys
      capReached = height == maximumHeight
      return true
    }
    var header = 0
    while header < frameHeight && rowsMatch(header, header, in: keys) { header += 1 }
    guard header < frameHeight else { return false }
    var footer = 0
    while footer < frameHeight - header
            && rowsMatch(frameHeight - footer - 1, frameHeight - footer - 1, in: keys) {
      footer += 1
    }
    let band = frameHeight - header - footer
    let minimumOverlap = max(4, band / 3)
    guard band > minimumOverlap else { return false }
    var bestShift = 0
    var bestScore = 0.0
    var runnerUp = 0.0
    for shift in candidateShifts(in: keys, header: header, end: frameHeight - footer,
                                 maximumShift: band - minimumOverlap) {
      let overlap = band - shift
      var matched = 0
      var missed = 0
      var distinctMatches: Set<UInt64> = []
      for row in header..<(frameHeight - footer - shift) {
        if rowsMatch(row + shift, row, in: keys) {
          matched += 1
          if keys.informative[row] { distinctMatches.insert(keys.hashes[0][row]) }
        } else { missed += 1 }
        if missed > overlap / 10 { break }
      }
      guard distinctMatches.count >= min(4, overlap) else { continue }
      let score = Double(matched) / Double(overlap)
      if score > bestScore {
        runnerUp = bestScore
        bestScore = score
        bestShift = shift
      } else { runnerUp = max(runnerUp, score) }
    }
    guard bestScore >= 0.95, bestScore - runnerUp >= 0.05 else { return false }
    let count = min(bestShift, maximumHeight - height)
    let stride = width * 4
    let start = (frameHeight - footer - bestShift) * stride
    pixels.removeLast(footer * stride)
    pixels.append(contentsOf: rgba[start..<(start + count * stride)])
    pixels.append(contentsOf: rgba[((frameHeight - footer) * stride)..<rgba.count])
    signatures = keys
    capReached = height == maximumHeight
    return count > 0
  }
}

#if canImport(CoreGraphics)
extension ScrollingScreenshotStitcher {
  mutating func append(_ image: CGImage) -> Bool {
    guard image.width == width, image.height == frameHeight, width > 0, frameHeight > 0,
          width <= Int.max / 4 / frameHeight else { return false }
    var bytes = [UInt8](repeating: 0, count: width * frameHeight * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: frameHeight,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: format) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: frameHeight))
      return true
    }
    return drawn && append(rgba: bytes)
  }

  var image: CGImage? {
    guard !pixels.isEmpty, let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
    let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: format),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }
}
#endif
