import Dispatch
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

nonisolated struct ScrollingScreenshotStitcher {
  enum AppendResult: Sendable {
    case appended, reanchored, unchanged, upward, unmatched, capped, invalid
  }

  let width: Int
  let frameHeight: Int
  let maximumHeight: Int
  private(set) var chunks: [[UInt8]] = []
  #if canImport(CoreGraphics)
  private var sourceColorSpace: CGColorSpace?
  #endif
  private var signatures = RowSignatures()
  private var lastFrame: RowSignatures?
  private(set) var appendResult = AppendResult.invalid
  private(set) var matchedShift: Int?
  private(set) var maximumMatchableShift: Int
  private var footerHeight = 0
  private var replacementTailHeight = 0
  private var outputColumns: Range<Int>?
  private(set) var capReached = false
  private(set) var height = 0
  private(set) var isLost = false
  private var failedFrames = 0
  private var referenceHeight = 0
  private var recoveryProbe = false
  private var anchors: [Anchor] = []

  private struct Anchor {
    let signatures: RowSignatures
    let height: Int
    let footer: Int
    let tail: Int
  }

  private var anchor: Anchor {
    Anchor(signatures: signatures, height: referenceHeight, footer: footerHeight, tail: replacementTailHeight)
  }

  private mutating func rememberAnchor() {
    anchors.removeAll { $0.height < height - frameHeight * 3 }
    if anchors.last.map({ referenceHeight - $0.height >= max(1, frameHeight / 6) }) ?? true {
      anchors.append(anchor)
    }
  }

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

  static func removeTail(byteCount: Int, from chunks: inout [[UInt8]]) -> Bool {
    guard byteCount >= 0, chunks.reduce(0, { $0 + $1.count }) >= byteCount else { return false }
    var remaining = byteCount
    while remaining > 0, let last = chunks.indices.last {
      let count = min(remaining, chunks[last].count)
      if count == chunks[last].count { chunks.removeLast() }
      else { chunks[last].removeLast(count) }
      remaining -= count
    }
    return remaining == 0
  }

  private func hasStaticEdges(in next: RowSignatures, footer: Int, shift: Int? = nil) -> Bool {
    guard binCount >= 8, frameHeight / 16 >= 3, footer + 3 < frameHeight else { return false }
    let edge = max(1, binCount / 16)
    let edges = [0..<edge, (binCount - edge)..<binCount]
    var currentEvidence = [false, false]
    for depth in 0..<3 {
      let row = frameHeight - footer - depth - 1
      let middle = (binCount / 4)..<(binCount * 3 / 4)
      let oldBackground = middle.map { signatures.values[row * binCount + $0] }.sorted()[middle.count / 2]
      let newBackground = middle.map { next.values[row * binCount + $0] }.sorted()[middle.count / 2]
      guard row >= (shift ?? 0), edges.enumerated().allSatisfy({ index, columns in
        columns.contains { column in
          let oldContrast = abs(Int(signatures.values[row * binCount + column]) - Int(oldBackground)) >= 8
          let newContrast = abs(Int(next.values[row * binCount + column]) - Int(newBackground)) >= 8
          let matches = rowsMatch(row, row, in: next, columns: column..<(column + 1))
          if newContrast && matches { currentEvidence[index] = true }
          return (shift == nil ? oldContrast || newContrast : oldContrast && newContrast) && matches
            && (shift.map { !rowsMatch(row, row - $0, in: next, columns: column..<(column + 1)) } ?? true)
        }
      }) else { return false }
    }
    return shift != nil || currentEvidence.allSatisfy { $0 }
  }

  private func cornerFooter(in next: RowSignatures, shift: Int, footer: Int) -> Int {
    guard hasStaticEdges(in: next, footer: footer, shift: shift) else { return 0 }
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
    normalizeLowContrast(&result)
    return result
  }

  private func normalizeLowContrast(_ result: inout RowSignatures) {
    let bins = binCount
    let columns = (bins / 16)..<(bins - bins / 16)
    var minimum = 255
    var maximum = 0
    for row in (frameHeight / 8)..<(frameHeight * 3 / 4) {
      for column in columns {
        let value = Int(result.values[row * bins + column])
        minimum = min(minimum, value)
        maximum = max(maximum, value)
      }
    }
    guard maximum > minimum, maximum - minimum < 8 else { return }
    for index in result.values.indices {
      result.values[index] = UInt8(clamping: (Int(result.values[index]) - minimum) * 16)
    }
    for row in 0..<frameHeight {
      let start = row * bins
      let values = result.values[start..<(start + bins)]
      let mean = values.reduce(0, { $0 + Int($1) }) / bins
      let hashBins = min(bins, 32)
      var hashes = [UInt64](repeating: 14_695_981_039_346_656_037, count: 2)
      for bin in 0..<hashBins {
        let left = bin * bins / hashBins
        let right = (bin + 1) * bins / hashBins
        let value = result.values[(start + left)..<(start + right)].reduce(0, { $0 + Int($1) })
          / (right - left) - mean + 256
        hashes[0] = (hashes[0] ^ UInt64(value / 16)) &* 1_099_511_628_211
        hashes[1] = (hashes[1] ^ UInt64((value + 8) / 16)) &* 1_099_511_628_211
      }
      result.hashes[0][row] = hashes[0]
      result.hashes[1][row] = hashes[1]
      result.informative[row] = Int(values.max()!) - Int(values.min()!) >= 8
    }
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
          informativeMatched >= min(leading + trailing > 0 ? 8 : 4, compared),
          unmaskedMatches >= min(4, compared),
          distinctMatches.count >= min(4, compared) else { return nil }
    return (Double(informativeMatched) / Double(informativeCompared), candidateHeader, candidateTrimmed)
  }

  private func candidateShifts(in next: RowSignatures, header: Int, end: Int, maximumShift: Int,
                               previous: RowSignatures? = nil) -> Set<Int> {
    let previous = previous ?? signatures
    var votes: [Int: Int] = [:]
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
          if shift > 0, shift <= maximumShift { votes[shift, default: 0] += 1 }
        }
      }
    }
    return Self.rankedCandidateShifts(votes)
  }

  static func rankedCandidateShifts(_ votes: [Int: Int]) -> Set<Int> {
    Set(votes.sorted {
      $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
    }.prefix(32).map(\.key))
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
    maximumMatchableShift = max(0, height - max(4, height / 3))
  }

  @discardableResult
  mutating func append(rgba: [UInt8]) -> Bool {
    var wasUpward = false
    if !isLost {
      let changed = appendForward(rgba: rgba)
      if appendResult == .appended {
        failedFrames = 0
        rememberAnchor()
        return changed
      }
      if appendResult == .reanchored {
        failedFrames = 0
        return false
      }
      if appendResult == .unmatched { failedFrames = min(2, failedFrames + 1) }
      else if appendResult == .upward { failedFrames = 0 }
      guard !capReached, appendResult == .unmatched || appendResult == .upward else { return false }
      wasUpward = appendResult == .upward
      if failedFrames == 2 { isLost = true }
    } else {
      matchedShift = nil
      guard width > 0, frameHeight > 0, width <= Int.max / 4 / frameHeight,
            rgba.count == width * frameHeight * 4 else {
        appendResult = .invalid
        return false
      }
      let next = rowSignatures(rgba)
      if lastFrame?.values == next.values {
        appendResult = .unchanged
        return false
      }
      appendResult = .unmatched
      lastFrame = next
    }
    guard let next = lastFrame else { return false }
    var recovered: Self?
    for anchor in anchors + [self.anchor] {
      var probe = self
      probe.signatures = anchor.signatures
      probe.footerHeight = anchor.footer
      probe.replacementTailHeight = anchor.tail
      probe.referenceHeight = anchor.height
      probe.recoveryProbe = true
      probe.lastFrame = nil
      _ = probe.appendForward(rgba: rgba, keys: next)
      guard probe.appendResult == .reanchored else { continue }
      if let recovered, recovered.referenceHeight != probe.referenceHeight { return false }
      recovered = probe
    }
    guard let recovered else { return false }
    signatures = recovered.signatures
    footerHeight = recovered.footerHeight
    replacementTailHeight = recovered.replacementTailHeight
    referenceHeight = recovered.referenceHeight
    maximumMatchableShift = recovered.maximumMatchableShift
    matchedShift = nil
    failedFrames = 0
    isLost = false
    appendResult = wasUpward ? .upward : .reanchored
    return false
  }

  @discardableResult
  private mutating func appendForward(rgba: [UInt8], keys suppliedKeys: RowSignatures? = nil) -> Bool {
    appendResult = .invalid
    matchedShift = nil
    if capReached {
      appendResult = .capped
      return false
    }
    guard width > 0, frameHeight > 0, maximumHeight >= frameHeight,
          width <= Int.max / 4 / frameHeight, rgba.count == width * frameHeight * 4,
          !capReached else { return false }
    let keys = suppliedKeys ?? rowSignatures(rgba)
    let previousFrame = lastFrame
    var matchesReference = false
    appendResult = .unchanged
    defer {
      lastFrame = keys
      if appendResult != .appended && appendResult != .reanchored {
        if capReached { appendResult = .capped }
        else if !matchesReference, let previousFrame, previousFrame.values != keys.values {
          appendResult = isUpwardScroll(from: previousFrame, to: keys) ? .upward : .unmatched
        }
      }
    }
    if chunks.isEmpty {
      chunks = [rgba]
      height = frameHeight
      referenceHeight = height
      signatures = keys
      capReached = height == maximumHeight
      appendResult = .appended
      return true
    }
    var header = 0
    while header < frameHeight && rowsMatch(header, header, in: keys) { header += 1 }
    guard header < frameHeight else {
      matchesReference = true
      let informativeRows = keys.informative.indices.filter { keys.informative[$0] }
      if recoveryProbe, informativeRows.count >= min(8, frameHeight),
         Set(informativeRows.map { keys.hashes[0][$0] }).count >= min(4, frameHeight) {
        appendResult = .reanchored
      }
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
    maximumMatchableShift = max(0, band - minimumOverlap)
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
    var start = max(bestHeader, frameHeight - trimmed - bestShift)
    if footer > 0, height - trimmed + frameHeight - start > maximumHeight {
      let movesWithBody = ((frameHeight - footer)..<frameHeight).allSatisfy {
        rowsMatch($0, $0 - bestShift, in: keys, previous: keys)
      }
      if movesWithBody { footer = 0 }
    }
    let nextReferenceHeight = referenceHeight - trimmed + frameHeight - start
    let nextTail = max(bestCorner, hasStaticEdges(in: keys, footer: footer) ? replacementTailHeight : 0)
    if recoveryProbe || nextReferenceHeight <= height {
      signatures = keys
      referenceHeight = nextReferenceHeight
      footerHeight = footer
      replacementTailHeight = nextTail
      appendResult = .reanchored
      return false
    }
    start += height - referenceHeight
    guard start >= bestHeader, start < frameHeight - footer else { return false }
    let contentCount = frameHeight - footer - start
    let count = min(contentCount, maximumHeight - (height - trimmed + footer))
    guard count > 0 else {
      capReached = true
      return false
    }
    let stride = width * 4
    guard Self.removeTail(byteCount: trimmed * stride, from: &chunks) else {
      appendResult = .invalid
      return false
    }
    chunks.append(Array(rgba[(start * stride)..<((start + count) * stride)]))
    outputColumns = columns
    replacementTailHeight = nextTail
    if footer > 0 { chunks.append(Array(rgba[((frameHeight - footer) * stride)..<rgba.count])) }
    height = height - trimmed + count + footer
    referenceHeight = height
    footerHeight = footer
    signatures = keys
    capReached = count < contentCount || height == maximumHeight
    matchedShift = bestShift
    appendResult = .appended
    return true
  }
}

