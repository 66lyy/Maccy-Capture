import Dispatch
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct ScrollingScreenshotStitcher {
  let width: Int
  let frameHeight: Int
  let maximumHeight: Int
  private var chunks: [[UInt8]] = []
  var pixels: [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(width * height * 4)
    for chunk in chunks { result.append(contentsOf: chunk) }
    return result
  }
  private var signatures = RowSignatures()
  private(set) var capReached = false
  private(set) var height = 0

  private struct RowSignatures {
    var values: [UInt8] = []
    var hashes: [[UInt64]] = [[], []]
    var informative: [Bool] = []
  }

  private var binCount: Int { min(width, 256) }

  private struct SignatureBuffers: @unchecked Sendable {
    let bytes: UnsafePointer<UInt8>
    let values: UnsafeMutablePointer<UInt8>
    let firstHashes: UnsafeMutablePointer<UInt64>
    let secondHashes: UnsafeMutablePointer<UInt64>
    let informative: UnsafeMutablePointer<Bool>
  }

  private func rowSignatures(_ rgba: [UInt8]) -> RowSignatures {
    let bins = binCount
    var result = RowSignatures()
    result.values = [UInt8](repeating: 0, count: frameHeight * bins)
    var firstHashes = [UInt64](repeating: 0, count: frameHeight)
    var secondHashes = firstHashes
    result.informative = [Bool](repeating: false, count: frameHeight)
    rgba.withUnsafeBufferPointer { source in
      result.values.withUnsafeMutableBufferPointer { values in
        firstHashes.withUnsafeMutableBufferPointer { first in
          secondHashes.withUnsafeMutableBufferPointer { second in
            result.informative.withUnsafeMutableBufferPointer { informative in
              let buffers = SignatureBuffers(
                bytes: source.baseAddress!, values: values.baseAddress!,
                firstHashes: first.baseAddress!, secondHashes: second.baseAddress!,
                informative: informative.baseAddress!
              )
              let tiles = width * frameHeight >= 1_000_000 ? min(4, frameHeight) : 1
              // Tiles write disjoint rows; concurrentPerform completes before the buffers leave scope.
              DispatchQueue.concurrentPerform(iterations: tiles) { tile in
                Self.fillSignatures(buffers, width: width, bins: bins,
                  rows: (tile * frameHeight / tiles)..<((tile + 1) * frameHeight / tiles))
              }
            }
          }
        }
      }
    }
    result.hashes = [firstHashes, secondHashes]
    return result
  }

  private static func fillSignatures(_ buffers: SignatureBuffers, width: Int, bins: Int, rows: Range<Int>) {
    let bytes = buffers.bytes
    let values = buffers.values
    var y = rows.lowerBound
    while y < rows.upperBound {
      let start = y * bins
      var minimum = 255
      var maximum = 0
      var total = 0
      var bin = 0
      while bin < bins {
        let left = bin * width / bins
        let right = (bin + 1) * width / bins
        var sum = 0
        var offset = (y * width + left) * 4
        let end = (y * width + right) * 4
        while offset < end {
          sum = sum &+ (Int(bytes[offset]) &* 77) &+ (Int(bytes[offset &+ 1]) &* 150)
            &+ (Int(bytes[offset &+ 2]) &* 29)
          offset = offset &+ 4
        }
        let value = sum / ((right - left) * 256)
        values[start + bin] = UInt8(value)
        minimum = min(minimum, value)
        maximum = max(maximum, value)
        total += value
        bin += 1
      }
      let mean = total / bins
      let hashBins = min(bins, 32)
      var firstHash: UInt64 = 14_695_981_039_346_656_037
      var secondHash = firstHash
      bin = 0
      while bin < hashBins {
        let left = bin * bins / hashBins
        let right = (bin + 1) * bins / hashBins
        var sum = 0
        var column = left
        while column < right {
          sum += Int(values[start + column])
          column += 1
        }
        let normalized = sum / (right - left) - mean + 256
        firstHash = (firstHash ^ UInt64(normalized / 16)) &* 1_099_511_628_211
        secondHash = (secondHash ^ UInt64((normalized + 8) / 16)) &* 1_099_511_628_211
        bin += 1
      }
      buffers.firstHashes[y] = firstHash
      buffers.secondHashes[y] = secondHash
      buffers.informative[y] = maximum - minimum >= 8
      y += 1
    }
  }

  private func rowsMatch(_ old: Int, _ new: Int, in next: RowSignatures) -> Bool {
    let bins = binCount
    return signatures.values.withUnsafeBufferPointer { oldBuffer in
      next.values.withUnsafeBufferPointer { newBuffer in
        let lhs = oldBuffer.baseAddress!
        let rhs = newBuffer.baseAddress!
        var a = old * bins
        var b = new * bins
        let end = a + bins
        while a < end {
          let difference = Int(lhs[a]) &- Int(rhs[b])
          if difference > 2 || difference < -2 { return false }
          a = a &+ 1
          b = b &+ 1
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
    if chunks.isEmpty {
      chunks = [rgba]
      height = frameHeight
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
    var removedBytes = footer * stride
    while removedBytes > 0 {
      let last = chunks.count - 1
      let removed = min(removedBytes, chunks[last].count)
      if removed == chunks[last].count {
        chunks.removeLast()
      } else {
        chunks[last].removeLast(removed)
      }
      removedBytes -= removed
    }
    chunks.append(Array(rgba[start..<(start + count * stride)]))
    if footer > 0 { chunks.append(Array(rgba[((frameHeight - footer) * stride)..<rgba.count])) }
    height += count
    signatures = keys
    capReached = height == maximumHeight
    return count > 0
  }
}

#if canImport(CoreGraphics)
extension ScrollingScreenshotStitcher {
  nonisolated mutating func append(_ image: CGImage) -> Bool {
    guard image.width == width, image.height == frameHeight, width > 0, frameHeight > 0,
          width <= Int.max / 4 / frameHeight else { return false }
    var bytes = [UInt8](repeating: 0, count: width * frameHeight * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: frameHeight,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: format) else { return false }
      context.setBlendMode(.copy)
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: frameHeight))
      return true
    }
    return drawn && append(rgba: bytes)
  }

  nonisolated var image: CGImage? {
    guard !chunks.isEmpty else { return nil }
    var data = Data(capacity: width * height * 4)
    for chunk in chunks { data.append(contentsOf: chunk) }
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: format),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  nonisolated func thumbnail(maximumWidth: Int = 264, maximumHeight: Int = 120) -> CGImage? {
    guard !chunks.isEmpty, maximumWidth > 0, maximumHeight > 0 else { return nil }
    let scale = min(1, Double(maximumWidth) / Double(width), Double(maximumHeight) / Double(height))
    let thumbnailWidth = max(1, Int(Double(width) * scale))
    let thumbnailHeight = max(1, Int(Double(height) * scale))
    let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: nil, width: thumbnailWidth, height: thumbnailHeight,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: format)
    else { return nil }
    context.interpolationQuality = .low
    var row = 0
    for chunk in chunks {
      let rows = chunk.count / (width * 4)
      let drawn = chunk.withUnsafeBytes { buffer -> Bool in
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer.baseAddress!, size: buffer.count,
          releaseData: { _, _, _ in }),
          let source = CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: format), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) else { return false }
        let top = Double(row) * Double(thumbnailHeight) / Double(height)
        let bottom = Double(row + rows) * Double(thumbnailHeight) / Double(height)
        context.draw(source, in: CGRect(x: 0, y: Double(thumbnailHeight) - bottom,
          width: Double(thumbnailWidth), height: bottom - top))
        return true
      }
      guard drawn else { return nil }
      row += rows
    }
    return context.makeImage()
  }
}

