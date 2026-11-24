import AppKit
import CoreData
import Defaults
import KeyboardShortcuts
import Testing
@testable import Maccy

private extension ScrollingScreenshotStitcher {
  var pixels: [UInt8] { chunks.flatMap { $0 } }
}

@MainActor
struct ScreenshotCaptureTests {
  @Test("Window compositing keeps transparent gaps, stacking order and the backdrop padding")
  func windowCompositing() throws {
    func layer(_ color: NSColor) throws -> CGImage {
      let context = try #require(CGContext(
        data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.setFillColor(color.cgColor)
      context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
      return try #require(context.makeImage())
    }
    let main = CGRect(x: -2, y: 4, width: 3, height: 3)
    let menu = CGRect(x: 0, y: 6, width: 3, height: 3)
    let windows = try ScreenshotCaptureSession.compositeWindows(
      [(layer(.red), main), (layer(.blue), menu)], bounds: main.union(menu), scale: 2
    )
    let image = try #require(windows)
    #expect(image.width == 10 && image.height == 10)
    let pixels = NSBitmapImageRep(cgImage: image)
    #expect(pixels.colorAt(x: 1, y: 1)?.redComponent == 1)
    #expect(pixels.colorAt(x: 4, y: 4)?.blueComponent == 1)
    #expect(pixels.colorAt(x: 9, y: 1)?.alphaComponent == 0)
    let result = try #require(ScreenshotCaptureSession.windowBackdrop(image, scale: 2))
    let padded = NSBitmapImageRep(cgImage: result)
    #expect(result.width == 138 && result.height == 138)
    #expect(padded.colorAt(x: 2, y: 2)?.alphaComponent == 1)
    #expect(padded.colorAt(x: 68, y: 68)?.blueComponent == 1)
    #expect(padded.colorAt(x: 135, y: 2) != padded.colorAt(x: 2, y: 135))
  }