nonisolated struct ScrollingScreenshotHintState {
  enum Warning: Sendable { case normal, tooFast, lostTrack }

  private(set) var consecutiveFailures = 0
  private(set) var warning = Warning.normal
  private var fastFrames = 0
  private var calmFrames = 0
  private var unchangedSince: Duration?
  var shouldShowSlowScrollHint: Bool { warning != .normal }

  mutating func record(_ result: ScrollingScreenshotStitcher.AppendResult,
                       shift: Int? = nil, maximumShift: Int = 0, now: Duration = .zero) {
    if result != .unchanged { unchangedSince = nil }
    switch result {
    case .unmatched:
      fastFrames = 0
      calmFrames = 0
      consecutiveFailures = min(2, consecutiveFailures + 1)
      if consecutiveFailures == 2 { warning = .lostTrack }
    case .appended:
      consecutiveFailures = 0
      if warning == .lostTrack { warning = .normal }
      guard let shift, shift > 0, maximumShift > 0 else { return }
      let fraction = Double(shift) / Double(maximumShift)
      fastFrames = fraction > 0.7 ? fastFrames + 1 : 0
      calmFrames = fraction < 0.5 ? calmFrames + 1 : 0
      if fraction > 0.85 || fastFrames >= 2 { warning = .tooFast }
      else if calmFrames >= 3 { warning = .normal }
    case .reanchored, .capped:
      self = Self()
    case .upward:
      consecutiveFailures = 0
      fastFrames = 0
      calmFrames = 0
    case .unchanged:
      if unchangedSince == nil { unchangedSince = now }
      if warning == .tooFast, let unchangedSince, now - unchangedSince >= .seconds(1) {
        warning = .normal
        fastFrames = 0
        calmFrames = 0
      }
    case .invalid: break
    }
  }
}