actor ScrollingScreenshotProcessor {
  struct Update: Sendable {
    let thumbnail: CGImage?
    let width: Int
    let height: Int
    let capReached: Bool
  }

  enum Failure: Error { case invalidFrame }

  private var stitcher: ScrollingScreenshotStitcher?
  private var needsPreview = false

  func append(_ image: CGImage, refreshPreview: Bool, maximumPixels: Int) throws -> Update {
    try Task.checkCancellation()
    if stitcher == nil {
      guard image.width > 0, image.height > 0, image.width <= maximumPixels / image.height else {
        throw Failure.invalidFrame
      }
      stitcher = ScrollingScreenshotStitcher(width: image.width, height: image.height, maximumPixels: maximumPixels)
    }
    let changed = stitcher!.append(image)
    needsPreview = needsPreview || changed
    try Task.checkCancellation()
    let capped = stitcher!.capReached
    let thumbnail = needsPreview && (refreshPreview || capped) ? stitcher!.thumbnail() : nil
    if thumbnail != nil { needsPreview = false }
    return Update(thumbnail: thumbnail, width: stitcher!.width, height: stitcher!.height, capReached: capped)
  }

  func pngData() throws -> Data? {
    try Task.checkCancellation()
    guard let image = stitcher?.image else { return nil }
    let data = ScreenshotAnnotationDocument.RenderSnapshot.pngData(image)
    try Task.checkCancellation()
    return data
  }
}
#endif
