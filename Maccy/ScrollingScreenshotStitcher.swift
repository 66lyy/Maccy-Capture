import Dispatch
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct ScrollingScreenshotStitcher {
  enum AppendResult: Sendable {
    case appended, unchanged, upward, unmatched, capped, invalid
  }

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
  private var lastFrame: RowSignatures?
  private(set) var appendResult = AppendResult.invalid
  private var footerHeight = 0
  private var replacementTailHeight = 0
  private var outputColumns: Range<Int>?
  private(set) var capReached = false
  private(set) var height = 0

  private struct RowSignatures {
    var values: [UInt8] = []
    var hashes: [[UInt64]] = [[], []]
    var informative: [Bool] = []
  }

  private struct RowInformation {
    var hashes: [UInt64]
    var informative: [Bool]
  }

  private var binCount: Int { min(width, 256) }

  private var scrollbarBinCap: Int {
    guard width > 0 else { return 0 }
    return max(1, max(16, width / 50) * binCount / width)
  }

  private var outputPixelColumns: Range<Int> {
    guard binCount > 0 else { return 0..<0 }
    let columns = outputColumns ?? 0..<binCount
    return (columns.lowerBound * width / binCount)..<(columns.upperBound * width / binCount)
  }

  var imageWidth: Int { outputPixelColumns.count }

  private func cornerFooter(in next: RowSignatures, shift: Int, footer: Int) -> Int {
    guard binCount >= 8, frameHeight / 16 >= 3, footer + 3 < frameHeight else { return 0 }
    let edge = max(1, binCount / 16)
    let edges = [0..<edge, (binCount - edge)..<binCount]
    for depth in 0..<3 {
      let row = frameHeight - footer - depth - 1
      let middle = (binCount / 4)..<(binCount * 3 / 4)
      let oldBackground = middle.map { signatures.values[row * binCount + $0] }.sorted()[middle.count / 2]
      let newBackground = middle.map { next.values[row * binCount + $0] }.sorted()[middle.count / 2]
      guard row >= shift, edges.allSatisfy({ columns in
        columns.contains { column in
          abs(Int(signatures.values[row * binCount + column]) - Int(oldBackground)) >= 8
            && abs(Int(next.values[row * binCount + column]) - Int(newBackground)) >= 8
            && rowsMatch(row, row, in: next, columns: column..<(column + 1))
            && !rowsMatch(row, row - shift, in: next, columns: column..<(column + 1))
        }
      }) else { return 0 }
    }
    return min(frameHeight, footer + frameHeight / 16)
  }

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

  private func rowsMatch(_ old: Int, _ new: Int, in next: RowSignatures,
                         previous: RowSignatures? = nil, columns: Range<Int>? = nil) -> Bool {
    let bins = binCount
    let columns = columns ?? 0..<bins
    return (previous ?? signatures).values.withUnsafeBufferPointer { oldBuffer in
      next.values.withUnsafeBufferPointer { newBuffer in
        let lhs = oldBuffer.baseAddress!
        let rhs = newBuffer.baseAddress!
        var a = old * bins + columns.lowerBound
        var b = new * bins + columns.lowerBound
        let end = old * bins + columns.upperBound
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

  private func rowDifferences(in next: RowSignatures, rows: Range<Int>, shift: Int) -> [Int] {
    let bins = binCount
    var differences = [Int](repeating: bins, count: rows.count)
    signatures.values.withUnsafeBufferPointer { old in
      next.values.withUnsafeBufferPointer { new in
        differences.withUnsafeMutableBufferPointer { result in
          for row in rows {
            let a = (row + shift) * bins
            let b = row * bins
            var column = 0
            while column < bins {
              let difference = Int(old[a + column]) - Int(new[b + column])
              if difference > 2 || difference < -2 { break }
              column += 1
            }
            result[row - rows.lowerBound] = column
          }
        }
      }
    }
    return differences
  }

  private func matchingColumns(_ differences: [Int]) -> [Range<Int>] {
    let bins = binCount
    let cap = scrollbarBinCap
    guard bins > cap else { return [] }
    var right = bins
    for column in differences where column >= bins - cap { right = min(right, column) }
    return right < bins ? [0..<right] : []
  }

  private func rowInformation(in next: RowSignatures, columns: Range<Int>) -> RowInformation {
    let bins = binCount
    if columns == 0..<bins { return RowInformation(hashes: next.hashes[0], informative: next.informative) }
    var result = RowInformation(hashes: [UInt64](repeating: 0, count: frameHeight),
      informative: [Bool](repeating: false, count: frameHeight))
    next.values.withUnsafeBufferPointer { values in
      result.hashes.withUnsafeMutableBufferPointer { hashes in
        result.informative.withUnsafeMutableBufferPointer { informative in
          for row in 0..<frameHeight {
            var minimum = 255
            var maximum = 0
            var hash: UInt64 = 14_695_981_039_346_656_037
            var index = row * bins + columns.lowerBound
            let end = row * bins + columns.upperBound
            while index < end {
              let value = values[index]
              minimum = min(minimum, Int(value))
              maximum = max(maximum, Int(value))
              hash = (hash ^ UInt64(value)) &* 1_099_511_628_211
              index += 1
            }
            hashes[row] = hash
            informative[row] = maximum - minimum >= 8
          }
        }
      }
    }
    return result
  }

  private func score(shift: Int, in next: RowSignatures, header: Int, trimmed: Int,
                     differences: [Int], columns: Range<Int>,
                     information: (old: RowInformation, new: RowInformation)) -> (value: Double, header: Int, trimmed: Int)? {
    let end = frameHeight - trimmed - shift
    guard end > header else { return nil }
    let matches = differences.map { $0 >= columns.upperBound }
    var candidateHeader = header
    var cursor = header
    while cursor < end {
      let matched = matches[cursor - header]
      if matched, information.new.informative[cursor] { break }
      if !matched { candidateHeader = cursor + 1 }
      cursor += 1
    }
    if candidateHeader - header > frameHeight / 8 { candidateHeader = header }
    var missed = 0
    var trailingMissed = 0
    for row in candidateHeader..<end {
      if matches[row - header] {
        trailingMissed = 0
      } else {
        missed += 1
        trailingMissed += 1
      }
    }
    let trailing = missed > 0 && trailingMissed == missed && missed <= frameHeight / 4 ? missed : 0
    let candidateTrimmed = trimmed + trailing
    let compared = end - trailing - candidateHeader
    let band = frameHeight - candidateHeader - candidateTrimmed
    let leading = candidateHeader - header
    let overlapHeader = leading > 0 && cursor - header <= frameHeight / 8 ? cursor : candidateHeader
    let overlapBand = frameHeight - overlapHeader - candidateTrimmed
    guard leading + trailing <= frameHeight / 4, leading == 0 || trailing == 0,
          compared >= max(4, band / 3),
          end - trailing - overlapHeader >= max(4, overlapBand / 3) else { return nil }
    var informativeOverlap = 0
    var informativeMasked = 0
    var informativeCompared = 0
    var informativeMatched = 0
    var unmaskedMatches = 0
    var distinctMatches: Set<UInt64> = []
    for row in header..<end {
      let newInformative = information.new.informative[row]
      let informative = newInformative || information.old.informative[row + shift]
      if informative { informativeOverlap += 1 }
      guard row >= candidateHeader, row < end - trailing else {
        if informative { informativeMasked += 1 }
        continue
      }
      if informative {
        informativeCompared += 1
        if matches[row - header] {
          informativeMatched += 1
          if newInformative { distinctMatches.insert(information.new.hashes[row]) }
        }
      }
      if next.informative[row], differences[row - header] == binCount {
        unmaskedMatches += 1
      }
    }
    let changingHeaderBudget = leading > 0 && columns != 0..<binCount
      && informativeMasked * 100 <= informativeOverlap * 43
    guard informativeMasked * 4 <= informativeOverlap || changingHeaderBudget,
          informativeCompared >= max(min(8, end - header), informativeOverlap / 3),
          unmaskedMatches >= min(4, compared),
          distinctMatches.count >= min(4, compared) else { return nil }
    return (Double(informativeMatched) / Double(informativeCompared), candidateHeader, candidateTrimmed)
  }

  private func candidateShifts(in next: RowSignatures, header: Int, end: Int, maximumShift: Int,
                               previous: RowSignatures? = nil) -> Set<Int> {
    let previous = previous ?? signatures
    var candidates: Set<Int> = []
    for grid in 0..<2 {
      var previousRows: [UInt64: [Int]] = [:]
      var newRows: [UInt64: [Int]] = [:]
      for row in header..<end where next.informative[row] {
        newRows[next.hashes[grid][row], default: []].append(row)
      }
      for row in header..<end where previous.informative[row] {
        previousRows[previous.hashes[grid][row], default: []].append(row)
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

  private func isUpwardScroll(from previous: RowSignatures, to next: RowSignatures) -> Bool {
    var header = 0
    while header < frameHeight && rowsMatch(header, header, in: previous, previous: next) { header += 1 }
    var end = frameHeight
    while end > header && rowsMatch(end - 1, end - 1, in: previous, previous: next) { end -= 1 }
    let band = end - header
    let minimumOverlap = max(4, band / 3)
    guard band > minimumOverlap else { return false }
    var bestScore = 0.0
    var runnerUp = 0.0
    for shift in candidateShifts(in: previous, header: header, end: end,
                                 maximumShift: band - minimumOverlap, previous: next) {
      let overlap = band - shift
      var matched = 0
      var distinctMatches: Set<UInt64> = []
      for row in header..<(end - shift) {
        if rowsMatch(row + shift, row, in: previous, previous: next) {
          matched += 1
          if previous.informative[row] { distinctMatches.insert(previous.hashes[0][row]) }
        }
      }
      guard distinctMatches.count >= min(4, overlap) else { continue }
      let score = Double(matched) / Double(overlap)
      if score > bestScore {
        runnerUp = bestScore
        bestScore = score
      } else { runnerUp = max(runnerUp, score) }
    }
    return bestScore >= 0.95 && bestScore - runnerUp >= 0.05
  }

  init(width: Int, height: Int, maximumPixels: Int) {
    self.width = width
    frameHeight = height
    maximumHeight = width > 0 ? maximumPixels / width : 0
  }

  @discardableResult
  mutating func append(rgba: [UInt8]) -> Bool {
    appendResult = .invalid
    if capReached {
      appendResult = .capped
      return false
    }
    guard width > 0, frameHeight > 0, maximumHeight >= frameHeight,
          width <= Int.max / 4 / frameHeight, rgba.count == width * frameHeight * 4,
          !capReached else { return false }
    let keys = rowSignatures(rgba)
    let previousFrame = lastFrame
    var matchesReference = false
    appendResult = .unchanged
    defer {
      lastFrame = keys
      if appendResult != .appended {
        if capReached { appendResult = .capped }
        else if !matchesReference, let previousFrame, previousFrame.values != keys.values {
          appendResult = isUpwardScroll(from: previousFrame, to: keys) ? .upward : .unmatched
        }
      }
    }
    if chunks.isEmpty {
      chunks = [rgba]
      height = frameHeight
      signatures = keys
      capReached = height == maximumHeight
      appendResult = .appended
      return true
    }
    var header = 0
    while header < frameHeight && rowsMatch(header, header, in: keys) { header += 1 }
    guard header < frameHeight else {
      matchesReference = true
      return false
    }
    var footer = 0
    while footer < frameHeight - header
            && rowsMatch(frameHeight - footer - 1, frameHeight - footer - 1, in: keys) {
      footer += 1
    }
    if footer > 0, footer < frameHeight {
      var boundary = frameHeight - footer
      while boundary < frameHeight,
            rowsMatch(boundary, boundary - 1, in: signatures, previous: signatures)
              || rowsMatch(boundary, boundary - 1, in: keys, previous: keys) {
        boundary += 1
      }
      footer = frameHeight - boundary
    }
    var trimmed = max(footerHeight, footer, replacementTailHeight)
    let band = frameHeight - header - trimmed
    let minimumOverlap = max(4, band / 3)
    guard band > minimumOverlap else { return false }
    var bestShift = 0
    var bestHeader = header
    var bestTrimmed = trimmed
    var bestColumns = 0..<binCount
    var bestCorner = 0
    var bestScore = 0.0
    var runnerUp = 0.0
    let fullInformation = (old: rowInformation(in: signatures, columns: 0..<binCount),
      new: rowInformation(in: keys, columns: 0..<binCount))
    var maskedInformation: [Int: (old: RowInformation, new: RowInformation)] = [:]
    for shift in candidateShifts(in: keys, header: header, end: frameHeight - trimmed,
                                 maximumShift: band - minimumOverlap) {
      let corner = cornerFooter(in: keys, shift: shift, footer: footer)
      let candidateTrimmed = max(trimmed, corner)
      guard frameHeight - candidateTrimmed - shift > header else { continue }
      let differences = rowDifferences(in: keys, rows: header..<(frameHeight - candidateTrimmed - shift), shift: shift)
      var candidate = score(shift: shift, in: keys, header: header,
                            trimmed: candidateTrimmed, differences: differences,
                            columns: 0..<binCount, information: fullInformation)
      var candidateColumns = 0..<binCount
      if candidate?.value != 1 || candidate?.header != header || candidate?.trimmed != candidateTrimmed {
        for columns in matchingColumns(differences) {
          let information: (old: RowInformation, new: RowInformation)
          if let cached = maskedInformation[columns.upperBound] { information = cached }
          else {
            information = (old: rowInformation(in: signatures, columns: columns),
              new: rowInformation(in: keys, columns: columns))
            maskedInformation[columns.upperBound] = information
          }
          if let masked = score(shift: shift, in: keys, header: header,
                                trimmed: candidateTrimmed, differences: differences,
                                columns: columns, information: information),
             masked.value > (candidate?.value ?? 0)
              || (masked.value == candidate?.value && (masked.header < (candidate?.header ?? header)
                || (masked.header == candidate?.header && masked.trimmed < (candidate?.trimmed ?? trimmed)))) {
            candidate = masked
            candidateColumns = columns
          }
        }
      }
      guard let candidate else { continue }
      if candidate.value > bestScore {
        runnerUp = bestScore
        bestScore = candidate.value
        bestShift = shift
        bestHeader = candidate.header
        bestTrimmed = candidate.trimmed
        bestColumns = candidateColumns
        bestCorner = corner
      } else { runnerUp = max(runnerUp, candidate.value) }
    }
    guard bestScore >= 0.95, bestScore - runnerUp >= 0.05 else { return false }
    let previousColumns = outputColumns ?? 0..<binCount
    let columns = max(previousColumns.lowerBound, bestColumns.lowerBound)..<min(
      previousColumns.upperBound, bestColumns.upperBound)
    guard columns.lowerBound == 0, binCount - columns.count <= scrollbarBinCap else { return false }
    trimmed = max(bestTrimmed, footer)
    let start = max(bestHeader, frameHeight - trimmed - bestShift)
    if footer > 0, height - trimmed + frameHeight - start > maximumHeight {
      let movesWithBody = ((frameHeight - footer)..<frameHeight).allSatisfy {
        rowsMatch($0, $0 - bestShift, in: keys, previous: keys)
      }
      if movesWithBody { footer = 0 }
    }
    let contentCount = frameHeight - footer - start
    let count = min(contentCount, maximumHeight - (height - trimmed + footer))
    guard count > 0 else {
      capReached = true
      return false
    }
    let stride = width * 4
    var removedBytes = trimmed * stride
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
    chunks.append(Array(rgba[(start * stride)..<((start + count) * stride)]))
    outputColumns = columns
    replacementTailHeight = max(replacementTailHeight, bestCorner)
    if footer > 0 { chunks.append(Array(rgba[((frameHeight - footer) * stride)..<rgba.count])) }
    height = height - trimmed + count + footer
    footerHeight = footer
    signatures = keys
    capReached = count < contentCount || height == maximumHeight
    appendResult = .appended
    return true
  }
}

nonisolated struct ScrollingScreenshotHintState {
  private(set) var consecutiveFailures = 0
  var shouldShowSlowScrollHint: Bool { consecutiveFailures >= 2 }

  mutating func record(_ result: ScrollingScreenshotStitcher.AppendResult) {
    switch result {
    case .unmatched: consecutiveFailures = min(2, consecutiveFailures + 1)
    case .appended, .upward, .capped: consecutiveFailures = 0
    case .unchanged, .invalid: break
    }
  }
}

#if canImport(CoreGraphics)
extension ScrollingScreenshotStitcher {
  nonisolated mutating func append(_ image: CGImage) -> Bool {
    appendResult = .invalid
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
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: format),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    return image?.cropping(to: CGRect(x: outputPixelColumns.lowerBound, y: 0, width: imageWidth, height: height))
  }

  nonisolated func thumbnail(maximumWidth: Int = 264, maximumHeight: Int = 120) -> CGImage? {
    guard !chunks.isEmpty, maximumWidth > 0, maximumHeight > 0 else { return nil }
    let scale = min(1, Double(maximumWidth) / Double(imageWidth), Double(maximumHeight) / Double(height))
    let thumbnailWidth = max(1, Int(Double(imageWidth) * scale))
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
        guard let cropped = source.cropping(to: CGRect(x: outputPixelColumns.lowerBound, y: 0,
          width: imageWidth, height: rows)) else { return false }
        context.draw(cropped, in: CGRect(x: 0, y: Double(thumbnailHeight) - bottom,
          width: Double(thumbnailWidth), height: bottom - top))
        return true
      }
      guard drawn else { return nil }
      row += rows
    }
    return context.makeImage()
  }
}

nonisolated struct ScrollingScreenshotCadence {
  private var unchangedFrames = 0
  var isIdle: Bool { unchangedFrames >= 4 }

  mutating func delay(after result: ScrollingScreenshotStitcher.AppendResult, elapsed: Duration) -> Duration {
    unchangedFrames = result == .unchanged ? min(4, unchangedFrames + 1) : 0
    return max(.milliseconds(5), (isIdle ? .milliseconds(150) : .milliseconds(50)) - max(.zero, elapsed))
  }
}

actor ScrollingScreenshotProcessor {
  struct Update: Sendable {
    let thumbnail: CGImage?
    let width: Int
    let height: Int
    let capReached: Bool
    let showSlowScrollHint: Bool
    let appendResult: ScrollingScreenshotStitcher.AppendResult
  }

  enum Failure: Error { case invalidFrame }

  private var stitcher: ScrollingScreenshotStitcher?
  private var needsPreview = false
  private var hintState = ScrollingScreenshotHintState()

  func append(_ image: CGImage, refreshPreview: Bool, maximumPixels: Int) throws -> Update {
    try Task.checkCancellation()
    if stitcher == nil {
      guard image.width > 0, image.height > 0, image.width <= maximumPixels / image.height else {
        throw Failure.invalidFrame
      }
      stitcher = ScrollingScreenshotStitcher(width: image.width, height: image.height, maximumPixels: maximumPixels)
    }
    let changed = stitcher!.append(image)
    hintState.record(stitcher!.appendResult)
    needsPreview = needsPreview || changed
    try Task.checkCancellation()
    let capped = stitcher!.capReached
    let thumbnail = needsPreview && (refreshPreview || capped) ? stitcher!.thumbnail() : nil
    if thumbnail != nil { needsPreview = false }
    return Update(thumbnail: thumbnail, width: stitcher!.imageWidth, height: stitcher!.height,
      capReached: capped, showSlowScrollHint: hintState.shouldShowSlowScrollHint,
      appendResult: stitcher!.appendResult)
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