#if canImport(CoreGraphics)
extension ScrollingScreenshotStitcher {
  nonisolated mutating func append(_ image: CGImage) -> Bool {
    appendResult = .invalid
    matchedShift = nil
    guard image.width == width, image.height == frameHeight, width > 0, frameHeight > 0,
          width <= Int.max / 4 / frameHeight else { return false }
    let colorSpace = chunks.isEmpty ? ScreenshotColorSpace.rgb(image.colorSpace) : outputColorSpace
    var bytes = [UInt8](repeating: 0, count: width * frameHeight * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
      guard let context = CGContext(data: buffer.baseAddress, width: width, height: frameHeight,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: format) else { return false }
      context.setBlendMode(.copy)
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: frameHeight))
      return true
    }
    guard drawn, append(rgba: bytes) else { return false }
    sourceColorSpace = colorSpace
    return true
  }

  private nonisolated var outputColorSpace: CGColorSpace { sourceColorSpace ?? CGColorSpaceCreateDeviceRGB() }

  nonisolated var image: CGImage? {
    var copy = self
    return try? copy.takeImage(rows: 0..<height)
  }

  nonisolated mutating func takeImage(rows: Range<Int>) throws -> CGImage? {
    let columns = outputPixelColumns
    guard !chunks.isEmpty, !columns.isEmpty, !rows.isEmpty, rows.lowerBound >= 0, rows.upperBound <= height
    else { return nil }
    defer { chunks.removeAll() }
    let sourceStride = width * 4
    let stride = columns.count * 4
    let byteCount = stride * rows.count
    let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<UInt32>.alignment)
    var ownsPixels = true
    defer { if ownsPixels { pixels.deallocate() } }
    var row = 0
    for index in chunks.indices {
      try Task.checkCancellation()
      let chunk = chunks[index]
      chunks[index] = []
      let start = row
      row += chunk.count / sourceStride
      guard let overlap = (start..<row).overlap(with: rows) else { continue }
      chunk.withUnsafeBytes { buffer in
        let source = buffer.baseAddress! + (overlap.lowerBound - start) * sourceStride + columns.lowerBound * 4
        let target = pixels + (overlap.lowerBound - rows.lowerBound) * stride
        if stride == sourceStride {
          target.copyMemory(from: source, byteCount: overlap.count * stride)
        } else {
          for rowIndex in 0..<overlap.count {
            (target + rowIndex * stride).copyMemory(from: source + rowIndex * sourceStride, byteCount: stride)
          }
        }
      }
    }
    guard row >= rows.upperBound, let provider = CGDataProvider(dataInfo: nil, data: pixels, size: byteCount,
      releaseData: { _, bytes, _ in UnsafeMutableRawPointer(mutating: bytes).deallocate() }) else { return nil }
    ownsPixels = false
    let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    return CGImage(width: columns.count, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: stride, space: outputColorSpace, bitmapInfo: CGBitmapInfo(rawValue: format),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  }

  nonisolated private enum ImageBytes {
    static func chunkEnds(_ chunks: [[UInt8]]) -> [Int] {
      var end = 0
      return chunks.map {
        end += $0.count
        return end
      }
    }

    static func read(_ buffer: UnsafeMutableRawPointer, chunks: [[UInt8]], ends: [Int],
                     offset: Int, count: Int) -> Int {
      guard offset >= 0, count > 0 else { return 0 }
      var low = 0
      var high = ends.count
      while low < high {
        let middle = low + (high - low) / 2
        if ends[middle] <= offset { low = middle + 1 }
        else { high = middle }
      }
      var copied = 0
      for index in low..<ends.count {
        let position = offset + copied
        let start = index == 0 ? 0 : ends[index - 1]
        let size = min(count - copied, ends[index] - position)
        guard size > 0 else { continue }
        chunks[index].withUnsafeBytes { bytes in
          buffer.advanced(by: copied).copyMemory(from: bytes.baseAddress! + (position - start), byteCount: size)
        }
        copied += size
        if copied == count { break }
      }
      return copied
    }
  }

  nonisolated func thumbnail(maximumWidth: Int = 264, maximumHeight: Int = 120,
                             rows: Range<Int>? = nil) -> CGImage? {
    let rows = rows ?? 0..<height
    guard !chunks.isEmpty, !rows.isEmpty, maximumWidth > 0, maximumHeight > 0 else { return nil }
    let scale = min(1, Double(maximumWidth) / Double(imageWidth), Double(maximumHeight) / Double(rows.count))
    let thumbnailWidth = max(1, Int(Double(imageWidth) * scale))
    let thumbnailHeight = max(1, Int(Double(rows.count) * scale))
    let colorSpace = outputColorSpace
    let format = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(data: nil, width: thumbnailWidth, height: thumbnailHeight,
      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: format)
    else { return nil }
    context.interpolationQuality = .low
    var row = 0
    for chunk in chunks {
      let chunkStart = row
      let chunkHeight = chunk.count / (width * 4)
      row += chunkHeight
      guard let overlap = (chunkStart..<row).overlap(with: rows) else { continue }
      let drawn = chunk.withUnsafeBytes { buffer -> Bool in
        guard let provider = CGDataProvider(dataInfo: nil, data: buffer.baseAddress!, size: buffer.count,
          releaseData: { _, _, _ in }),
          let source = CGImage(width: width, height: chunkHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: format), provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent) else { return false }
        let top = Double(overlap.lowerBound - rows.lowerBound) * Double(thumbnailHeight) / Double(rows.count)
        let bottom = Double(overlap.upperBound - rows.lowerBound) * Double(thumbnailHeight) / Double(rows.count)
        guard let cropped = source.cropping(to: CGRect(x: outputPixelColumns.lowerBound,
          y: overlap.lowerBound - chunkStart, width: imageWidth, height: overlap.count)) else { return false }
        context.draw(cropped, in: CGRect(x: 0, y: Double(thumbnailHeight) - bottom,
          width: Double(thumbnailWidth), height: bottom - top))
        return true
      }
      guard drawn else { return nil }
    }
    return context.makeImage()
  }

  nonisolated mutating func applyMosaic(_ edit: ScrollingScreenshotEdit) throws {
    guard !edit.cells.isEmpty else { return }
    let stride = width * 4
    let columnOffset = outputPixelColumns.lowerBound
    let ends = ImageBytes.chunkEnds(chunks)
    let groups = Dictionary(grouping: edit.cells, by: \.y).sorted { $0.key < $1.key }
    var chunkIndex = 0
    for (tileRow, cells) in groups {
      try Task.checkCancellation()
      let firstRow = tileRow * edit.blockSize
      let tileRows = firstRow..<min(height, firstRow + edit.blockSize)
      guard let visibleRows = tileRows.overlap(with: edit.rows) else { continue }
      let fills = cells.map { cell in
        let firstColumn = cell.x * edit.blockSize
        let columns = (firstColumn + columnOffset)..<(min(imageWidth, firstColumn + edit.blockSize) + columnOffset)
        var sums = SIMD4<UInt64>.zero
        var bytes = [UInt8](repeating: 0, count: columns.count * 4)
        for row in tileRows {
          bytes.withUnsafeMutableBytes { buffer in
            _ = ImageBytes.read(buffer.baseAddress!, chunks: chunks, ends: ends,
              offset: row * stride + columns.lowerBound * 4, count: buffer.count)
          }
          for pixel in Swift.stride(from: 0, to: bytes.count, by: 4) {
            sums &+= SIMD4(UInt64(bytes[pixel]), UInt64(bytes[pixel + 1]),
                          UInt64(bytes[pixel + 2]), UInt64(bytes[pixel + 3]))
          }
        }
        let count = UInt64(tileRows.count * columns.count)
        return (columns, SIMD4<UInt8>(truncatingIfNeeded: sums / count))
      }
      for row in visibleRows {
        let offset = row * stride
        while ends[chunkIndex] <= offset { chunkIndex += 1 }
        let localOffset = offset - (chunkIndex == 0 ? 0 : ends[chunkIndex - 1])
        chunks[chunkIndex].withUnsafeMutableBytes { buffer in
          for (columns, color) in fills {
            for column in columns { buffer.storeBytes(of: color, toByteOffset: localOffset + column * 4, as: SIMD4<UInt8>.self) }
          }
        }
      }
    }
  }
}