  @Test("Inferred leading and trailing misses require informative body confirmation",
        arguments: [false, true])
  func scrollingExcludedBandsRequireBody(trailing: Bool) {
    let stride = 8 * 4
    let first = scrollingFrame(0)
    var next = scrollingFrame(6)
    let rows = trailing ? 16..<18 : 0..<2
    let changed = scrollingFrame(100)
    next.replaceSubrange((rows.lowerBound * stride)..<(rows.upperBound * stride),
      with: changed.prefix(2 * stride))
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 100)
    #expect({ stitcher.append(rgba: first) }())
    #expect({ stitcher.append(rgba: next) }())
    #expect(stitcher.matchedShift == 6)
    #expect(stitcher.height == 30)
    let trim = trailing ? 2 : 0
    #expect({ stitcher.pixels == Array(first.prefix((24 - trim) * stride))
      + Array(next.suffix((6 + trim) * stride)) }())

    var unsupported = next
    unsupported.replaceSubrange((2 * stride)..<(16 * stride),
      with: [UInt8](repeating: 255, count: 14 * stride))
    var rejected = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 100)
    #expect({ rejected.append(rgba: first) }())
    #expect({ !rejected.append(rgba: unsupported) }())
    #expect({ rejected.pixels == first }())
  }

  @Test("Candidate overflow retains the strongest thirty-two anchor vote totals deterministically")
  func scrollingCandidateVoteRanking() {
    #expect(ScrollingScreenshotStitcher.rankedCandidateShifts([:]).isEmpty)
    #expect(ScrollingScreenshotStitcher.rankedCandidateShifts([7: 1, 19: 2]) == [7, 19])
    var votes = Dictionary(uniqueKeysWithValues: (1...64).map { ($0, 1) })
    votes[60] = 100
    votes[61] = 99
    let expected = Set(Array(1...30) + [60, 61])
    #expect(ScrollingScreenshotStitcher.rankedCandidateShifts(votes) == expected)
    #expect(ScrollingScreenshotStitcher.rankedCandidateShifts(
      Dictionary(uniqueKeysWithValues: votes.sorted { $0.key > $1.key })) == expected)
  }

  @Test("Removing a scrollbar does not reveal its stale pixels in already stored rows", arguments: [false, true])
  func scrollingHistoricalScrollbarCrop(fileBacked: Bool) throws {
    let width = 800, frameHeight = 800, stride = width * 4
    let page = scrollingTextContent(width: width, height: 1280)
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight,
      maximumPixels: width * 2000)
    for offset in [0, 160, 320, 480] {
      var frame = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      if offset < 320 {
        for row in (70 + offset / 4)..<(160 + offset / 4) {
          for column in (width - 12)..<width {
            let index = (row * width + column) * 4
            frame[index] = 110; frame[index + 1] = 110; frame[index + 2] = 110
          }
        }
      }
      #expect({ stitcher.append(rgba: frame) }())
      #expect(stitcher.height == frameHeight + offset)
    }
    let image = try #require(stitcher.image)
    #expect(image.width < width)
    #expect(image.width >= width - 20)
    let expected = page.enumerated().filter { $0.offset % stride < image.width * 4 }.map(\.element)
    #expect(try scrollingImagePixels(image) == expected)
    #expect({ stitcher.pixels != page }())
    #expect({ Array(stitcher.pixels.suffix(frameHeight * stride)) == Array(page.suffix(frameHeight * stride)) }())
    let rows = 761..<1001
    let cropped = try #require(try stitcher.takeImage(rows: rows, fileBacked: fileBacked))
    #expect(stitcher.chunks.isEmpty)
    #expect(cropped.width == image.width && cropped.height == rows.count)
    let outputStride = image.width * 4
    let retained = (rows.lowerBound * outputStride)..<(rows.upperBound * outputStride)
    #expect(try scrollingImagePixels(cropped) == Array(expected[retained]))
  }

  @Test("Static corner replacement retains exact pixels across short and tall edge overlays",
        arguments: [3, 24, 80, 140])
  func scrollingCornerReplacementDepth(depth: Int) throws {
    let width = 800, frameHeight = 800, stride = width * 4
    let page = scrollingTextContent(width: width, height: 1120)
    func edges(_ bytes: inout [UInt8], height: Int) {
      for row in (height - depth)..<height {
        for column in Array(0..<16) + Array((width - 16)..<width) {
          let index = (row * width + column) * 4
          bytes[index] = 72; bytes[index + 1] = 72; bytes[index + 2] = 72
        }
      }
    }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight,
      maximumPixels: width * 2000)
    for offset in [0, 160, 320] {
      var frame = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      edges(&frame, height: frameHeight)
      #expect({ stitcher.append(rgba: frame) }())
      #expect(stitcher.height == frameHeight + offset)
      var expected = Array(page.prefix((frameHeight + offset) * stride))
      edges(&expected, height: frameHeight + offset)
      #expect({ stitcher.pixels == expected }())
    }
  }

  @Test("Corner replacement includes faint shading below signature quantization")
  func scrollingFaintCornerShading() {
    let width = 128, frameHeight = 800, stride = width * 4
    var page = [UInt8](repeating: 255, count: stride * 960)
    for row in 0..<960 {
      let seed = UInt64(row + 1) &* 0x9E3779B97F4A7C15
      for column in 0..<32 {
        let index = row * stride + column * 4
        page[index] = UInt8(truncatingIfNeeded: seed >> 32)
        page[index + 1] = UInt8(truncatingIfNeeded: seed >> 40)
        page[index + 2] = UInt8(truncatingIfNeeded: seed >> 48)
      }
    }
    func shade(_ bytes: inout [UInt8], height: Int) {
      for row in (height - 20)..<height {
        for column in 64..<96 {
          let index = row * stride + column * 4
          bytes[index] = 254; bytes[index + 1] = 254; bytes[index + 2] = 254
        }
      }
      for row in (height - 6)..<height {
        for column in Array(0..<16) + Array(112..<128) {
          let index = row * stride + column * 4
          bytes[index] = 72; bytes[index + 1] = 72; bytes[index + 2] = 72
        }
      }
    }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight,
      maximumPixels: width * 2000)
    for offset in [0, 160] {
      var frame = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      shade(&frame, height: frameHeight)
      #expect({ stitcher.append(rgba: frame) }())
      var expected = Array(page.prefix((frameHeight + offset) * stride))
      shade(&expected, height: frameHeight + offset)
      #expect(stitcher.height == frameHeight + offset)
      #expect({ stitcher.pixels == expected }())
    }
  }

  @Test("Warning thresholds use pixel shifts at both backing scales", arguments: [1, 2])
  func scrollingWarningPixelUnits(scale: Int) {
    var hint = ScrollingScreenshotHintState()
    hint.record(.appended, shift: 40 * scale, maximumShift: 100 * scale)
    #expect(hint.warning == .normal)
    hint.record(.appended, shift: 86 * scale, maximumShift: 100 * scale)
    #expect(hint.warning == .tooFast)
    hint.record(.unmatched)
    hint.record(.unmatched)
    #expect(hint.warning == .lostTrack)
    hint.record(.reanchored)
    #expect(hint.warning == .normal)
  }

  @Test("The scrolling thumbnail and PNG retain the first frame's Display P3 profile")
  func scrollingWideGamutExport() async throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(
      data: nil, width: 8, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let green = try #require(CGColor(colorSpace: space, components: [0.2, 0.8, 0.4, 1]))
    context.setFillColor(green)
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 24))
    let frame = try #require(context.makeImage())
    let processor = ScrollingScreenshotProcessor()
    let result = try await processor.append(frame, refreshPreview: true, maximumPixels: 8 * 48)
    let thumbnail = try #require(result.thumbnail)
    let output = try #require(await processor.export())
    let data = output.data
    let decoded = try ScreenshotCaptureSession.ValidatedImage.validate(data).image
    for image in [thumbnail, decoded] {
      #expect(image.colorSpace?.isWideGamutRGB == true)
      #expect(ScreenshotPixelLoupe.sample(image, at: .zero)?.hex == "#33CC66")
    }
  }

  @Test("Tail removal rejects abnormal trims without indexing empty chunks or changing stored pixels")
  func scrollingEmptyTailRemoval() {
    for initial: [[UInt8]] in [[], [[]], [[1, 2], [], [3, 4, 5]]] {
      for count in [-1, Int.max] {
        var chunks = initial
        #expect(!ScrollingScreenshotStitcher.removeTail(byteCount: count, from: &chunks))
        #expect(chunks == initial)
      }
      var chunks = initial
      #expect(ScrollingScreenshotStitcher.removeTail(byteCount: 0, from: &chunks))
      #expect(chunks == initial)
    }
    var chunks: [[UInt8]] = [[1, 2], [], [3, 4, 5]]
    #expect(ScrollingScreenshotStitcher.removeTail(byteCount: 4, from: &chunks))
    #expect(chunks == [[1]])
    #expect(ScrollingScreenshotStitcher.removeTail(byteCount: 1, from: &chunks))
    #expect(chunks.isEmpty)
    #expect(!ScrollingScreenshotStitcher.removeTail(byteCount: 1, from: &chunks))
    #expect(chunks.isEmpty)
  }

  @Test("Low-contrast browser text provides anchors without changing exported pixels",
        arguments: ["chrome-dim", "chrome-low", "safari-dim", "safari-low"])
  func scrollingLowContrast(name: String) throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Scrolling")
    func image(_ suffix: String) throws -> CGImage {
      let data = try Data(contentsOf: directory.appendingPathComponent("contrast-\(name)-\(suffix).png"))
      return try #require(NSBitmapImageRep(data: data)?.cgImage)
    }
    let first = try image("start")
    let next = try image("next")
    var stitcher = ScrollingScreenshotStitcher(width: first.width, height: first.height,
      maximumPixels: 100_000_000)
    #expect({ stitcher.append(first) }())
    #expect({ stitcher.append(next) }())
    #expect(stitcher.height == first.height + 160)
    #expect(stitcher.imageWidth == first.width)
    let expected = try scrollingImagePixels(first) + scrollingImagePixels(next).suffix(160 * first.width * 4)
    #expect({ stitcher.pixels == expected }())
    #expect({ !stitcher.append(next) }())
    #expect(stitcher.appendResult == .unchanged)
    #expect({ !stitcher.append(rgba: []) }())
    #expect(stitcher.appendResult == .invalid)
    #expect({ stitcher.pixels == expected }())
  }

  @Test("A disappearing floating bar releases its replacement tail and restores the full match range",
        arguments: ["chrome", "safari"])
  func scrollingDisappearingTail(browser: String) throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Scrolling")
    func image(_ y: Int) throws -> CGImage {
      let data = try Data(contentsOf: directory.appendingPathComponent("tail-\(browser)-\(y).png"))
      return try #require(NSBitmapImageRep(data: data)?.cgImage)
    }
    let first = try image(0)
    let last = try image(960)
    var stitcher = ScrollingScreenshotStitcher(width: first.width, height: first.height,
      maximumPixels: 100_000_000)
    var compressed = 0
    var previousPixels: [UInt8] = []
    for y in [0, 160, 320, 480, 640, 800, 960] {
      let frame = try image(y)
      let pixels = try scrollingImagePixels(frame)
      let previousHeight = stitcher.height
      let appended = stitcher.append(frame)
      #expect(appended == (pixels != previousPixels))
      #expect(stitcher.height == (pixels == previousPixels ? previousHeight : first.height + y))
      previousPixels = pixels
      if y == 800 { compressed = stitcher.maximumMatchableShift }
    }
    #expect(stitcher.maximumMatchableShift > compressed)
    #expect(stitcher.maximumMatchableShift >= 520)
    let expected = try scrollingImagePixels(first)
      + Array(scrollingImagePixels(image(800)).prefix(160 * first.width * 4))
      + scrollingImagePixels(last)
    #expect({ stitcher.pixels == expected }())
  }

  @Test("Recorded sparse content rejects aliased jumps without losing rows and recovers nearby frames",
        arguments: ["chat", "table", "safari-table"])
  func scrollingSolidContentAliases(name: String) throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Scrolling")
    func image(_ suffix: String) throws -> CGImage {
      let data = try Data(contentsOf: directory.appendingPathComponent("solid-\(name)-\(suffix).png"))
      return try #require(NSBitmapImageRep(data: data)?.cgImage)
    }
    let first = try image("before")
    let nearby = try image("near")
    let step = name == "table" ? 120 : 64
    var stitcher = ScrollingScreenshotStitcher(width: 800, height: 800, maximumPixels: 800 * 4000)
    #expect({ stitcher.append(first) }())
    let original = stitcher.pixels
    let rejected = stitcher.append(try image("jump"))
    #expect(!rejected)
    #expect(stitcher.height == 800)
    #expect({ stitcher.pixels == original }())
    let accepted = stitcher.append(nearby)
    #expect(accepted)
    #expect(stitcher.height == 800 + step)
    var reference = ScrollingScreenshotStitcher(width: 800, height: 800, maximumPixels: 800 * 4000)
    reference.append(nearby)
    let expected = original + reference.pixels.suffix(step * 800 * 4)
    #expect({ stitcher.pixels == expected }())
  }

  @Test("The article fixture documents a pixel-identical periodic overlap")
  func scrollingPeriodicArticleOverlap() throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Scrolling")
    func pixels(_ suffix: String) throws -> [UInt8] {
      let data = try Data(contentsOf: directory.appendingPathComponent("solid-article-\(suffix).png"))
      return try scrollingImagePixels(#require(NSBitmapImageRep(data: data)?.cgImage))
    }
    let first = try pixels("before")
    let jump = try pixels("jump")
    let stride = 800 * 4
    #expect(Array(first[(225 * stride)..<(800 * stride)]) == Array(jump[(3 * stride)..<(578 * stride)]))
  }

  @Test("Neutral rows after a changing header stay unmasked and informative removal stays bounded",
        arguments: [0, 100, 110])
  func scrollingHeaderNeutralRows(informativeRows: Int) {
    let width = 256
    let frameHeight = 800
    let shift = 128
    let stride = width * 4
    let content = scrollingSolidAreaPage(width: width, height: 1400, band: 0..<0)
    var page = [UInt8](repeating: 255, count: (frameHeight + shift) * stride)
    let body = (shift + 200)..<(shift + 200 + informativeRows)
    page.replaceSubrange((body.lowerBound * stride)..<(body.upperBound * stride),
      with: content[(body.lowerBound * stride)..<(body.upperBound * stride)])
    func frame(_ offset: Int) -> [UInt8] {
      var bytes = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      let source = offset == 0 ? 1000 : 1200
      bytes.replaceSubrange(0..<(80 * stride), with: content[(source * stride)..<((source + 80) * stride)])
      for row in (offset == 0 ? 100..<120 : 140..<160) {
        for column in (width - 12)..<width {
          let index = (row * width + column) * 4
          bytes[index] = 75; bytes[index + 1] = 75; bytes[index + 2] = 75
        }
      }
      return bytes
    }
    let first = frame(0)
    let next = frame(shift)
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: width * 2000)
    #expect({ stitcher.append(rgba: first) }())
    let accepted = stitcher.append(rgba: next)
    #expect(accepted == (informativeRows == 110))
    #expect(stitcher.height == frameHeight + (accepted ? shift : 0))
    #expect({ stitcher.pixels == (accepted ? first + Array(next.suffix(shift * stride)) : first) }())
  }

  @Test("Recorded full-window Safari headers preserve neutral body rows and exact output",
        arguments: ["bands", "text"])
  func scrollingLiveSafariHeader(name: String) throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Scrolling")
    func image(_ suffix: String) throws -> CGImage {
      let data = try Data(contentsOf: directory.appendingPathComponent("live-safari-\(name)-\(suffix).png"))
      return try #require(NSBitmapImageRep(data: data)?.cgImage)
    }
    let first = try image("before")
    let next = try image("after")
    let shift = name == "bands" ? 169 : 320
    let width = first.width
    let height = first.height
    let stride = width * 4
    var stitcher = ScrollingScreenshotStitcher(width: width, height: height, maximumPixels: 100_000_000)
    #expect({ stitcher.append(first) }())
    #expect({ stitcher.append(next) }())
    #expect(stitcher.height == height + shift)
    let expected = Array(try scrollingImagePixels(first).prefix((height - 126) * stride))
      + Array(try scrollingImagePixels(next).suffix((shift + 126) * stride))
    #expect({ stitcher.pixels == expected }())
    let output = try #require(stitcher.image)
    var cropped = [UInt8]()
    cropped.reserveCapacity(output.width * output.height * 4)
    for row in 0..<output.height {
      cropped.append(contentsOf: expected[(row * stride)..<(row * stride + output.width * 4)])
    }
    #expect(try scrollingImagePixels(output) == cropped)
  }

  @Test("The height cap does not replace real body rows with an ambiguous plain footer")
  func scrollingSolidFooterAtCap() {
    let width = 256
    let stride = width * 4
    let source = scrollingTextContent(width: width, height: 40 * 19)
    var page = [UInt8](repeating: 255, count: 1200 * stride)
    for row in 0..<1200 where row % 32 < 12 {
      let start = (row / 32 * 19 + row % 32) * stride
      page.replaceSubrange((row * stride)..<((row + 1) * stride), with: source[start..<(start + stride)])
    }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: 800, maximumPixels: width * 1000)
    for offset in [0, 64, 128, 192, 256] {
      let frame = Array(page[(offset * stride)..<((offset + 800) * stride)])
      #expect({ stitcher.append(rgba: frame) }())
      let expected = Array(page.prefix(min(800 + offset, 1000) * stride))
      #expect({ stitcher.pixels == expected }())
    }
    #expect(stitcher.capReached)
    let original = stitcher.pixels
    #expect({ !stitcher.append(rgba: Array(page.prefix(800 * stride))) }())
    #expect({ stitcher.pixels == original }())
  }

  @Test("Recorded Safari toolbar and Chrome scrollbar frames retain exact output pixels",
        arguments: ["safari-toolbar", "chrome-scrollbar"])
  func scrollingRecordedBrowserUI(name: String) throws {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/Scrolling")
    func image(_ suffix: String) throws -> CGImage {
      let data = try Data(contentsOf: directory.appendingPathComponent("\(name)-\(suffix).png"))
      let bitmap = try #require(NSBitmapImageRep(data: data))
      return try #require(bitmap.cgImage)
    }
    let first = try image("before")
    let next = try image("after")
    let width = first.width
    let frameHeight = first.height
    let shift = name == "safari-toolbar" ? 160 : 80
    func pixels(_ image: CGImage) throws -> [UInt8] {
      var bytes = [UInt8](repeating: 0, count: width * frameHeight * 4)
      try bytes.withUnsafeMutableBytes { buffer in
        let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: frameHeight,
          bitsPerComponent: 8, bytesPerRow: width * 4, space: first.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: frameHeight))
      }
      return bytes
    }
    let oldPixels = try pixels(first)
    let nextPixels = try pixels(next)
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: 100_000_000)
    #expect({ stitcher.append(first) }())
    #expect({ stitcher.append(next) }())
    #expect(stitcher.height == frameHeight + shift)
    let bottomChrome = 126
    let expected = Array(oldPixels.prefix((frameHeight - bottomChrome) * width * 4))
      + Array(nextPixels.suffix((shift + bottomChrome) * width * 4))
    #expect({ stitcher.pixels == expected }())
    let output = try #require(stitcher.image)
    #expect(output.width <= width && output.width >= width - width / 8 - 1)
    if name == "chrome-scrollbar" { #expect(output.width < width) }
    let crop = width - output.width
    let expectedImage = expected.enumerated().filter { $0.offset % (width * 4) < (width - crop) * 4 }.map(\.element)
    #expect(try scrollingImagePixels(output) == expectedImage)
  }

  private func scrollingImagePixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.setBlendMode(.copy)
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
  }

  @Test("Large PNG history previews have bounded pixel dimensions without changing the stored PNG")
  func largePNGHistoryPreviews() throws {
    let width = 2048, height = 8193
    let context = try #require(CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    ))
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    let content = HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: data)
    let decorator = HistoryItemDecorator(HistoryItem(contents: [content]))
    decorator.sizeImages()
    let pixelScale = NSScreen.forPopup?.backingScaleFactor ?? 1
    for (preview, bounds) in [
      (decorator.thumbnailImage, HistoryItemDecorator.thumbnailImageSize),
      (decorator.previewImage, HistoryItemDecorator.previewImageSize)
    ] {
      let resized = try #require(preview)
      let representation = try #require(resized.representations.first)
      #expect(representation.pixelsWide > 0 && representation.pixelsHigh > 0)
      #expect(representation.pixelsWide <= Int(ceil(bounds.width * pixelScale)))
      #expect(representation.pixelsHigh <= Int(ceil(bounds.height * pixelScale)))
      #expect(abs(resized.size.width / resized.size.height - Double(width) / Double(height)) < 0.001)
    }
    #expect(decorator.item.imageData == data)
  }

  @Test("Forty bands retain exact pixels across thirteen joins with rounded corners, shading and a moving thumb")
  func scrollingRoundedCorners() throws {
    let width = 512
    let frameHeight = 800
    let stride = width * 4
    var page = scrollingTextContent(width: width, height: 3200)
    for row in 0..<3200 {
      for column in 0..<width where page[(row * width + column) * 4] == 255 {
        let index = (row * width + column) * 4
        let value = UInt8(130 + row / 80 * 3)
        page[index] = value; page[index + 1] = value; page[index + 2] = value
      }
    }
    func shade(_ bytes: inout [UInt8], height: Int) {
      for row in (height - 35)..<height {
        let alpha = (row - height + 36) * 4
        for column in 0..<width {
          let index = (row * width + column) * 4
          for channel in 0..<3 {
            bytes[index + channel] = UInt8((Int(bytes[index + channel]) * (255 - alpha) + 24 * alpha) / 255)
          }
        }
      }
    }
    func corners(_ bytes: inout [UInt8], height: Int, top: Bool, bottom: Bool) {
      for row in 0..<height where (top && row < 20) || (bottom && row >= height - 20) {
        let dy = row < 20 ? Double(row) + 0.5 - 20 : Double(height - row) - 0.5 - 20
        for column in 0..<width where column < 20 || column >= width - 20 {
          let dx = column < 20 ? Double(column) + 0.5 - 20 : Double(width - column) - 0.5 - 20
          if dx * dx + dy * dy > 400 {
            let index = (row * width + column) * 4
            bytes[index] = 72; bytes[index + 1] = 72; bytes[index + 2] = 72
          }
        }
      }
    }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: width * 4000)
    for offset in Array(Swift.stride(from: 0, through: 2304, by: 192)) + [2400] {
      var frame = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      for row in (70 + offset / 4)..<(160 + offset / 4) {
        for column in (width - 12)..<width {
          let index = (row * width + column) * 4
          frame[index] = 110; frame[index + 1] = 110; frame[index + 2] = 110
        }
      }
      shade(&frame, height: frameHeight)
      corners(&frame, height: frameHeight, top: true, bottom: true)
      #expect({ stitcher.append(rgba: frame) }())
      #expect(stitcher.height == frameHeight + offset)
      if offset == 0 { continue }
      let image = try #require(stitcher.image)
      #expect(image.width == width - 12)
      var expected = Array(page.prefix((frameHeight + offset) * stride))
      shade(&expected, height: frameHeight + offset)
      corners(&expected, height: frameHeight + offset, top: true, bottom: true)
      let cropped = expected.enumerated().filter { $0.offset % stride < image.width * 4 }.map(\.element)
      #expect(try scrollingImagePixels(image) == cropped)
      let preview = try #require(stitcher.thumbnail(maximumWidth: image.width, maximumHeight: image.height))
      #expect(try scrollingImagePixels(preview) == cropped)
    }
    #expect(stitcher.height == 3200)
  }

  @Test("Narrow right thumbs and short headers match while other edge and body changes reject",
        arguments: ["left", "right", "header", "both", "middle", "scattered", "wideEdge", "wideScrollbar", "tallHeader",
                    "shortOverlap", "twoEdges"])
  func scrollingChangingStrips(mode: String) {
    let width = 256
    let frameHeight = 800
    let shift = mode == "shortOverlap" ? 500 : 128
    let stride = width * 4
    let header = mode == "shortOverlap" ? 160
      : ["header", "both", "tallHeader"].contains(mode) ? (mode == "tallHeader" ? 120 : 80) : 0
    let page = scrollingTextContent(width: width, height: frameHeight + shift)
    func frame(_ offset: Int) -> [UInt8] {
      var bytes = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      for row in 0..<frameHeight {
        for column in 0..<width {
          var value: UInt8?
          if row < header { value = offset == 0 ? 40 : 200 }
          if ["left", "right", "both", "wideEdge", "wideScrollbar", "twoEdges"].contains(mode) {
            let thickness = mode == "wideEdge" ? 40 : mode == "wideScrollbar" ? 20 : 12
            let atEdge = mode == "twoEdges" ? column < thickness || column >= width - thickness
              : mode == "left" ? column < thickness : column >= width - thickness
            if atEdge, (offset == 0 ? 100..<200 : 120..<220).contains(row) {
              let original = value ?? bytes[row * stride + column * 4]
              value = UInt8((Int(original) + 75) / 2)
            }
          }
          if offset > 0, (100..<300).contains(row) {
            if mode == "middle", (120..<132).contains(column) { value = 40 }
            if mode == "scattered", column % 31 == 0 { value = 40 }
          }
          if let value {
            let index = row * stride + column * 4
            bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
          }
        }
      }
      return bytes
    }
    let first = frame(0)
    let next = frame(shift)
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: width * 2000)
    #expect({ stitcher.append(rgba: first) }())
    let accepted = stitcher.append(rgba: next)
    let shouldAccept = ["right", "header", "both"].contains(mode)
    #expect(accepted == shouldAccept)
    #expect(stitcher.height == (shouldAccept ? frameHeight + shift : frameHeight))
    let expected = shouldAccept ? first + Array(next.suffix(shift * stride)) : first
    #expect({ stitcher.pixels == expected }())
  }

  @Test("Native text frames stitch exactly at point and Retina resolutions", arguments: [1, 2])
  func scrollingRetinaText(scale: Int) async throws {
    let width = 1120 * scale
    let frameHeight = 800 * scale
    let pageHeight = 1040 * scale
    var page = [UInt8](repeating: 255, count: width * pageHeight * 4)
    try page.withUnsafeMutableBytes { buffer in
      let context = try #require(CGContext(data: buffer.baseAddress, width: width, height: pageHeight,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
      context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      defer { NSGraphicsContext.restoreGraphicsState() }
      for line in 0..<32 {
        ("Line \(line) — Cedar branches shelter seven finches. Marker \(line * 7919)" as NSString).draw(
          at: NSPoint(x: 24, y: 1000 - line * 32), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular), .foregroundColor: NSColor.black
          ])
      }
    }
    let processor = ScrollingScreenshotProcessor()
    var processorMilliseconds: [Double] = []
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: 100_000_000)
    for offset in [0, 20, 60, 100, 200] {
      let firstByte = offset * scale * width * 4
      let bytes = Array(page[firstByte..<(firstByte + frameHeight * width * 4)])
      let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
      let image = try #require(CGImage(width: width, height: frameHeight, bitsPerComponent: 8,
        bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      let accepted = stitcher.append(image)
      #expect(accepted)
      #expect(stitcher.height == frameHeight + offset * scale)
      #expect({ stitcher.pixels == Array(page.prefix((frameHeight + offset * scale) * width * 4)) }())
      let started = Date()
      let update = try await processor.append(image, refreshPreview: true, maximumPixels: 100_000_000)
      processorMilliseconds.append(Date().timeIntervalSince(started) * 1000)
      #expect(update.appendResult == .appended)
      #expect(update.height == stitcher.height)
      #expect(update.thumbnail != nil)
    }
    print("RETINA_PROCESSOR scale=\(scale) pixels=\(width)x\(frameHeight) milliseconds=\(processorMilliseconds)")
  }

  private func scrollingFrame(_ start: Int, header: Int = 0, footer: Int = 0) -> [UInt8] {
    (0..<24).flatMap { y -> [UInt8] in
      let value = y < header ? 240 + y : y >= 24 - footer ? 250 + y - 24 : start + y - header
      return (0..<8).flatMap { x -> [UInt8] in
        let red = UInt8((value * 37 + x * 19) % 239)
        let green = UInt8((value * 71 + x * 13) % 239)
        return [red, green, UInt8(value % 239), 255]
      }
    }
  }

  private func scrollingTextContent(width: Int, height: Int) -> [UInt8] {
    let stride = width * 4
    var strip = [UInt8](repeating: 255, count: height * stride)
    for y in 0..<height where y % 19 < 12 {
      let line = y / 19
      var x = 11 + (line * 17) % 31
      var glyph = 0
      let lineEnd = width - 40 - (line * 73) % 420
      while x < lineEnd {
        let dashWidth = 2 + (line * 7 + glyph * 11 + y % 19 * 3) % 13
        for column in x..<min(x + dashWidth, lineEnd) {
          let index = y * stride + column * 4
          strip[index] = 0
          strip[index + 1] = 0
          strip[index + 2] = 0
        }
        x += dashWidth + 3 + (glyph * 5 + line) % 9
        glyph += 1
      }
    }
    return strip
  }

  private func scrollingSolidAreaPage(width: Int, height: Int, band: Range<Int>, nearUniform: Bool = false)
    -> [UInt8] {
    var page = [UInt8](repeating: 255, count: width * height * 4)
    for row in 0..<height {
      var seed = UInt64(row + 12345)
      for column in 0..<width {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let value = band.contains(row) ? UInt8(nearUniform ? 254 + row % 3 / 2 : 255)
          : UInt8((seed >> 32) % 220)
        let index = (row * width + column) * 4
        for channel in 0..<3 { page[index + channel] = value }
      }
    }
    return page
  }

  @Test("Solid areas preserve the exact page prefix at every scroll",
        arguments: ["band150", "band400", "margin400", "nearUniform", "footerBand"], [64, 128])
  func scrollingSolidAreas(mode: String, step: Int) {
    let width = 32
    let frameHeight = 800
    let pageHeight = 2400
    let stride = width * 4
    let margin = mode == "margin400" || mode == "nearUniform"
    let band = margin ? 2000..<2400 : 768..<(768 + (mode == "band150" ? 150 : 400))
    let page = scrollingSolidAreaPage(width: width, height: pageHeight, band: band,
      nearUniform: mode == "nearUniform")
    let footerHeight = mode == "footerBand" ? 80 : 0
    let footer = (0..<(width * footerHeight)).flatMap { _ -> [UInt8] in [35, 35, 35, 255] }
    let bodyHeight = frameHeight - footerHeight
    let lastOffset = pageHeight - bodyHeight
    var offsets = Array(Swift.stride(from: 0, through: lastOffset, by: step))
    if offsets.last != lastOffset { offsets.append(lastOffset) }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight,
      maximumPixels: width * (pageHeight + footerHeight + 1))
    for offset in offsets {
      let end = offset + bodyHeight
      let frame = Array(page[(offset * stride)..<(end * stride)]) + footer
      let accepted = stitcher.append(rgba: frame)
      #expect(accepted, "\(mode), step \(step), offset \(offset)")
      if accepted {
        let pixels = stitcher.pixels
        let expected = Array(page.prefix(end * stride)) + footer
        #expect({ pixels == expected }(), "\(mode), step \(step), offset \(offset)")
        #expect(stitcher.height == offset + frameHeight)
      }
    }
    #expect(stitcher.height == pageHeight + footerHeight)
    #expect({ stitcher.pixels == page + footer }())
  }

  @Test("Featureless overlap stalls without removing accepted pixels")
  func scrollingFeaturelessGap() {
    let width = 32
    let frameHeight = 800
    let stride = width * 4
    let page = scrollingSolidAreaPage(width: width, height: 2400, band: 768..<1468)
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: width * 2401)
    var rejected = 0
    for offset in Swift.stride(from: 0, through: 1536, by: 128) {
      let height = stitcher.height
      let pixels = stitcher.pixels
      let frame = Array(page[(offset * stride)..<((offset + frameHeight) * stride)])
      let accepted = stitcher.append(rgba: frame)
      #expect(accepted == (offset <= 640), "offset \(offset)")
      if accepted {
        #expect(stitcher.height == offset + frameHeight)
        #expect({ stitcher.pixels == Array(page.prefix((offset + frameHeight) * stride)) }())
      } else {
        rejected += 1
        #expect(stitcher.height == height)
        #expect({ stitcher.pixels == pixels }(), "rejected offset \(offset)")
      }
    }
    #expect(rejected == 7)
    #expect(stitcher.height == 1440)
  }

  @Test("Downward scrolling appends only new rows, including repeated captures")
  func scrollingDown() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 100)
    #expect({ stitcher.append(rgba: scrollingFrame(0)) }())
    #expect({ stitcher.append(rgba: scrollingFrame(6)) }())
    #expect(stitcher.height == 30)
    #expect({ stitcher.append(rgba: scrollingFrame(12)) }())
    #expect(stitcher.height == 36)
    #expect(stitcher.pixels == scrollingFrame(0) + Array(scrollingFrame(6).suffix(6 * 32))
      + Array(scrollingFrame(12).suffix(6 * 32)))
  }

  @Test("Unmatched changed frames are distinct from unchanged, upward, invalid and capped frames")
  func scrollingAppendClassification() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 100)
    #expect({ !stitcher.append(rgba: []) }())
    #expect(stitcher.appendResult == .invalid)
    #expect({ stitcher.append(rgba: scrollingFrame(12)) }())
    #expect(stitcher.appendResult == .appended)
    let pixels = stitcher.pixels
    #expect({ !stitcher.append(rgba: scrollingFrame(12)) }())
    #expect(stitcher.appendResult == .unchanged)
    #expect({ !stitcher.append(rgba: scrollingFrame(6)) }())
    #expect(stitcher.appendResult == .upward)
    #expect({ !stitcher.append(rgba: scrollingFrame(29)) }())
    #expect(stitcher.appendResult == .unmatched)
    #expect({ !stitcher.append(rgba: scrollingFrame(29)) }())
    #expect(stitcher.appendResult == .unchanged)
    #expect({ !stitcher.append(rgba: scrollingFrame(12)) }())
    #expect(stitcher.appendResult == .unchanged)
    #expect(stitcher.pixels == pixels)
    #expect({ stitcher.append(rgba: scrollingFrame(18)) }())
    #expect(stitcher.appendResult == .appended)

    var capped = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 24)
    #expect({ capped.append(rgba: scrollingFrame(0)) }())
    #expect({ !capped.append(rgba: scrollingFrame(17)) }())
    #expect(capped.appendResult == .capped)
  }

  @Test("Slow-scroll hint counts changed failures, survives polling and clears on a successful stitch")
  func scrollingSlowScrollHint() {
    var state = ScrollingScreenshotHintState()
    #expect(!state.shouldShowSlowScrollHint)
    state.record(.unmatched)
    #expect(!state.shouldShowSlowScrollHint)
    state.record(.unchanged)
    state.record(.invalid)
    #expect(state.consecutiveFailures == 1)
    state.record(.unmatched)
    #expect(state.shouldShowSlowScrollHint)
    state.record(.unchanged)
    state.record(.unmatched)
    #expect(state.shouldShowSlowScrollHint)
    #expect(state.consecutiveFailures == 2)
    state.record(.appended)
    #expect(!state.shouldShowSlowScrollHint)
    state.record(.unmatched)
    state.record(.upward)
    state.record(.unmatched)
    #expect(!state.shouldShowSlowScrollHint)
    state.record(.capped)
    #expect(state.consecutiveFailures == 0)
    #expect(!state.shouldShowSlowScrollHint)
  }

  @Test("Speed warnings require risky successful shifts, with strict thresholds and calm-frame hysteresis")
  func scrollingSpeedWarning() {
    var state = ScrollingScreenshotHintState()
    for shift in [0, 8, 21, 49, 50, 70, 70] {
      state.record(.appended, shift: shift, maximumShift: 100)
      #expect(state.warning == .normal)
    }
    state.record(.appended, shift: 71, maximumShift: 100)
    #expect(state.warning == .normal)
    state.record(.appended, shift: 71, maximumShift: 100)
    #expect(state.warning == .tooFast)
    state.record(.appended, shift: 49, maximumShift: 100)
    state.record(.appended, shift: 49, maximumShift: 100)
    #expect(state.warning == .tooFast)
    state.record(.appended, shift: 49, maximumShift: 100)
    #expect(state.warning == .normal)
    state.record(.appended, shift: 85, maximumShift: 100)
    #expect(state.warning == .normal)
    state.record(.unchanged)
    state.record(.appended, shift: 86, maximumShift: 100)
    #expect(state.warning == .tooFast)
    state.record(.unchanged, now: .seconds(2))
    state.record(.unchanged, now: .milliseconds(2999))
    #expect(state.warning == .tooFast)
    state.record(.unchanged, now: .seconds(3))
    #expect(state.warning == .normal)
    state.record(.appended, shift: nil, maximumShift: 0)
    state.record(.invalid, shift: 100, maximumShift: 100)
    #expect(state.warning == .normal)
  }

  @Test("Lost track takes precedence over speed and survives idle time until re-anchoring")
  func scrollingWarningPrecedence() {
    var state = ScrollingScreenshotHintState()
    state.record(.appended, shift: 90, maximumShift: 100)
    #expect(state.warning == .tooFast)
    state.record(.unmatched)
    state.record(.unmatched)
    #expect(state.warning == .lostTrack)
    state.record(.unchanged, now: .seconds(1))
    state.record(.unchanged, now: .seconds(5))
    state.record(.upward)
    #expect(state.warning == .lostTrack)
    state.record(.reanchored)
    #expect(state.warning == .normal)
  }

  @Test("Accepted shift and candidate-search limit are exposed without stale values on failures")
  func scrollingShiftExposure() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 200)
    stitcher.append(rgba: scrollingFrame(0))
    #expect(stitcher.matchedShift == nil)
    #expect(stitcher.maximumMatchableShift == 16)
    stitcher.append(rgba: scrollingFrame(6))
    #expect(stitcher.matchedShift == 6)
    #expect(stitcher.maximumMatchableShift == 16)
    stitcher.append(rgba: scrollingFrame(6))
    #expect(stitcher.matchedShift == nil)
    stitcher.append(rgba: [])
    #expect(stitcher.matchedShift == nil)
    #expect(stitcher.appendResult == .invalid)
    stitcher.append(rgba: scrollingFrame(90))
    #expect(stitcher.matchedShift == nil)
  }

  @Test("Loss freezes the canvas; small and large scroll-backs re-anchor without rewriting stored rows",
        arguments: [12, 66])
  func scrollingReanchor(offset: Int) {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 300)
    var truth = scrollingFrame(0)
    for start in stride(from: 0, through: 72, by: 6) {
      #expect({ stitcher.append(rgba: scrollingFrame(start)) }())
      if start > 0 { truth += scrollingFrame(start).suffix(6 * 8 * 4) }
    }
    stitcher.append(rgba: scrollingFrame(120))
    stitcher.append(rgba: scrollingFrame(150))
    #expect(stitcher.isLost)
    #expect({ stitcher.pixels == truth }())
    #expect({ !stitcher.append(rgba: scrollingFrame(offset)) }())
    #expect(stitcher.appendResult == .reanchored)
    #expect(!stitcher.isLost)
    #expect({ stitcher.pixels == truth }())
    for start in stride(from: offset + 6, through: 90, by: 6) {
      stitcher.append(rgba: scrollingFrame(start))
      if start > 72 { truth += scrollingFrame(start).suffix(6 * 8 * 4) }
      #expect({ stitcher.pixels == truth }())
    }
    #expect(stitcher.height == 114)
  }

  @Test("Repeated look-alike positions and empty frames cannot re-anchor a lost capture")
  func scrollingAmbiguousReanchor() {
    func frame(_ start: Int) -> [UInt8] {
      (start..<(start + 24)).flatMap { row in
        Array(scrollingFrame((72..<96).contains(row) ? row - 72 : row).prefix(8 * 4))
      }
    }
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 300)
    for start in stride(from: 0, through: 72, by: 6) { stitcher.append(rgba: frame(start)) }
    let original = stitcher.pixels
    stitcher.append(rgba: frame(150))
    stitcher.append(rgba: frame(180))
    #expect(stitcher.isLost)
    stitcher.append(rgba: frame(0))
    #expect(stitcher.isLost)
    stitcher.append(rgba: [UInt8](repeating: 255, count: 8 * 24 * 4))
    #expect(stitcher.isLost)
    #expect({ stitcher.pixels == original }())
  }

  @Test("Processor reports match failures and hint recovery even without a refreshed thumbnail")
  func scrollingProcessorHint() async throws {
    func frame(_ start: Int) throws -> CGImage {
      var source = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 100)
      source.append(rgba: scrollingFrame(start))
      return try #require(source.image)
    }
    let processor = ScrollingScreenshotProcessor()
    let initial = try await processor.append(frame(12), refreshPreview: true, maximumPixels: 8 * 100)
    #expect(initial.appendResult == .appended)
    #expect(!initial.showSlowScrollHint)
    let first = try await processor.append(frame(29), refreshPreview: false, maximumPixels: 8 * 100)
    #expect(first.appendResult == .unmatched)
    #expect(!first.showSlowScrollHint)
    let repeated = try await processor.append(frame(29), refreshPreview: false, maximumPixels: 8 * 100)
    #expect(repeated.appendResult == .unchanged)
    #expect(!repeated.showSlowScrollHint)
    let second = try await processor.append(frame(35), refreshPreview: false, maximumPixels: 8 * 100)
    #expect(second.appendResult == .unmatched)
    #expect(second.showSlowScrollHint)
    #expect(second.thumbnail == nil)
    #expect(second.height == 24)
    let recovered = try await processor.append(frame(18), refreshPreview: false, maximumPixels: 8 * 100)
    #expect(recovered.appendResult == .reanchored)
    #expect(!recovered.showSlowScrollHint)
    #expect(recovered.thumbnail == nil)
    #expect(recovered.height == 24)
    let resumed = try await processor.append(frame(20), refreshPreview: false, maximumPixels: 8 * 100)
    #expect(resumed.appendResult == .appended)
    #expect(resumed.height == 32)
  }

  @Test("Changing the long screenshot hint does not resize the panel")
  func scrollingHintPanelSize() {
    let panel = ScrollingScreenshotPanel(beside: NSRect(x: 20, y: 20, width: 400, height: 400),
      bounds: NSRect(x: 0, y: 0, width: 1200, height: 900), level: 0)
    let size = panel.frame.size
    for warning: ScrollingScreenshotHintState.Warning in [.tooFast, .lostTrack, .normal] {
      panel.updateHint(capped: false, warning: warning)
      panel.contentView?.layoutSubtreeIfNeeded()
      #expect(panel.frame.size == size)
      #expect(panel.contentView?.layer?.borderWidth == (warning == .normal ? 0 : 2))
    }
    panel.close()
  }

  @Test("Sticky header and footer are retained exactly once")
  func scrollingStickyEdges() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    let first = scrollingFrame(0, header: 3, footer: 2)
    let next = scrollingFrame(6, header: 3, footer: 2)
    #expect({ stitcher.append(rgba: first) }())
    #expect({ stitcher.append(rgba: next) }())
    #expect(stitcher.height == 30)
    #expect(stitcher.pixels == Array(first.prefix(22 * 32)) + Array(next.suffix(8 * 32)))
  }

  @Test("Changing footer heights do not leave old toolbar rows in the content", arguments: [false, true])
  func scrollingChangingFooter(grows: Bool) {
    let width = 1031
    let frameHeight = 800
    let stride = width * 4
    let offsets = [0, 37, 90, 131]
    let strip = scrollingTextContent(width: width, height: frameHeight + 131)
    let topRow = (0..<width).flatMap { _ -> [UInt8] in [176, 24, 112, 255] }
    let bottomRow = (0..<width).flatMap { _ -> [UInt8] in [24, 112, 176, 255] }
    let top = (0..<20).flatMap { _ in topRow }
    let bottom = (0..<20).flatMap { _ in bottomRow }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: width * 1100)
    for (index, offset) in offsets.enumerated() {
      let footerHeight = (index < 2) == grows ? 20 : 40
      let footer = footerHeight == 40 ? top + bottom : bottom
      let end = offset + frameHeight - footerHeight
      let frame = Array(strip[(offset * stride)..<(end * stride)]) + footer
      #expect({ stitcher.append(rgba: frame) }())
      let pixels = stitcher.pixels
      #expect(pixels == Array(strip.prefix(end * stride)) + footer)
      #expect(stitcher.height == offset + frameHeight)
      if footerHeight == 20 {
        let hasRemovedBarRow = (0..<stitcher.height).contains { row in
          pixels[(row * stride)..<((row + 1) * stride)].elementsEqual(topRow)
        }
        #expect(!hasRemovedBarRow)
      }
    }
  }

  @Test("A shrinking footer does not invalidate a large scroll overlap")
  func scrollingShrinkingFooterLargeShift() {
    let width = 1031
    let frameHeight = 500
    let stride = width * 4
    let offsets = [0, 128, 256, 384]
    let strip = scrollingTextContent(width: width, height: frameHeight + 384)
    let top = (0..<(width * 20)).flatMap { _ -> [UInt8] in [176, 24, 112, 255] }
    let bottom = (0..<(width * 20)).flatMap { _ -> [UInt8] in [24, 112, 176, 255] }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: frameHeight, maximumPixels: width * 1000)
    for offset in offsets {
      let footerHeight = offset < 256 ? 40 : 20
      let footer = footerHeight == 40 ? top + bottom : bottom
      let end = offset + frameHeight - footerHeight
      let frame = Array(strip[(offset * stride)..<(end * stride)]) + footer
      #expect({ stitcher.append(rgba: frame) }())
      #expect(stitcher.height == offset + frameHeight)
      #expect({ stitcher.pixels == Array(strip.prefix(end * stride)) + footer }())
    }
  }

  @Test("Cold shrinking footers are replaced at large shifts", arguments: [800, 1200])
  func scrollingColdShrinkingFooter(frameHeight: Int) {
    let width = 1031
    let stride = width * 4
    let headerHeight = 60
    let band = frameHeight - headerHeight - 80
    let limit = band - max(4, band / 3)
    let strip = scrollingTextContent(width: width, height: frameHeight + limit)
    let header = (0..<(width * headerHeight)).flatMap { _ -> [UInt8] in [120, 200, 220, 255] }
    let removedRow = (0..<width).flatMap { _ -> [UInt8] in [176, 24, 112, 255] }
    let top = (0..<40).flatMap { _ in removedRow }
    let bottom = (0..<(width * 40)).flatMap { _ -> [UInt8] in [24, 112, 176, 255] }
    for shift in [300, 400, limit, limit + 1] {
      var stitcher = ScrollingScreenshotStitcher(
        width: width, height: frameHeight, maximumPixels: width * 3000
      )
      let firstEnd = frameHeight - headerHeight - 80
      let first = header + Array(strip.prefix(firstEnd * stride)) + top + bottom
      let end = shift + frameHeight - headerHeight - 40
      let next = header + Array(strip[(shift * stride)..<(end * stride)]) + bottom
      #expect({ stitcher.append(rgba: first) }())
      if shift > limit {
        #expect({ !stitcher.append(rgba: next) }())
        #expect({ stitcher.pixels == first }())
      } else {
        #expect({ stitcher.append(rgba: next) }())
        #expect(stitcher.height == frameHeight + shift)
        #expect({ stitcher.pixels == header + Array(strip.prefix(end * stride)) + bottom }())
        let pixels = stitcher.pixels
        let hasRemovedRow = (0..<stitcher.height).contains { row in
          pixels[(row * stride)..<((row + 1) * stride)].elementsEqual(removedRow)
        }
        #expect(!hasRemovedRow)
      }
    }
  }

  @Test("Changed body rows are not inferred as a footer", arguments: [false, true])
  func scrollingChangedBodyRows(atBottom: Bool) {
    let width = 1031
    let frameHeight = 800
    let stride = width * 4
    let shift = 300
    let strip = scrollingTextContent(width: width, height: frameHeight + shift)
    let first = Array(strip.prefix(frameHeight * stride))
    var next = Array(strip[(shift * stride)..<((frameHeight + shift) * stride)])
    let comparisonEnd = frameHeight - shift
    let rows = atBottom ? (comparisonEnd - frameHeight / 4 - 1)..<comparisonEnd : 150..<250
    let changedRow = (0..<width).flatMap { _ -> [UInt8] in [176, 24, 112, 255] }
    for row in rows { next.replaceSubrange((row * stride)..<((row + 1) * stride), with: changedRow) }
    var stitcher = ScrollingScreenshotStitcher(
      width: width, height: frameHeight, maximumPixels: width * 3000
    )
    #expect({ stitcher.append(rgba: first) }())
    #expect({ !stitcher.append(rgba: next) }())
    #expect(stitcher.height == frameHeight)
    #expect({ stitcher.pixels == first }())
  }

  @Test("Shrinking footers respect the height cap while replacing the entire old bar")
  func scrollingShrinkingFooterCap() {
    let width = 1031
    let frameHeight = 800
    let maximumHeight = 850
    let stride = width * 4
    let strip = scrollingTextContent(width: width, height: 890)
    let top = (0..<(width * 20)).flatMap { _ -> [UInt8] in [176, 24, 112, 255] }
    let bottom = (0..<(width * 20)).flatMap { _ -> [UInt8] in [24, 112, 176, 255] }
    var stitcher = ScrollingScreenshotStitcher(
      width: width, height: frameHeight, maximumPixels: width * maximumHeight
    )
    for offset in [0, 37, 90] {
      let footerHeight = offset < 90 ? 40 : 20
      let footer = footerHeight == 40 ? top + bottom : bottom
      let frame = Array(strip[(offset * stride)..<((offset + frameHeight - footerHeight) * stride)]) + footer
      #expect({ stitcher.append(rgba: frame) }())
    }
    #expect(stitcher.capReached)
    #expect(stitcher.height == maximumHeight)
    let pixels = stitcher.pixels
    #expect(pixels == Array(strip.prefix((maximumHeight - 20) * stride)) + bottom)
    #expect({ !stitcher.append(rgba: Array(strip.prefix(760 * stride)) + top + bottom) }())
    #expect(stitcher.pixels == pixels)
  }

  @Test("Unchanged, upward, jumped, blank and malformed frames do not extend a capture")
  func scrollingIgnoredFrames() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ stitcher.append(rgba: scrollingFrame(12)) }())
    let original = stitcher.pixels
    #expect({ !stitcher.append(rgba: scrollingFrame(12)) }())
    #expect({ !stitcher.append(rgba: scrollingFrame(6)) }())
    #expect({ !stitcher.append(rgba: scrollingFrame(100)) }())
    #expect({ !stitcher.append(rgba: [UInt8](repeating: 255, count: 8 * 24 * 4)) }())
    #expect({ !stitcher.append(rgba: []) }())
    #expect(stitcher.pixels == original)
    var blank = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ blank.append(rgba: [UInt8](repeating: 255, count: 8 * 24 * 4)) }())
    #expect({ !blank.append(rgba: [UInt8](repeating: 254, count: 8 * 24 * 4)) }())
    #expect(blank.height == 24)
  }

  @Test("Height cap truncates new body rows and retains the latest footer")
  func scrollingHeightCap() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 27)
    #expect({ stitcher.append(rgba: scrollingFrame(0, header: 3, footer: 2)) }())
    let next = scrollingFrame(6, header: 3, footer: 2)
    #expect({ stitcher.append(rgba: next) }())
    #expect(stitcher.capReached)
    #expect(stitcher.height == 27)
    #expect(Array(stitcher.pixels.suffix(2 * 32)) == Array(next.suffix(2 * 32)))
    #expect({ !stitcher.append(rgba: scrollingFrame(12, header: 3, footer: 2)) }())
  }

  @Test("Bitmap adapter preserves image orientation")
  func scrollingBitmapRoundTrip() throws {
    let bytes = scrollingFrame(0)
    var source = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ source.append(rgba: bytes) }())
    let image = try #require(source.image)
    var destination = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ destination.append(image) }())
    #expect(destination.pixels == source.pixels)
  }

  @Test("Tiny RGB noise does not prevent overlap matching")
  func scrollingPixelNoise() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ stitcher.append(rgba: scrollingFrame(0)) }())
    let noisy = scrollingFrame(6).enumerated().map { index, value in index % 4 == 3 ? value : value + 1 }
    #expect({ stitcher.append(rgba: noisy) }())
    #expect(stitcher.height == 30)
  }

  @Test("Parallel signature tiles preserve every row across uneven frame dimensions")
  func scrollingParallelRows() {
    let width = 1031
    let height = 1001
    let shift = 37
    var strip = [UInt8](repeating: 255, count: width * (height + shift) * 4)
    var state: UInt64 = 123
    for index in stride(from: 0, to: strip.count, by: 4) {
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let value = UInt8(truncatingIfNeeded: state >> 32)
      strip[index] = value
      strip[index + 1] = value
      strip[index + 2] = value
    }
    var stitcher = ScrollingScreenshotStitcher(width: width, height: height, maximumPixels: width * 2000)
    #expect({ stitcher.append(rgba: Array(strip.prefix(width * height * 4))) }())
    #expect({ stitcher.append(rgba: Array(strip.dropFirst(width * shift * 4))) }())
    #expect(stitcher.height == height + shift)
    #expect(stitcher.pixels == strip)
  }

  @Test("Thumbnails own their pixels and leave the full capture intact")
  func scrollingThumbnailOwnership() throws {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect(stitcher.thumbnail() == nil)
    let original = scrollingFrame(0)
    stitcher.append(rgba: original)
    #expect(stitcher.thumbnail(maximumWidth: 0) == nil)
    let thumbnail = try #require(stitcher.thumbnail(maximumWidth: 8, maximumHeight: 24))
    #expect({ stitcher.append(rgba: scrollingFrame(6)) }())
    var snapshot = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ snapshot.append(thumbnail) }())
    #expect(snapshot.pixels == original)
    let stitchedThumbnail = try #require(stitcher.thumbnail(maximumWidth: 8, maximumHeight: 30))
    var stitchedSnapshot = ScrollingScreenshotStitcher(width: 8, height: 30, maximumPixels: 800)
    #expect({ stitchedSnapshot.append(stitchedThumbnail) }())
    #expect(stitchedSnapshot.pixels == stitcher.pixels)
    let reduced = try #require(stitcher.thumbnail(maximumWidth: 4, maximumHeight: 12))
    #expect(reduced.width <= 4 && reduced.height <= 12)
    #expect(stitcher.height == 30)
  }

  @Test("Chunked captures replace sticky footers across multiple appends and stop at the cap")
  func scrollingChunkedFooters() {
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 8 * 39)
    let first = scrollingFrame(0, header: 3, footer: 2)
    stitcher.append(rgba: first)
    var expected = Array(first.prefix(22 * 32))
    for offset in [6, 12, 18] {
      let frame = scrollingFrame(offset, header: 3, footer: 2)
      #expect({ stitcher.append(rgba: frame) }())
      let count = min(6, 39 - (24 + offset - 6))
      expected.append(contentsOf: frame[(16 * 32)..<((16 + count) * 32)])
      #expect(stitcher.pixels == expected + Array(frame.suffix(2 * 32)))
    }
    #expect(stitcher.height == 39 && stitcher.capReached)
  }

  @Test("The background processor defers previews, flushes at the cap and exports the full PNG")
  func scrollingProcessorOutput() async throws {
    let processor = ScrollingScreenshotProcessor()
    #expect(try await processor.export() == nil)
    var first = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    first.append(rgba: scrollingFrame(0))
    let firstImage = try #require(first.image)
    let initial = try await processor.append(firstImage, refreshPreview: false, maximumPixels: 8 * 30)
    #expect(initial.thumbnail == nil && initial.height == 24 && !initial.capReached)
    let refreshed = try await processor.append(firstImage, refreshPreview: true, maximumPixels: 8 * 30)
    #expect(refreshed.thumbnail != nil)
    let unchanged = try await processor.append(firstImage, refreshPreview: true, maximumPixels: 8 * 30)
    #expect(unchanged.thumbnail == nil)
    var next = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    next.append(rgba: scrollingFrame(6))
    let nextImage = try #require(next.image)
    let capped = try await processor.append(nextImage, refreshPreview: false, maximumPixels: 8 * 30)
    #expect(capped.thumbnail != nil && capped.capReached && capped.height == 30)
    let output = try #require(try await processor.export())
    let result = try ScreenshotCaptureSession.ValidatedImage.validate(output.data)
    #expect(result.image.width == 8 && result.image.height == 30)
    #expect(output.image.width == result.image.width && output.image.height == result.image.height)
    let pixelData = try #require(output.image.dataProvider?.data)
    #expect(pixelData as Data == Data(scrollingFrame(0) + scrollingFrame(6).suffix(6 * 32)))
    #expect(try await processor.export() == nil)
  }

  @Test("The background processor rejects invalid budgets and cancelled work")
  func scrollingProcessorCancellation() async throws {
    let processor = ScrollingScreenshotProcessor()
    var source = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    source.append(rgba: scrollingFrame(0))
    let image = try #require(source.image)
    await #expect(throws: ScrollingScreenshotProcessor.Failure.self) {
      try await processor.append(image, refreshPreview: true, maximumPixels: 1)
    }
    let task = Task { try await processor.append(image, refreshPreview: true, maximumPixels: 800) }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await processor.export() == nil)
  }

  @Test("A failed export consumes the stitched frames", arguments: [false, true])
  func scrollingFailedExportReleasesFrames(invalidEdit: Bool) async throws {
    let processor = ScrollingScreenshotProcessor()
    var source = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    source.append(rgba: scrollingFrame(0))
    let image = try #require(source.image)
    _ = try await processor.append(image, refreshPreview: false, maximumPixels: 800)
    let edit = invalidEdit ? ScrollingScreenshotEdit(width: 7, height: 24, blockSize: 5) : nil
    let output = try await processor.export(edit: edit) { _ in
      #expect(!invalidEdit)
      return nil
    }
    #expect(output == nil)
    #expect(try await processor.editingPreview() == nil)
    #expect(try await processor.export() == nil)
  }

  @Test("Long screenshot crop handles map top-down to full-resolution rows and cannot cross")
  func scrollingCropMapping() {
    var edit = ScrollingScreenshotEdit(width: 700, height: 941, blockSize: 20)
    edit.crop(at: 5.0 / 120, top: true)
    edit.crop(at: 111.0 / 120, top: false)
    #expect(edit.rows == 39..<870)
    edit.crop(at: -1, top: false)
    #expect(edit.rows == 39..<40)
    edit.crop(at: 2, top: true)
    #expect(edit.rows == 39..<40)
    edit.crop(at: 2, top: false)
    edit.crop(at: -1, top: true)
    #expect(edit.rows == 0..<941)
  }

  @Test("Edited PNG and thumbnail share the trimmed rows and mosaic across a chunk boundary")
  func scrollingEditedExport() async throws {
    let processor = ScrollingScreenshotProcessor()
    for offset in [0, 6] {
      var frame = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
      frame.append(rgba: scrollingFrame(offset))
      let image = try #require(frame.image)
      _ = try await processor.append(image, refreshPreview: false, maximumPixels: 800)
    }
    let editing = try #require(try await processor.editingPreview())
    #expect(editing.width == 8 && editing.height == 30)
    var edit = ScrollingScreenshotEdit(width: 8, height: 30, blockSize: 5)
    edit.crop(at: 3.0 / 30, top: true)
    edit.crop(at: 27.0 / 30, top: false)
    edit.paint(CGRect(x: 6.0 / 8, y: 23.0 / 30, width: 1.0 / 8, height: 1.0 / 30))
    #expect(edit.cells == [.init(x: 1, y: 4)])

    let output = try #require(try await processor.export(includePreview: true, edit: edit))
    let decoded = try ScreenshotCaptureSession.ValidatedImage.validate(output.data).image
    let thumbnail = try #require(output.preview)
    let original = scrollingFrame(0) + scrollingFrame(6).suffix(6 * 32)
    var expected = Array(original[(3 * 32)..<(27 * 32)])
    for channel in 0..<4 {
      var sum = 0
      for row in 20..<25 {
        for column in 5..<8 { sum += Int(original[row * 32 + column * 4 + channel]) }
      }
      for row in 17..<22 {
        for column in 5..<8 { expected[row * 32 + column * 4 + channel] = UInt8(sum / 15) }
      }
    }
    for image in [output.image, decoded, thumbnail] {
      #expect(image.width == 8 && image.height == 24)
      #expect(try scrollingImagePixels(image) == expected)
    }
  }

  @Test("Text-like glyph rows stitch exactly after uneven scrolls under a sticky header")
  func scrollingTextStrip() {
    let width = 1031
    let headerHeight = 13
    let bodyHeight = 180
    let stride = width * 4
    let offsets = [0, 37, 90]
    let sourceHeight = bodyHeight + (offsets.last ?? 0)
    let strip = scrollingTextContent(width: width, height: sourceHeight)
    let header = [UInt8](repeating: 192, count: headerHeight * stride)
      .enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : $0.element }
    var stitcher = ScrollingScreenshotStitcher(
      width: width, height: headerHeight + bodyHeight, maximumPixels: width * 1000
    )
    for offset in offsets {
      let frame = header + Array(strip[(offset * stride)..<((offset + bodyHeight) * stride)])
      #expect({ stitcher.append(rgba: frame) }())
      #expect(stitcher.pixels == header + Array(strip.prefix((bodyHeight + offset) * stride)))
    }
  }

  @Test("Repeated list rows with indistinguishable overlaps are not guessed")
  func scrollingPeriodicRows() {
    let first = (0..<6).flatMap { _ in Array(scrollingFrame(0).prefix(4 * 32)) }
    let shifted = Array(first.dropFirst(32)) + Array(first.prefix(32))
    var stitcher = ScrollingScreenshotStitcher(width: 8, height: 24, maximumPixels: 800)
    #expect({ stitcher.append(rgba: first) }())
    #expect({ !stitcher.append(rgba: shifted) }())
    #expect(stitcher.pixels == first)
  }

  @Test("Tall capture pins are reduced to fit the target display")
  func scrollingPinFitsScreen() {
    let visible = NSRect(x: -1000, y: 0, width: 1000, height: 800)
    let capture = NSRect(x: -800, y: -4400, width: 400, height: 5000)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: capture.size, visibleFrame: visible, anchor: NSPoint(x: -600, y: 599), captureFrame: capture
    )
    #expect(visible.contains(frame))
    #expect(abs(frame.width / frame.height - capture.width / capture.height) < 0.001)
  }

  @Test("Global capture defaults use bare function keys and leave optional actions unassigned")
  func globalCaptureShortcutDefaults() {
    #expect(KeyboardShortcuts.Name.screenshot.initialShortcut == nil)
    #expect(KeyboardShortcuts.Name.screenshotSelection.initialShortcut == KeyboardShortcuts.Shortcut(.f1))
    #expect(KeyboardShortcuts.Name.pinScreenshot.initialShortcut == KeyboardShortcuts.Shortcut(.f3))
    #expect(KeyboardShortcuts.Name.pinClipboardImage.initialShortcut == nil)
  }

  @Test("Pin estimates reject oversized, empty and overflowing pixel dimensions")
  func pinPixelLimits() {
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 10_000, pixelHeight: 10_000) == 400_000_000)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 10_001, pixelHeight: 10_000) == nil)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: Int.max, pixelHeight: Int.max) == nil)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 0, pixelHeight: 100) == nil)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 100, pixelHeight: -1) == nil)
    var budget = PinnedImageBudget()
    #expect(!budget.canAdd(400_000_004))
    let oversizedAdded = budget.add(UUID(), bytes: 400_000_004)
    #expect(!oversizedAdded)
    #expect(!budget.canAdd(0))
    #expect(budget.total == 0)
  }

  @Test("Pin budget reaches the aggregate limit and removing pins frees capacity")
  func aggregatePinBudget() {
    var budget = PinnedImageBudget()
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let firstAdded = budget.add(first, bytes: 400_000_000)
    let secondAdded = budget.add(second, bytes: 400_000_000)
    #expect(firstAdded && secondAdded)
    let remaining = PinnedImageBudget.maximumBytes - budget.total
    #expect(budget.canAdd(remaining))
    let thirdAdded = budget.add(third, bytes: remaining)
    #expect(thirdAdded)
    #expect(budget.total == PinnedImageBudget.maximumBytes)
    #expect(!budget.canAdd(4))
    let overflowAdded = budget.add(UUID(), bytes: 4)
    #expect(!overflowAdded)
    budget.remove(first)
    budget.remove(first)
    #expect(budget.total == PinnedImageBudget.maximumBytes - 400_000_000)
    #expect(budget.canAdd(400_000_000))
    let thirdUpdated = budget.add(third, bytes: 4)
    #expect(thirdUpdated)
    #expect(budget.total == 400_000_004)
    budget.remove(second)
    budget.remove(third)
    #expect(budget.total == 0)
  }

  @Test("Pin estimates use the largest bitmap pixels rather than Retina points")
  func retinaPinEstimate() throws {
    let retina = try #require(NSBitmapImageRep(data: generatedPNG()))
    retina.size = NSSize(width: 4, height: 4)
    let small = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    ))
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.addRepresentation(small)
    image.addRepresentation(retina)
    #expect(PinnedImageBudget.estimatedBytes(for: image) == 8 * 8 * 4)
  }

  @Test("Pinned image context menus route close-all through the coordinator callback")
  func closeAllPinnedAction() throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    var calls = 0
    window.onCloseAll = { calls += 1 }
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let menu = try #require(imageView.menu)
    let item = try #require(menu.items.last)
    #expect(item.action == #selector(PinnedScreenshotWindow.closeAllImages))
    #expect(item.target === window)
    window.perform(item.action)
    #expect(calls == 1)
    window.close()
    #expect(window.onCloseAll == nil)
  }

  @Test("PNG validation decodes one full-resolution image off-main")
  func validatedImage() async throws {
    let data = try generatedPNG()
    let result = try await Task.detached {
      try ScreenshotCaptureSession.ValidatedImage.validate(data)
    }.value
    #expect(result.data == data)
    #expect(result.image.width == 8 && result.image.height == 8)
  }

  @Test("PNG validation rejects truncated and non-image data")
  func malformedImageData() throws {
    let data = try generatedPNG()
    for invalid in [Data(), Data("not an image".utf8), Data(data.prefix(24)), Data(data.dropLast(20))] {
      #expect(throws: ScreenshotCaptureSession.Failure.invalidImage) {
        try ScreenshotCaptureSession.ValidatedImage.validate(invalid)
      }
    }
  }

  @Test("PNG validation rejects images exceeding the pixel limit before decoding")
  func oversizedImageData() throws {
    let data = try generatedPNG()
    #expect(throws: ScreenshotCaptureSession.Failure.invalidImage) {
      try ScreenshotCaptureSession.ValidatedImage.validate(data, maximumPixels: 63)
    }
    #expect(try ScreenshotCaptureSession.ValidatedImage.validate(data, maximumPixels: 64).image.width == 8)
  }

  @Test("A history save failure does not block screenshot output", arguments: [false, true])
  func deliverWithHistoryResult(historyFails: Bool) throws {
    let data = try generatedPNG()
    let storageError = CocoaError(.persistentStoreSave)
    var steps: [String] = []
    let result = try ScreenshotCapture.deliverScreenshot(data, copy: { copied in
      #expect(copied == data)
      steps.append("copy")
      return true
    }, saveHistory: { saved in
      #expect(saved == data)
      steps.append("save")
      if historyFails { throw storageError }
    }, present: {
      steps.append("present")
    })
    #expect(steps == ["copy", "save", "present"])
    switch result {
    case .failure(let error):
      #expect(historyFails)
      #expect((error as? CocoaError)?.code == storageError.code)
    case .success:
      #expect(!historyFails)
    }
  }

  @Test("A clipboard write failure does not add screenshot history")
  func failedClipboardDelivery() throws {
    let data = try generatedPNG()
    #expect(throws: ScreenshotCaptureSession.Failure.clipboardWrite) {
      try ScreenshotCapture.deliverScreenshot(data, copy: { _ in false }, saveHistory: { _ in
        Issue.record("History was saved after a clipboard failure")
      }, present: {
        Issue.record("Output was presented after a clipboard failure")
      })
    }
  }

  @Test("Capture is silent and noninteractive; region coordinates support displays left of the main display")
  func captureArguments() {
    let output = URL(fileURLWithPath: "/private/tmp/generated-capture.png")
    let rectangle = NSRect(x: -1200, y: 120, width: 400, height: 300)
    #expect(ScreenshotCaptureSession.Mode.region(rectangle).arguments(output: output) == [
      "-R-1200,120,400,300", "-x", "-t", "png", output.path
    ])
    #expect(ScreenshotCaptureSession.Mode.mainDisplay.arguments(output: output) == [
      "-m", "-x", "-t", "png", output.path
    ])
  }

  @Test("Display freezing prefers the rectangle screenshot over the filtered rendering")
  func rectangleDisplayCapture() async throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let result = await ScreenshotCaptureSession.captureDisplayImage(rectangleCapture: {
      image
    }, filteredCapture: {
      Issue.record("Filtered rendering was used after a successful rectangle screenshot")
      return image
    })
    #expect(result === image)
  }

  @Test("Captures are color-converted to the source display profile rather than relabeled")
  func captureProfileConversion() throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let profile = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let converted = ScreenshotColorSpace.matchDisplay(image, profile: profile)
    #expect(converted.colorSpace?.isWideGamutRGB == true)
    #expect(converted !== image)
    #expect(ScreenshotColorSpace.matchDisplay(converted, profile: profile) === converted)
    #expect(converted.width == image.width && converted.height == image.height)
  }

  @Test("Display captures require native pixel resolution with one-pixel rounding tolerance")
  func displayCaptureResolution() throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    func accepts(width: CGFloat, height: CGFloat, scale: CGFloat) -> Bool {
      let frame = NSRect(x: 0, y: 0, width: width, height: height)
      let display = ScreenshotSelectionController.Display(frame: frame, captureFrame: frame, scale: scale)
      return ScreenshotCaptureSession.hasSufficientResolution(image, for: display)
    }
    #expect(accepts(width: 8, height: 8, scale: 1))
    #expect(accepts(width: 7, height: 7, scale: 1))
    #expect(accepts(width: 9, height: 9, scale: 1))
    #expect(!accepts(width: 10, height: 8, scale: 1))
    #expect(!accepts(width: 8, height: 10, scale: 1))
    #expect(accepts(width: 4, height: 4, scale: 2))
    #expect(!accepts(width: 8, height: 8, scale: 2))
    #expect(accepts(width: 4.7, height: 4.7, scale: 2))
    #expect(!accepts(width: 4.8, height: 4.8, scale: 2))
  }

  @Test("Display capture resolution uses the current mode's pixel dimensions, not the AppKit backing factor")
  func scaledDisplayCaptureResolution() throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let frame = CGRect(x: 0, y: 0, width: 4, height: 4)
    var display = ScreenshotSelectionController.Display(frame: frame, captureFrame: frame, scale: 2)
    #expect(ScreenshotCaptureSession.hasSufficientResolution(image, for: display))
    display.modePixelSize = CGSize(width: 10, height: 8)
    #expect(!ScreenshotCaptureSession.hasSufficientResolution(image, for: display))
  }

  @Test("Display freezing falls back when rectangle capture is unavailable or fails", arguments: [false, true])
  func filteredDisplayCapture(throwsError: Bool) async throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    var fallbackCalls = 0
    let result = await ScreenshotCaptureSession.captureDisplayImage(rectangleCapture: {
      if throwsError { throw ScreenshotCaptureSession.Failure.captureFailed }
      return nil
    }, filteredCapture: {
      fallbackCalls += 1
      return image
    })
    #expect(result === image)
    #expect(fallbackCalls == 1)
  }

  @Test("Display freezing returns no frozen image when both capture methods fail")
  func failedDisplayCapture() async {
    let result = await ScreenshotCaptureSession.captureDisplayImage(rectangleCapture: {
      throw ScreenshotCaptureSession.Failure.captureFailed
    }, filteredCapture: {
      throw ScreenshotCaptureSession.Failure.captureFailed
    })
    #expect(result == nil)
  }

  @Test("Display freezing with no displays returns no images")
  func emptyDisplayCapture() async {
    let images = await ScreenshotCaptureSession.captureDisplays([])
    #expect(images.isEmpty)
  }

  @Test("Display freezes overlap and keep display order even when a capture fails")
  func concurrentDisplayCapture() async throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let displays = (1...3).map { id in
      ScreenshotSelectionController.Display(
        frame: NSRect(x: 0, y: 0, width: 800, height: 600),
        captureFrame: NSRect(x: 0, y: 0, width: 800, height: 600), scale: 1,
        displayID: CGDirectDisplayID(id), visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
      )
    }
    var completed: [CGDirectDisplayID] = []
    let images = await ScreenshotCaptureSession.captureDisplays(displays, capture: { display in
      try? await Task.sleep(for: .milliseconds(display.displayID == 1 ? 50 : 1))
      completed.append(display.displayID)
      return display.displayID == 2 ? nil : image
    })
    #expect(completed.last == 1)
    #expect(images.count == 3)
    #expect(images[0] === image)
    #expect(images[1] == nil)
    #expect(images[2] === image)
  }

  @Test("Missing region output is an error and temporary files are removed before retry",
        arguments: ["/usr/bin/true", "/usr/bin/false"])
  func missingRegionResult(executable: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, _ in
      process(executable)
    }
    let mode = ScreenshotCaptureSession.Mode.region(NSRect(x: 10, y: 20, width: 40, height: 30))
    await #expect(throws: ScreenshotCaptureSession.Failure.captureFailed) {
      try await session.capture(mode: mode)
    }
    #expect(!session.isCapturing)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    await #expect(throws: ScreenshotCaptureSession.Failure.captureFailed) {
      try await session.capture(mode: mode)
    }
  }

  @Test("A missing full-screen result is an error, not cancellation")
  func missingFullScreenResult() async throws {
    let session = ScreenshotCaptureSession { _, _ in process("/usr/bin/true") }
    await #expect(throws: ScreenshotCaptureSession.Failure.captureFailed) {
      try await session.capture(mode: .mainDisplay)
    }
    #expect(!session.isCapturing)
  }

  @Test("A capture tool that fails to launch releases the session")
  func launchFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, _ in
      process("/nonexistent/maccy-capture-test")
    }
    await #expect(throws: (any Error).self) {
      try await session.capture(mode: .mainDisplay)
    }
    #expect(!session.isCapturing)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Invalid image output never reaches the history pipeline")
  func invalidImage() async throws {
    let session = ScreenshotCaptureSession { _, output in
      process("/usr/bin/touch", arguments: [output.path])
    }
    await #expect(throws: ScreenshotCaptureSession.Failure.invalidImage) {
      try await session.capture(mode: .mainDisplay)
    }
    #expect(!session.isCapturing)
  }

  @Test("Only generated PNG data is returned and private temporary files are removed")
  func generatedImage() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = root.appendingPathComponent("generated.png")
    let data = try generatedPNG()
    try data.write(to: fixture)
    var permissions: Int?
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, output in
      let attributes = try? FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)
      permissions = attributes?[.posixPermissions] as? Int
      return process("/bin/cp", arguments: [fixture.path, output.path])
    }
    let result = try await session.capture(mode: .mainDisplay)
    #expect(result.data == data)
    #expect(result.image.width == 8 && result.image.height == 8)
    #expect(permissions == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["generated.png"])
  }

  @Test("Timeout terminates the child and resets capture state")
  func timeout() async throws {
    let child = process("/bin/sleep", arguments: ["30"])
    let session = ScreenshotCaptureSession { _, _ in child }
    await #expect(throws: ScreenshotCaptureSession.Failure.timedOut) {
      try await session.capture(mode: .mainDisplay, timeout: .milliseconds(50))
    }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
  }

  @Test("Repeated shortcuts cannot create overlapping capture sessions")
  func repeatedCapture() async throws {
    let child = process("/bin/sleep", arguments: ["30"])
    let session = ScreenshotCaptureSession { _, _ in child }
    let first = Task { try await session.capture(mode: .mainDisplay) }
    try await waitForStart(session)
    await #expect(throws: ScreenshotCaptureSession.Failure.alreadyCapturing) {
      try await session.capture(mode: .mainDisplay)
    }
    session.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
  }

  @Test("A stuck capture that ignores termination is killed after timeout")
  func unresponsiveCapture() async throws {
    let child = process("/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"])
    let session = ScreenshotCaptureSession { _, _ in child }
    await #expect(throws: ScreenshotCaptureSession.Failure.timedOut) {
      try await session.capture(mode: .mainDisplay, timeout: .milliseconds(100))
    }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
  }

  @Test("Task cancellation terminates capture and removes temporary files")
  func taskCancellation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = process("/bin/sleep", arguments: ["30"])
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, _ in child }
    let task = Task { try await session.capture(mode: .mainDisplay) }
    try await waitForStart(session)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Pinned images fit within displays with negative coordinates")
  func pinPlacement() {
    let screen = NSRect(x: -1920, y: -1080, width: 1920, height: 1040)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: NSSize(width: 6000, height: 3000),
      visibleFrame: screen,
      anchor: NSPoint(x: -1, y: -1)
    )
    #expect(screen.contains(frame))
    #expect(frame.width <= screen.width)
    #expect(abs(frame.width / frame.height - 2) < 0.001)
  }

  @Test("Capture pins preserve their screen rectangle regardless of pixel density", arguments: [CGFloat(1), CGFloat(2)])
  func capturePinPointSize(scale: CGFloat) {
    let capture = NSRect(x: -1800, y: -900, width: 1500, height: 900)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: NSSize(width: capture.width * scale, height: capture.height * scale),
      visibleFrame: NSRect(x: -1920, y: -1080, width: 1920, height: 1040),
      anchor: NSPoint(x: capture.midX, y: capture.midY), captureFrame: capture
    )
    #expect(frame == capture)
  }

  @Test("A capture pin from a disconnected display opens on the remaining screen")
  func capturePinFromDisconnectedDisplay() {
    let capture = NSRect(x: -640, y: 400, width: 320, height: 160)
    let remainingScreen = NSRect(x: 0, y: 50, width: 800, height: 600)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: capture.size, visibleFrame: remainingScreen,
      anchor: NSPoint(x: capture.midX, y: capture.midY), captureFrame: capture
    )
    #expect(frame == NSRect(x: 0, y: 400, width: 320, height: 160))
  }

  @Test("A lost pin moves to the nearest remaining display")
  func lostPinUsesNearestDisplay() {
    let main = NSRect(x: 0, y: 50, width: 800, height: 600)
    let secondary = NSRect(x: -800, y: -100, width: 800, height: 600)
    let pin = NSRect(x: -1280, y: 300, width: 320, height: 160)
    let recovered = PinnedScreenshotWindow.reachableFrame(pin, in: [main, secondary])
    #expect(recovered == NSRect(x: -800, y: 300, width: 320, height: 160))
    #expect(PinnedScreenshotWindow.reachableFrame(pin, in: []) == pin)
  }

  @Test("Pins with only a sliver visible are recovered without moving reachable pins")
  func partiallyVisiblePins() {
    let main = NSRect(x: 0, y: 50, width: 800, height: 600)
    let secondary = NSRect(x: -800, y: -100, width: 800, height: 600)
    let sliver = NSRect(x: 795, y: 200, width: 320, height: 160)
    #expect(PinnedScreenshotWindow.reachableFrame(sliver, in: [main, secondary])
      == NSRect(x: 480, y: 200, width: 320, height: 160))
    for pin in [
      NSRect(x: 100, y: 100, width: 320, height: 160),
      NSRect(x: -700, y: -50, width: 320, height: 160),
      NSRect(x: 700, y: 200, width: 320, height: 160)
    ] {
      #expect(PinnedScreenshotWindow.reachableFrame(pin, in: [main, secondary]) == pin)
    }
  }

  @Test("A pin too large for the remaining display shrinks without changing its aspect ratio")
  func oversizedPinOnRemainingDisplay() {
    let screen = NSRect(x: 0, y: 50, width: 800, height: 600)
    let pin = NSRect(x: -1400, y: 500, width: 1600, height: 800)
    #expect(PinnedScreenshotWindow.reachableFrame(pin, in: [screen])
      == NSRect(x: 0, y: 250, width: 800, height: 400))
  }

  @Test("A screen change recovers open pins and their saved expanded frames", arguments: [false, true])
  func screenChangeRecoversOpenPin(thumbnail: Bool) throws {
    let screens = NSScreen.screens.map(\.visibleFrame)
    let rightEdge = try #require(screens.map(\.maxX).max())
    let pin = pinnedZoomWindow()
    defer { pin.close() }
    pin.present()
    pin.setFrameOrigin(NSPoint(x: rightEdge + 200, y: pin.frame.minY))
    let lostFrame = pin.frame
    if thumbnail { pin.showThumbnail(in: lostFrame, page: 1, total: 2) }
    try #require(!screens.contains { $0.intersects(lostFrame) })
    try #require(pin.frame == lostFrame && pin.editingFrame == lostFrame)

    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

    #expect(pin.isVisible && screens.contains { $0.contains(pin.frame) })
    #expect(screens.contains { $0.contains(pin.editingFrame) })
    if thumbnail { pin.restoreExpandedPresentation() }
    #expect(screens.contains { $0.contains(pin.frame) })
    #expect(pin.frame.size == lostFrame.size)
  }

  @Test("Clipboard pins use representation point size rather than bitmap pixels")
  func clipboardPinPointSize() throws {
    let bitmap = try #require(NSBitmapImageRep(data: generatedPNG()))
    bitmap.size = NSSize(width: 4, height: 4)
    let image = NSImage(size: .zero)
    image.addRepresentation(bitmap)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: image.size, visibleFrame: NSRect(x: 0, y: 0, width: 100, height: 100),
      anchor: NSPoint(x: 99, y: 99)
    )
    #expect(frame == NSRect(x: 96, y: 96, width: 4, height: 4))
  }

  @Test("Clipboard pins only shrink when their point size exceeds the visible screen")
  func clipboardPinFitsScreen() {
    let screen = NSRect(x: -100, y: 0, width: 100, height: 100)
    for width: CGFloat in [80, 200] {
      let frame = PinnedScreenshotWindow.initialFrame(
        imageSize: NSSize(width: width, height: width / 2), visibleFrame: screen, anchor: .zero
      )
      #expect(frame.size == NSSize(width: min(width, 100), height: min(width, 100) / 2))
      #expect(screen.contains(frame))
    }
  }

  @Test("Invalid clipboard image sizes produce no frame", arguments: [
    NSSize.zero, NSSize(width: -1, height: 100), NSSize(width: CGFloat.infinity, height: 100)
  ])
  func invalidPinPointSize(size: NSSize) {
    #expect(PinnedScreenshotWindow.initialFrame(
      imageSize: size, visibleFrame: NSRect(x: 0, y: 0, width: 100, height: 100), anchor: .zero
    ) == .zero)
  }

  @Test("Presenting a pinned image keeps the current key window")
  func presentingPinnedImageKeepsKeyWindow() throws {
    let visibleFrame = try #require(NSScreen.main?.visibleFrame)
    let current = NSPanel(
      contentRect: NSRect(x: visibleFrame.midX, y: visibleFrame.midY, width: 120, height: 120),
      styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false
    )
    let pin = PinnedScreenshotWindow(
      image: try #require(NSImage(data: generatedPNG())),
      visibleFrame: visibleFrame,
      anchor: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    )
    defer {
      pin.close()
      current.close()
    }
    current.makeKeyAndOrderFront(nil)
    try #require(current.isKeyWindow)

    pin.present()

    #expect(pin.isVisible)
    #expect(!pin.isKeyWindow)
    #expect(!pin.canBecomeKey)
    #expect(current.isKeyWindow)

    pin.focusForInteraction()
    #expect(pin.isKeyWindow)
    current.makeKey()
    #expect(!pin.canBecomeKey)
  }

  @Test("A pinned image has an exit path and close cleanup runs only once")
  func pinnedWindowCloses() throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image,
      visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    var closes = 0
    window.onClose = { closes += 1 }
    #expect(window.level == .floating)
    #expect(!window.canBecomeKey)
    #expect(!window.isReleasedWhenClosed)
    window.cancelOperation(nil)
    window.close()
    #expect(closes == 1)
  }

  @Test("Pinned windows respond to Escape and Command-W without a system event tap",
        arguments: [false, true])
  func pinnedKeyboardExit(commandW: Bool) throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image,
      visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    var closed = false
    window.onClose = { closed = true }
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: commandW ? .command : [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: commandW ? "w" : "\u{1B}", charactersIgnoringModifiers: commandW ? "w" : "\u{1B}",
      isARepeat: false, keyCode: commandW ? 13 : 53
    ))
    if commandW {
      #expect(window.performKeyEquivalent(with: event))
    } else {
      window.keyDown(with: event)
    }
    #expect(closed)
  }

  @Test("Pinned zoom preserves the image point beneath the pointer and the aspect ratio")
  func pinnedZoomAnchor() {
    let frame = NSRect(x: 300, y: 200, width: 400, height: 200)
    let zoomed = PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 800, height: 400), frame: frame, factor: 1.5,
      visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
      anchor: NSPoint(x: 400, y: 250)
    )
    #expect(zoomed == NSRect(x: 250, y: 175, width: 600, height: 300))
  }

  @Test("Thumbnail stacks show one pin, page in order and restore separate pins")
  func pinnedThumbnailStack() {
    let first = pinnedZoomWindow()
    let second = pinnedZoomWindow(size: NSSize(width: 300, height: 200))
    let third = pinnedZoomWindow(size: NSSize(width: 400, height: 100))
    let screen = NSRect(x: -900, y: -600, width: 900, height: 600)
    let stack = PinnedScreenshotStack(visibleFrames: { [screen] })
    let original = first.frame
    first.alphaValue = 0.45
    defer { third.close(); second.close(); first.close() }

    stack.add(first, alongside: [], visibleFrame: screen)
    #expect(first.isVisible && first.thumbnailStack == nil)
    stack.add(second, alongside: [first], visibleFrame: screen)
    stack.add(third, alongside: [], visibleFrame: screen)
    #expect(!first.isVisible && !second.isVisible && third.isVisible)
    #expect(third.frame == NSRect(x: -192, y: -584, width: 176, height: 112))

    stack.scroll(20, precise: true, phase: .began, from: third)
    #expect(stack.visiblePin === third)
    stack.scroll(10, precise: true, phase: .changed, from: third)
    #expect(stack.visiblePin === second && second.isVisible && !third.isVisible)
    stack.scroll(50, precise: true, phase: .changed, from: second)
    #expect(stack.visiblePin === second)
    stack.scroll(0, precise: true, phase: .ended, from: second)
    stack.scroll(1, precise: false, phase: [], from: second)
    #expect(stack.visiblePin === first && first.alphaValue == 1)

    stack.detach(first)
    #expect(first.frame == original && first.alphaValue == 0.45 && first.isVisible)
    #expect(first.thumbnailStack == nil && stack.visiblePin === second)
    let secondExpanded = second.editingFrame
    third.close()
    #expect(stack.pins.isEmpty && second.thumbnailStack == nil)
    #expect(second.isVisible && second.frame == secondExpanded)
  }

  @Test("A moved thumbnail stack stays in place when paging, adding or closing a pin")
  func movedThumbnailStack() {
    let first = pinnedZoomWindow()
    let second = pinnedZoomWindow()
    let third = pinnedZoomWindow()
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let stack = PinnedScreenshotStack()
    let original = first.frame
    defer { second.close(); first.close() }

    stack.add(first, alongside: [], visibleFrame: screen)
    stack.add(second, alongside: [first], visibleFrame: screen)
    second.setFrameOrigin(NSPoint(x: second.frame.minX - 80, y: second.frame.minY + 60))
    let movedFrame = second.frame
    #expect(movedFrame != PinnedScreenshotStack.thumbnailFrame(in: screen))
    stack.step(by: -1, from: second)
    #expect(stack.visiblePin === first && first.frame == movedFrame)

    stack.add(third, alongside: [], visibleFrame: screen)
    #expect(stack.visiblePin === third && third.frame == movedFrame)
    third.close()
    #expect(stack.visiblePin === second && second.frame == movedFrame)
    second.restoreFromThumbnail()
    #expect(first.isVisible && first.thumbnailStack == nil && first.frame == original)
  }

  @Test("Stack paging does not reuse a moved thumbnail's origin on a disconnected display")
  func thumbnailStackPagingAfterDisplayRemoval() {
    let first = pinnedZoomWindow()
    let second = pinnedZoomWindow()
    let originalScreen = NSRect(x: -900, y: -600, width: 900, height: 600)
    let remainingScreen = NSRect(x: 0, y: 50, width: 800, height: 600)
    var screens = [originalScreen, remainingScreen]
    let stack = PinnedScreenshotStack(visibleFrames: { screens })
    defer { second.close(); first.close() }

    stack.add(first, alongside: [], visibleFrame: originalScreen)
    stack.add(second, alongside: [first], visibleFrame: originalScreen)
    second.setFrameOrigin(NSPoint(x: -500, y: -300))
    #expect(originalScreen.contains(second.frame))
    screens = [remainingScreen]

    stack.step(by: -1, from: second)

    #expect(first.isVisible && remainingScreen.contains(first.frame))
  }

  @Test("Empty stacks are released when a pin closes or expands", arguments: [false, true])
  func emptyThumbnailStackIsReleased(expand: Bool) throws {
    let controller = ScreenshotCapture()
    let (first, second) = try stackTwoPins(using: controller)
    defer { second.close(); first.close() }
    weak var stack = second.thumbnailStack
    try #require(stack != nil && first.thumbnailStack === stack)

    if expand { second.restoreFromThumbnail() } else { second.close() }

    #expect(first.isVisible && first.thumbnailStack == nil)
    #expect(stack == nil)
    withExtendedLifetime(controller) {}
  }

  @Test("A display change prunes disconnected stacks without closing their pins")
  func disconnectedThumbnailStackIsReleased() throws {
    let screen = try #require(NSScreen.main)
    let displayNumber = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
    var connectedDisplayIDs: Set<CGDirectDisplayID> = [displayNumber.uint32Value]
    let controller = ScreenshotCapture(connectedDisplayIDs: { connectedDisplayIDs })
    let (first, second) = try stackTwoPins(using: controller)
    defer { second.close(); first.close() }
    weak var stack = second.thumbnailStack
    try #require(stack != nil && first.thumbnailStack === stack)
    let expandedFrames = [first.editingFrame, second.editingFrame]

    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    #expect(stack != nil && !first.isVisible && second.isVisible)

    connectedDisplayIDs = [displayNumber.uint32Value ^ 1]
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

    #expect(stack == nil)
    #expect(first.isVisible && second.isVisible)
    #expect(first.thumbnailStack == nil && second.thumbnailStack == nil)
    #expect([first.frame, second.frame] == expandedFrames)
  }

  private func stackTwoPins(using controller: ScreenshotCapture) throws
    -> (PinnedScreenshotWindow, PinnedScreenshotWindow) {
    let screen = try #require(NSScreen.main?.visibleFrame)
    let key = Defaults.Keys.automaticPinStackingEnabled
    let previous = Defaults[key]
    Defaults[key] = true
    defer { Defaults[key] = previous }
    let png = try generatedPNG()
    func pin(offset: CGFloat) throws -> PinnedScreenshotWindow {
      let image = try #require(NSImage(data: png))
      let frame = NSRect(x: (screen.midX + offset).rounded(), y: screen.midY.rounded(), width: 120, height: 120)
      controller.pinImage(image, imageFrame: frame)
      return try #require(NSApp.windows.compactMap { $0 as? PinnedScreenshotWindow }.first { $0.image === image })
    }
    return try (pin(offset: -180), pin(offset: 60))
  }

  @Test("Click-through restores a pin and keeps it out of subsequent thumbnail stacks")
  func clickThroughRemovesThumbnail() {
    let first = pinnedZoomWindow()
    let second = pinnedZoomWindow()
    let third = pinnedZoomWindow()
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let stack = PinnedScreenshotStack()
    defer { third.close(); second.close(); first.close() }

    stack.add(first, alongside: [], visibleFrame: screen)
    stack.add(second, alongside: [first], visibleFrame: screen)
    second.isClickThrough = true
    #expect(stack.pins.isEmpty && second.ignoresMouseEvents && second.isVisible && first.isVisible)
    stack.add(third, alongside: [first, second], visibleFrame: screen)
    #expect(stack.pins.count == 2 && !stack.pins.contains { $0 === second })
    #expect(second.isVisible && second.thumbnailStack == nil)
  }

  @Test("Explicitly expanded pins stay separate when later pins are added")
  func expandedPinStaysSeparate() {
    let first = pinnedZoomWindow()
    let second = pinnedZoomWindow()
    let third = pinnedZoomWindow()
    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let stack = PinnedScreenshotStack()
    let original = second.frame
    defer { third.close(); second.close(); first.close() }

    stack.add(first, alongside: [], visibleFrame: screen)
    stack.add(second, alongside: [first], visibleFrame: screen)
    second.restoreFromThumbnail()
    #expect(second.keepsOpenSeparately && second.frame == original)
    #expect(first.isVisible && !first.keepsOpenSeparately)

    stack.add(third, alongside: [first, second], visibleFrame: screen)
    #expect(second.isVisible && second.thumbnailStack == nil && second.frame == original)
    #expect(stack.pins.count == 2 && stack.visiblePin === third && !first.isVisible)
  }

  @Test("Disabling automatic stacking restores existing pins and leaves new pins full size")
  func automaticPinStackingPreference() async throws {
    try #require(AppDelegate.isTesting)
    let key = Defaults.Keys.automaticPinStackingEnabled
    #expect(key.defaultValue)
    let previousValue = Defaults[key]
    let controller = ScreenshotCapture.shared
    var windows: [PinnedScreenshotWindow] = []
    defer {
      windows.reversed().forEach { $0.close() }
      Defaults[key] = previousValue
    }
    let screen = try #require(NSScreen.main?.visibleFrame)
    let data = try generatedPNG()
    func pin(at offset: CGFloat) throws -> (PinnedScreenshotWindow, NSRect) {
      let image = try #require(NSImage(data: data))
      let frame = NSRect(x: (screen.midX + offset).rounded(), y: screen.midY.rounded(), width: 160, height: 160)
      controller.pinImage(image, imageFrame: frame)
      let window = try #require(NSApp.windows.compactMap { $0 as? PinnedScreenshotWindow }.first { $0.image === image })
      windows.append(window)
      return (window, frame)
    }

    Defaults[key] = true
    let (first, firstFrame) = try pin(at: -240)
    let (second, secondFrame) = try pin(at: -60)
    #expect(!first.isVisible && second.isVisible && second.thumbnailStack != nil)

    Defaults[key] = false
    let deadline = ContinuousClock.now + .seconds(2)
    while second.thumbnailStack != nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let (third, thirdFrame) = try pin(at: 120)
    for (window, frame) in [(first, firstFrame), (second, secondFrame), (third, thirdFrame)] {
      #expect(window.isVisible && window.thumbnailStack == nil)
      #expect(window.frame == frame)
    }

    Defaults[key] = true
    let (fourth, _) = try pin(at: 240)
    #expect(fourth.thumbnailStack?.pins.count == 4 && fourth.isVisible)
    #expect(!first.isVisible && !second.isVisible && !third.isVisible)
  }

  @Test("Double-click closes only the current pin, while the context menu opens annotation", arguments: [false, true])
  func doubleClickClosesPin(stacked: Bool) throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    let other = stacked ? pinnedZoomWindow() : nil
    let stack = PinnedScreenshotStack()
    defer { window.close(); other?.close() }
    if let other {
      let screen = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
      stack.add(other, alongside: [], visibleFrame: screen)
      stack.add(window, alongside: [other], visibleFrame: screen)
    } else {
      window.present()
    }
    let view = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let click = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 4, y: 4), modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1
    ))
    let annotate = #selector(PinnedScreenshotWindow.annotateImage)
    let item = try #require(view.menu?.items.first { $0.action == annotate })
    var annotatedImages: [NSImage] = []
    var closed = false
    window.onAnnotate = { annotatedImages.append($0) }
    window.onClose = { closed = true }
    #expect(NSApp.sendAction(annotate, to: item.target, from: item))
    #expect(annotatedImages.count == 1 && annotatedImages.first === image)
    #expect(window.isVisible && !closed)
    view.mouseDown(with: click)
    #expect(!window.isVisible && closed && annotatedImages.count == 1)
    if let other { #expect(other.isVisible && other.thumbnailStack == nil) }
  }

  @Test("Only Option at mouse-down selects pin export, and export requires at least four points of movement")
  func pinnedExportGesture() throws {
    let origin = NSPoint(x: 10, y: 20)
    func event(
      _ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1
    ) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: flags, timestamp: 0,
        windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1
      ))
    }
    let plain = try event(.leftMouseDown, at: origin)
    let doubleClick = try event(.leftMouseDown, at: origin, clicks: 2)
    let option = try event(.leftMouseDown, at: origin, flags: [.option])
    #expect(PinnedScreenshotDragGesture.action(for: plain) == .move)
    #expect(PinnedScreenshotDragGesture.action(for: doubleClick) == .close)
    #expect(PinnedScreenshotDragGesture.action(for: option) == .export)
    let gesture = PinnedScreenshotDragGesture(origin: option.locationInWindow)
    let tiny = try event(.leftMouseDragged, at: NSPoint(x: 13, y: 22), flags: [.option])
    let released = try event(.leftMouseDragged, at: NSPoint(x: 14, y: 20))
    #expect(!gesture.crossedThreshold(with: tiny))
    #expect(gesture.crossedThreshold(with: released))
  }

  @Test("Pin drag stages a real PNG file at the source pixel size and cleans up on cancellation")
  func pinnedFileExport() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let file = try PinnedScreenshotDragExport.stage(source, in: root)
    let secondFile = try PinnedScreenshotDragExport.stage(source, in: root)
    let data = try Data(contentsOf: file)
    let result = try #require(NSBitmapImageRep(data: data))
    #expect(file != secondFile && file.pathExtension == "png")
    #expect(result.pixelsWide == source.width && result.pixelsHigh == source.height)
    #expect((file as NSURL).writableTypes(for: .general).contains(.fileURL))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    try #require(pasteboard.writeObjects([file as NSURL]))
    #expect(pasteboard.string(forType: .fileURL).flatMap(URL.init(string:)) == file)
    let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    #expect(urls == [file])
    let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    #expect(pasteboard.propertyList(forType: filenames) as? [String] == [file.path])

    PinnedScreenshotDragExport.finish(file, copied: false)
    PinnedScreenshotDragExport.finish(secondFile, copied: true)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(FileManager.default.fileExists(atPath: secondFile.path))
    #expect(try Data(contentsOf: secondFile) == data)
  }

  @Test("Pruning removes stale export directories without deleting recent exports or unrelated folders")
  func pinnedFileExportPruning() throws {
    let root = try temporaryDirectory()
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    let source = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let expired = try PinnedScreenshotDragExport.stage(source, in: root)
    let recent = try PinnedScreenshotDragExport.stage(source, in: root)
    let unrelated = root.appendingPathComponent("unrelated", isDirectory: true)
    try files.createDirectory(at: unrelated, withIntermediateDirectories: false)
    let old = Date(timeIntervalSinceNow: -172_800)
    for directory in [expired.deletingLastPathComponent(), unrelated] {
      try files.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
    }

    PinnedScreenshotDragExport.removeExpired(in: root)

    #expect(!files.fileExists(atPath: expired.deletingLastPathComponent().path))
    #expect(files.fileExists(atPath: recent.path))
    #expect(files.fileExists(atPath: unrelated.path))
  }

  @Test("Pin export fails without leaving a staged file when the export root is not writable as a directory")
  func pinnedFileExportFailure() throws {
    let root = try temporaryDirectory()
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    let obstruction = root.appendingPathComponent("obstruction")
    let data = try generatedPNG()
    try data.write(to: obstruction)
    let source = try #require(NSBitmapImageRep(data: data)?.cgImage)

    #expect(throws: (any Error).self) { try PinnedScreenshotDragExport.stage(source, in: obstruction) }
    #expect(try files.contentsOfDirectory(atPath: root.path) == ["obstruction"])
    #expect(try Data(contentsOf: obstruction) == data)
  }

  @Test("Releasing the mouse or closing the pin cancels in-flight PNG staging", arguments: [false, true])
  func cancelInFlightPinExport(closePin: Bool) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (window, view) = try pinForStagingTest()
    defer { window.close() }
    let gate = PinExportStagingGate(root: root, pauseBeforeWrite: true)
    defer { gate.resume.signal() }
    var paused = gate.paused.makeAsyncIterator()
    var observations = gate.observations.makeAsyncIterator()
    let pending = try startPinExport(in: window, view: view, gate: gate)
    await paused.next()

    if closePin {
      window.cancelOperation(nil)
      #expect(!window.isVisible)
    } else {
      view.mouseUp(with: try pinMouseEvent(.leftMouseUp, in: window))
    }
    #expect(pending.isCancelled)
    gate.resume.signal()
    await pending.value

    let observation = try #require(await observations.next())
    #expect(observation.cancelled)
    #expect(observation.stagedDirectories == 0)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("A superseded pin export removes its already written PNG without resetting the new drag")
  func rapidPinExports() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (window, view) = try pinForStagingTest()
    defer { window.close() }
    let first = PinExportStagingGate(root: root, pauseBeforeWrite: false)
    let second = PinExportStagingGate(root: root, pauseBeforeWrite: true)
    defer { first.resume.signal(); second.resume.signal() }
    var firstPaused = first.paused.makeAsyncIterator()
    var secondPaused = second.paused.makeAsyncIterator()
    let superseded = try startPinExport(in: window, view: view, gate: first)
    await firstPaused.next()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)

    let latest = try startPinExport(in: window, view: view, gate: second)
    await secondPaused.next()
    first.resume.signal()
    await superseded.value

    #expect(superseded.isCancelled)
    #expect(!latest.isCancelled && view.exportTask != nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    view.mouseUp(with: try pinMouseEvent(.leftMouseUp, in: window))
    second.resume.signal()
    await latest.value
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("A remapped pinned-window shortcut works without keeping its old binding")
  func remappedPinnedShortcut() throws {
    try #require(AppDelegate.isTesting)
    let action = ScopedShortcut.closePinnedImage
    let previous = Defaults[.scopedShortcuts][action.rawValue]
    defer { Defaults[.scopedShortcuts][action.rawValue] = previous }
    let newShortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
    action.set(newShortcut)
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    var closed = false
    window.onClose = { closed = true }
    defer { window.close() }
    let oldEvent = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil,
      characters: "w", charactersIgnoringModifiers: "w", isARepeat: false,
      keyCode: UInt16(action.initial.carbonKeyCode)
    ))
    #expect(!action.matches(oldEvent))
    let newEvent = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: newShortcut.modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil,
      characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
      keyCode: UInt16(newShortcut.carbonKeyCode)
    ))
    #expect(window.performKeyEquivalent(with: newEvent))
    #expect(closed)
  }

  @Test("Shortcut conflicts respect window scope and global assignments")
  func shortcutConflictScopes() {
    let chord = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
    let capture = ShortcutAssignment(id: "capture", title: "Capture", scope: .capture, shortcut: chord)
    let editor = ShortcutAssignment(id: "edit", title: "Edit", scope: .annotation, shortcut: chord)
    let selection = ShortcutAssignment(id: "selection", title: "Selection", scope: .selection, shortcut: chord)
    let pin = ShortcutAssignment(id: "pin", title: "Pin", scope: .pinnedImage, shortcut: chord)
    let global = ShortcutAssignment(id: "global", title: "Global", scope: .global, shortcut: chord)
    let assignments = [capture, editor, selection, pin, global]
    #expect(Set(capture.conflicts(in: assignments).map(\.id)) == ["edit", "selection", "global"])
    #expect(Set(editor.conflicts(in: assignments).map(\.id)) == ["capture", "global"])
    #expect(pin.conflicts(in: assignments).map(\.id) == ["global"])
    #expect(global.conflicts(in: assignments).count == 4)
  }

  @Test("Shortcut storage distinguishes a cleared binding from its default")
  func scopedShortcutStorage() throws {
    let action = ScopedShortcut.copyCapture
    let cleared = try JSONEncoder().encode(nil as KeyboardShortcuts.Shortcut?)
    let custom = KeyboardShortcuts.Shortcut(.k, modifiers: .command)
    let customData = try JSONEncoder().encode(custom)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: nil) == action.initial)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: cleared) == nil)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: customData) == custom)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: Data()) == action.initial)
  }

  @Test("Pinned zoom stays on negative-coordinate displays for wide, tall, and tiny images",
        arguments: [
          NSSize(width: 800, height: 400), NSSize(width: 400, height: 800),
          NSSize(width: 100000, height: 1000), NSSize(width: 1000, height: 100000),
          NSSize(width: 8, height: 8)
        ])
  func pinnedZoomBounds(imageSize: NSSize) {
    let visibleFrame = NSRect(x: -1920, y: -1080, width: 1920, height: 1040)
    let anchor = NSPoint(x: -5, y: -45)
    var frame = PinnedScreenshotWindow.initialFrame(
      imageSize: imageSize, visibleFrame: visibleFrame, anchor: anchor
    )
    for factor: CGFloat in [1000000, 0.000001, 2, 0.5] {
      frame = PinnedScreenshotWindow.zoomedFrame(
        imageSize: imageSize, frame: frame, factor: factor, visibleFrame: visibleFrame, anchor: anchor
      )
      #expect(visibleFrame.insetBy(dx: -0.001, dy: -0.001).contains(frame))
      #expect(frame.width > 0 && frame.height > 0)
      #expect(abs(frame.width / frame.height - imageSize.width / imageSize.height) < 0.001)
      #expect(frame.width <= imageSize.width * 5 + 0.001)
    }
  }

  @Test("Pinned zoom has minimum and maximum sizes")
  func pinnedZoomLimits() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    let frame = NSRect(x: 600, y: 400, width: 400, height: 200)
    let anchor = NSPoint(x: frame.midX, y: frame.midY)
    let smallest = PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 800, height: 400), frame: frame, factor: 0.000001,
      visibleFrame: visibleFrame, anchor: anchor
    )
    #expect(smallest.size == NSSize(width: 80, height: 40))
    let largest = PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 80, height: 40), frame: frame, factor: 1000000,
      visibleFrame: visibleFrame, anchor: anchor
    )
    #expect(largest.size == NSSize(width: 400, height: 200))
  }

  @Test("Invalid zoom factors leave pinned windows unchanged", arguments: [
    CGFloat.zero, -1, .nan, .infinity
  ])
  func invalidPinnedZoom(factor: CGFloat) {
    let frame = NSRect(x: 100, y: 100, width: 400, height: 200)
    #expect(PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 800, height: 400), frame: frame, factor: factor,
      visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
      anchor: NSPoint(x: 300, y: 200)
    ) == frame)
  }

  @Test("Option-wheel zoom reaches the panel through its image view without extra buttons",
        arguments: [false, true], [false, true])
  func pinnedWheelZoom(precise: Bool, inverted: Bool) throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let image = try #require(imageView.image)
    let originalSize = image.size
    let event = PinnedZoomEvent()
    event.flags = .option
    event.precise = precise
    event.inverted = inverted
    event.scrollDelta = (precise ? 10 : 1) * (inverted ? -1 : 1)
    imageView.scrollWheel(with: event)
    #expect(window.frame.width > originalFrame.width)
    #expect(abs(window.frame.width - window.frame.height * 2) <= 2)
    event.scrollDelta *= -1
    imageView.scrollWheel(with: event)
    #expect(abs(window.frame.width - originalFrame.width) <= 1)
    #expect(imageView.image === image)
    #expect(image.size == originalSize)
    let controls = try #require(window.contentView?.subviews.compactMap { $0 as? GlassControlStrip }.first)
    #expect(controls.controlsView.subviews.compactMap { $0 as? NSButton }.count == 1)
    #expect(window.contentView?.subviews.contains { $0 is NSButton } == false)
    #expect(window.alphaValue == 1)
  }

  @Test("Plain wheel scrolling changes pinned opacity without resizing", arguments: [false, true], [false, true])
  func pinnedWheelOpacity(precise: Bool, inverted: Bool) throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let event = PinnedZoomEvent()
    event.precise = precise
    event.inverted = inverted
    event.scrollDelta = -(precise ? 50 : 4) * (inverted ? -1 : 1)
    imageView.scrollWheel(with: event)
    #expect(abs(window.alphaValue - 0.8) < 0.01)
    #expect(window.frame == originalFrame)
    event.scrollDelta *= -1
    imageView.scrollWheel(with: event)
    #expect(abs(window.alphaValue - 1) < 0.01)
    event.scrollDelta *= -1
    for _ in 0..<20 { window.scrollWheel(with: event) }
    #expect(abs(window.alphaValue - PinnedScreenshotWindow.minimumOpacity) < 0.01)
    #expect(window.frame == originalFrame)
  }

  @Test("Pinned opacity steps are bounded and ignore invalid input")
  func pinnedOpacitySteps() {
    #expect(PinnedScreenshotWindow.adjustedOpacity(1, delta: 1, precise: false) == 1)
    #expect(abs(PinnedScreenshotWindow.adjustedOpacity(1, delta: -1, precise: false) - 0.95) < 0.0001)
    #expect(abs(PinnedScreenshotWindow.adjustedOpacity(1, delta: -100, precise: false) - 0.75) < 0.0001)
    #expect(PinnedScreenshotWindow.adjustedOpacity(0.15, delta: -10, precise: false) == 0.1)
    #expect(PinnedScreenshotWindow.adjustedOpacity(0.5, delta: .nan, precise: true) == 0.5)
  }

  @Test("Click-through lets mouse events pass, swaps the close button for a sign, and toggles from the menu and Command-T")
  func pinnedClickThrough() throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    var changes = 0
    window.onClickThroughChange = { changes += 1 }
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let item = try #require(imageView.menu?.items.first { $0.action == #selector(PinnedScreenshotWindow.toggleClickThrough) })
    let controls = try #require(window.contentView?.subviews.compactMap { $0 as? GlassControlStrip }.first)
    let sign = try #require(window.contentView?.subviews.compactMap { $0 as? PinnedClickThroughSignView }.first)
    #expect(!window.ignoresMouseEvents && item.state == .off && !controls.isHidden && sign.isHidden)
    window.perform(item.action)
    #expect(window.isClickThrough && window.ignoresMouseEvents && item.state == .on && controls.isHidden)
    #expect(!sign.isHidden && sign.frame == window.contentView?.bounds && sign.hitTest(NSPoint(x: 10, y: 10)) == nil)
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "t", charactersIgnoringModifiers: "t",
      isARepeat: false, keyCode: 17
    ))
    #expect(window.performKeyEquivalent(with: event))
    #expect(!window.isClickThrough && !window.ignoresMouseEvents && item.state == .off && !controls.isHidden)
    #expect(sign.isHidden && changes == 2)
    #expect(imageView.acceptsFirstMouse(for: nil))
  }

  @Test("Only the click-through border and close badge receive mouse input", arguments: [false, true])
  func pinnedClickThroughTargets(tiny: Bool) throws {
    let window = tiny ? pinnedZoomWindow(size: NSSize(width: 8, height: 8)) : pinnedZoomWindow()
    window.present()
    defer { window.close() }
    window.isClickThrough = true

    let children = try #require(window.childWindows)
    #expect(children.count == 5)
    #expect(window.ignoresMouseEvents)
    #expect(children.allSatisfy { !$0.ignoresMouseEvents && !$0.canBecomeKey })
    let bounds = try #require(window.contentView?.bounds)
    let rect = window.convertToScreen(bounds)
    let interior = NSPoint(x: rect.midX, y: rect.midY)
    let edges = [
      NSPoint(x: rect.minX + 1, y: rect.midY), NSPoint(x: rect.maxX - 1, y: rect.midY),
      NSPoint(x: rect.midX, y: rect.minY + 1), NSPoint(x: rect.midX, y: rect.maxY - 1)
    ]
    #expect(children.allSatisfy { !$0.frame.contains(interior) })
    for (edge, panel) in zip(edges, children) {
      #expect(panel.frame.contains(edge))
    }
    let badge = try #require(children.last)
    let badgeButton = try #require(badge.contentView as? NSButton)
    #expect(badgeButton.image != nil && !badgeButton.isTransparent)
    if tiny {
      #expect(!badge.frame.intersects(rect))
    } else {
      #expect(badge.frame == NSRect(x: rect.maxX - 28, y: rect.maxY - 28, width: 22, height: 22))
    }
    let borderButton = try #require(children.first?.contentView as? NSButton)
    #expect(borderButton.hitTest(NSPoint(x: 1, y: 1)) === borderButton)
    borderButton.performClick(nil)
    #expect(!window.isClickThrough)
    #expect(window.isVisible)
    #expect(window.childWindows?.isEmpty != false)
    #expect(children.allSatisfy { !$0.isVisible })
  }

  enum PinnedClosePath: CaseIterable {
    case button, badge, commandW, escape, programmatic
  }

  @Test("Every pin dismissal releases the tracked window", arguments: PinnedClosePath.allCases)
  func pinnedWindowIsReleased(path: PinnedClosePath) async throws {
    let controller = ScreenshotCapture()
    let image = try #require(NSImage(data: generatedPNG()))
    weak var releasedWindow: PinnedScreenshotWindow?
    try autoreleasepool {
      let knownWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
      controller.pinImage(image)
      let window = try #require(NSApp.windows.compactMap { $0 as? PinnedScreenshotWindow }.first {
        !knownWindows.contains(ObjectIdentifier($0)) && $0.isVisible
      })
      releasedWindow = window
      switch path {
      case .button:
        let controls = try #require(window.contentView?.subviews.compactMap { $0 as? GlassControlStrip }.first)
        let button = try #require(controls.controlsView.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
      case .badge:
        window.isClickThrough = true
        #expect(controller.pinnedImages.clickThroughCount == 1)
        let badge = try #require(window.childWindows?.last?.contentView as? NSButton)
        badge.performClick(nil)
      case .commandW, .escape:
        let command = path == .commandW
        let event = try #require(NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
          timestamp: 0, windowNumber: window.windowNumber, context: nil,
          characters: command ? "w" : "\u{1B}", charactersIgnoringModifiers: command ? "w" : "\u{1B}",
          isARepeat: false, keyCode: command ? 13 : 53
        ))
        window.keyDown(with: event)
      case .programmatic:
        window.close()
      }
      #expect(!window.isVisible)
      #expect(window.childWindows?.isEmpty != false)
    }
    for _ in 0..<100 where releasedWindow != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(releasedWindow == nil)
    #expect(controller.pinnedImages.clickThroughCount == 0)
  }

  @Test("Trackpad pinch reaches the pinned panel through its image view")
  func pinnedPinchZoom() throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalWidth = window.frame.width
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let event = PinnedZoomEvent()
    event.pinchDelta = 0.25
    imageView.magnify(with: event)
    #expect(abs(window.frame.width - originalWidth * 1.25) <= 1)
    event.pinchDelta = -0.2
    imageView.magnify(with: event)
    #expect(abs(window.frame.width - originalWidth) <= 1)
  }

  @Test("Subpixel trackpad scrolling accumulates without window-rounding drift")
  func precisePinnedZoomAccumulates() {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalWidth = window.frame.width
    let event = PinnedZoomEvent()
    event.precise = true
    event.flags = .option
    event.scrollDelta = 0.02
    for _ in 0..<100 {
      window.scrollWheel(with: event)
    }
    #expect(abs(window.frame.width - originalWidth * exp(0.02)) <= 1)
    event.scrollDelta *= -1
    for _ in 0..<100 {
      window.scrollWheel(with: event)
    }
    #expect(abs(window.frame.width - originalWidth) <= 1)
  }

  @Test("Momentum, cancelled gestures, zero deltas, and invalid input cannot zoom a pin")
  func ignoredPinnedZoomEvents() {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let event = PinnedZoomEvent()
    event.scrollDelta = 2
    event.simulatedMomentum = .changed
    window.scrollWheel(with: event)
    #expect(window.frame == originalFrame && window.alphaValue == 1)
    event.simulatedMomentum = []
    event.simulatedPhase = .cancelled
    event.pinchDelta = 0.25
    window.scrollWheel(with: event)
    window.magnify(with: event)
    #expect(window.frame == originalFrame)
    event.simulatedPhase = []
    for delta: CGFloat in [0, .nan, .infinity] {
      event.scrollDelta = delta
      event.pinchDelta = delta
      window.scrollWheel(with: event)
      window.magnify(with: event)
      #expect(window.frame == originalFrame && window.alphaValue == 1)
    }
  }

  @Test("Screenshot previews stay in the bottom-left corner of the target display",
        arguments: [
          NSRect(x: -1920, y: -1080, width: 1920, height: 1040),
          NSRect(x: 0, y: 0, width: 200, height: 160)
        ])
  func previewPlacement(visibleFrame: NSRect) {
    let frame = ScreenshotPreviewWindow.initialFrame(
      imageSize: NSSize(width: 3840, height: 2160), visibleFrame: visibleFrame
    )
    #expect(visibleFrame.contains(frame))
    #expect(frame.width <= 220)
    #expect(frame.height <= 150)
    #expect(frame.minX == visibleFrame.minX + 16)
    #expect(frame.minY == visibleFrame.minY + 16)
  }

  @Test("Screenshot previews never take keyboard focus and clean up once on timeout")
  func previewAutoDismisses() async throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      dismissalDelay: .milliseconds(30), onPin: {}
    )
    var closes = 0
    window.onClose = { closes += 1 }
    #expect(!window.canBecomeKey)
    #expect(!window.canBecomeMain)
    #expect(window.level == .floating)
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(window.imageView.image === image)
    #expect(window.imageView.imageScaling == .scaleProportionallyUpOrDown)
    window.scheduleDismissal()
    try await waitForPreviewClose { closes > 0 }
    window.close()
    #expect(closes == 1)
  }

  @Test("The default thumbnail lifetime is two seconds")
  func previewTwoSeconds() async throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      onPin: {}
    )
    var closed = false
    window.onClose = { closed = true }
    let started = ContinuousClock.now
    window.scheduleDismissal()
    try await Task.sleep(for: .milliseconds(1700))
    #expect(!closed)
    try await waitForPreviewClose { closed }
    #expect(closed)
    #expect(started.duration(to: .now) >= .seconds(2))
  }

  @Test("Pinning a thumbnail dismisses only that thumbnail and invokes its action once")
  func pinThumbnail() throws {
    let image = try #require(NSImage(data: generatedPNG()))
    var pins = 0
    var closes = 0
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      onPin: { pins += 1 }
    )
    window.onClose = { closes += 1 }
    window.pinImage()
    window.pinImage()
    #expect(pins == 1)
    #expect(closes == 1)
  }

  @Test("The thumbnail glass strip leaves its pin button clickable")
  func thumbnailGlassButton() throws {
    let image = try #require(NSImage(data: generatedPNG()))
    var pins = 0
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      onPin: { pins += 1 }
    )
    defer { window.close() }
    let surface = try #require(window.contentView as? GlassSurfaceView)
    surface.layoutSubtreeIfNeeded()
    let controls = try #require(surface.controlsView.subviews.compactMap { $0 as? GlassControlStrip }.first)
    let button = try #require(controls.controlsView.subviews.compactMap { $0 as? NSButton }.first)
    let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
    let hit = controls.hitTest(surface.controlsView.convert(center, from: button))
    #expect(hit === button)
    let gutter = surface.controlsView.convert(NSPoint(x: 1, y: controls.bounds.midY), from: controls)
    #expect(controls.hitTest(gutter) == nil)
    button.performClick(nil)
    #expect(pins == 1)
  }

  private func waitForPreviewClose(_ isClosed: () -> Bool) async throws {
    for _ in 0..<100 {
      if isClosed() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Preview did not dismiss")
  }

  private func pinnedZoomWindow(size: NSSize = NSSize(width: 200, height: 100)) -> PinnedScreenshotWindow {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    return PinnedScreenshotWindow(
      image: NSImage(size: size), visibleFrame: visibleFrame,
      anchor: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    )
  }

  private func pinForStagingTest() throws -> (PinnedScreenshotWindow, PinnedScreenshotImageView) {
    let image = try #require(NSImage(data: generatedPNG()))
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = PinnedScreenshotWindow(
      image: image, visibleFrame: visibleFrame, anchor: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    )
    let view = try #require(window.contentView?.subviews.compactMap { $0 as? PinnedScreenshotImageView }.first)
    window.present()
    return (window, view)
  }

  private func startPinExport(
    in window: PinnedScreenshotWindow, view: PinnedScreenshotImageView, gate: PinExportStagingGate
  ) throws -> Task<Void, Never> {
    view.stageExport = gate.stage
    view.mouseDown(with: try pinMouseEvent(.leftMouseDown, in: window))
    view.mouseDragged(with: try pinMouseEvent(.leftMouseDragged, in: window))
    return try #require(view.exportTask)
  }

  private func pinMouseEvent(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: NSPoint(x: type == .leftMouseDown ? 4 : 12, y: 4), modifierFlags: [.option],
      timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
  }

  private func process(_ executable: String, arguments: [String] = []) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    return process
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Maccy-Test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func generatedPNG() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    ))
    for column in 0..<8 {
      for row in 0..<8 {
        bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), atX: column, y: row)
      }
    }
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func waitForStart(_ session: ScreenshotCaptureSession) async throws {
    for _ in 0..<100 {
      if session.isCapturing { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Capture did not start")
    throw CancellationError()
  }
}

nonisolated private final class PinExportStagingGate: Sendable {
  struct Observation: Sendable {
    let cancelled: Bool
    let stagedDirectories: Int?
  }

  let resume = DispatchSemaphore(value: 0)
  private let pause = AsyncStream<Void>.makeStream()
  private let result = AsyncStream<Observation>.makeStream()
  private let root: URL
  private let pauseBeforeWrite: Bool

  var paused: AsyncStream<Void> { pause.stream }
  var observations: AsyncStream<Observation> { result.stream }

  init(root: URL, pauseBeforeWrite: Bool) {
    self.root = root
    self.pauseBeforeWrite = pauseBeforeWrite
  }

  func stage(_ image: CGImage) throws -> URL {
    defer {
      result.continuation.yield(.init(
        cancelled: Task.isCancelled,
        stagedDirectories: try? FileManager.default.contentsOfDirectory(atPath: root.path).count
      ))
      result.continuation.finish()
      pause.continuation.finish()
    }
    if pauseBeforeWrite { wait() }
    let file = try PinnedScreenshotDragExport.stage(image, in: root)
    if !pauseBeforeWrite { wait() }
    return file
  }

  private func wait() {
    pause.continuation.yield(())
    _ = resume.wait(timeout: .now() + 10)
  }
}

private final class PinnedZoomEvent: NSEvent {
  var scrollDelta: CGFloat = 0
  var pinchDelta: CGFloat = 0
  var precise = false
  var inverted = false
  var simulatedMomentum: NSEvent.Phase = []
  var simulatedPhase: NSEvent.Phase = []
  var flags: NSEvent.ModifierFlags = []

  override var scrollingDeltaY: CGFloat { scrollDelta }
  override var magnification: CGFloat { pinchDelta }
  override var hasPreciseScrollingDeltas: Bool { precise }
  override var isDirectionInvertedFromDevice: Bool { inverted }
  override var momentumPhase: NSEvent.Phase { simulatedMomentum }
  override var phase: NSEvent.Phase { simulatedPhase }
  override var modifierFlags: NSEvent.ModifierFlags { flags }
  override var locationInWindow: NSPoint { NSPoint(x: 100, y: 50) }
}