private extension Range<Int> {
  nonisolated func overlap(with other: Range<Int>) -> Range<Int>? {
    overlaps(other) ? clamped(to: other) : nil
  }
}

nonisolated struct ScrollingScreenshotEdit: Sendable {
  struct Cell: Hashable, Sendable { let x: Int; let y: Int }

  let width: Int
  let height: Int
  let blockSize: Int
  private(set) var rows: Range<Int>
  private(set) var cells: Set<Cell> = []

  init(width: Int, height: Int, blockSize: Int) {
    self.width = width
    self.height = height
    self.blockSize = max(1, blockSize)
    rows = 0..<height
  }

  mutating func crop(at fraction: CGFloat, top: Bool) {
    let row = Int((min(1, max(0, fraction)) * CGFloat(height)).rounded())
    rows = top ? min(row, rows.upperBound - 1)..<rows.upperBound
      : rows.lowerBound..<max(row, rows.lowerBound + 1)
  }

  mutating func paint(_ normalizedRect: CGRect) {
    let rect = normalizedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !rect.isEmpty else { return }
    let x = Int(rect.minX * CGFloat(width)) / blockSize
    let y = Int(rect.minY * CGFloat(height)) / blockSize
    let lastX = (Int(ceil(rect.maxX * CGFloat(width))) - 1) / blockSize
    let lastY = (Int(ceil(rect.maxY * CGFloat(height))) - 1) / blockSize
    for row in y...lastY {
      for column in x...lastX { cells.insert(Cell(x: column, y: row)) }
    }
  }
}

nonisolated struct ScrollingScreenshotCadence {
  static let minimumDelay: Duration = .milliseconds(17)
  private var unchangedFrames = 0
  var isIdle: Bool { unchangedFrames >= 4 }

  mutating func delay(after result: ScrollingScreenshotStitcher.AppendResult, elapsed: Duration,
                      scrollIsActive: Bool = false) -> Duration {
    unchangedFrames = result == .unchanged ? min(4, unchangedFrames + 1) : 0
    if scrollIsActive { return Self.minimumDelay }
    return max(Self.minimumDelay, (isIdle ? .milliseconds(150) : .milliseconds(50)) - max(.zero, elapsed))
  }
}

actor ScrollingScreenshotProcessor {
  struct Output: Sendable {
    let data: Data
    let image: CGImage
    let preview: CGImage?
  }

  struct Update: Sendable {
    let thumbnail: CGImage?
    let width: Int
    let height: Int
    let capReached: Bool
    let showSlowScrollHint: Bool
    let warning: ScrollingScreenshotHintState.Warning
    let appendResult: ScrollingScreenshotStitcher.AppendResult
    let matchedShift: Int?
    let maximumMatchableShift: Int
  }

  enum Failure: Error { case invalidFrame }

  private var stitcher: ScrollingScreenshotStitcher?
  private var needsPreview = false
  private var hintState = ScrollingScreenshotHintState()
  private let clockOrigin = ContinuousClock.now

  func append(_ image: CGImage, refreshPreview: Bool, maximumPixels: Int) throws -> Update {
    try Task.checkCancellation()
    if stitcher == nil {
      guard image.width > 0, image.height > 0, image.width <= maximumPixels / image.height else {
        throw Failure.invalidFrame
      }
      stitcher = ScrollingScreenshotStitcher(width: image.width, height: image.height, maximumPixels: maximumPixels)
    }
    let changed = stitcher!.append(image)
    hintState.record(stitcher!.appendResult, shift: stitcher!.matchedShift,
      maximumShift: stitcher!.maximumMatchableShift, now: clockOrigin.duration(to: .now))
    needsPreview = needsPreview || changed
    try Task.checkCancellation()
    let capped = stitcher!.capReached
    let thumbnail = needsPreview && (refreshPreview || capped) ? stitcher!.thumbnail() : nil
    if thumbnail != nil { needsPreview = false }
    return Update(thumbnail: thumbnail, width: stitcher!.imageWidth, height: stitcher!.height,
      capReached: capped, showSlowScrollHint: hintState.shouldShowSlowScrollHint,
      warning: hintState.warning, appendResult: stitcher!.appendResult,
      matchedShift: stitcher!.matchedShift, maximumMatchableShift: stitcher!.maximumMatchableShift)
  }

  func editingPreview() throws -> Update? {
    try Task.checkCancellation()
    guard let stitcher, let thumbnail = stitcher.thumbnail(maximumHeight: 4096) else { return nil }
    return Update(thumbnail: thumbnail, width: stitcher.imageWidth, height: stitcher.height,
      capReached: stitcher.capReached, showSlowScrollHint: false, warning: .normal,
      appendResult: stitcher.appendResult, matchedShift: stitcher.matchedShift,
      maximumMatchableShift: stitcher.maximumMatchableShift)
  }

  func export(includePreview: Bool = false, edit: ScrollingScreenshotEdit? = nil,
              encodePNG: @Sendable (CGImage) -> Data? = ScrollingScreenshotProcessor.mappedPNG) throws -> Output? {
    guard let (image, preview) = try takeExportImages(includePreview: includePreview, edit: edit) else { return nil }
    try Task.checkCancellation()
    guard let data = encodePNG(image) else { return nil }
    try Task.checkCancellation()
    return Output(data: data, image: image, preview: preview)
  }

  private func takeExportImages(includePreview: Bool, edit: ScrollingScreenshotEdit?) throws
    -> (CGImage, CGImage?)? {
    defer {
      stitcher = nil
      needsPreview = false
    }
    try Task.checkCancellation()
    guard let rows = stitcher.map({ 0..<$0.height }) else { return nil }
    if let edit {
      guard edit.width == stitcher?.imageWidth, edit.height == rows.count else { return nil }
      try stitcher?.applyMosaic(edit)
    }
    let outputRows = edit?.rows ?? rows
    let preview = includePreview
      ? stitcher?.thumbnail(maximumWidth: 440, maximumHeight: 300, rows: outputRows) : nil
    guard let image = try stitcher?.takeImage(rows: outputRows) else { return nil }
    return (image, preview)
  }

  private static func mappedPNG(_ image: CGImage) -> Data? {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
    defer { try? FileManager.default.removeItem(at: url) }
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return try? Data(contentsOf: url, options: .alwaysMapped)
  }
}
#endif
