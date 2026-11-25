import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ScreenshotAnnotationDocument {
  nonisolated enum Tool: Int, CaseIterable, Sendable {
    case arrow, rectangle, ellipse, pen, text, number, magnifier, redact, mosaic, eraser

    var titleKey: String {
      switch self {
      case .arrow: "AnnotationArrow"
      case .rectangle: "AnnotationRectangle"
      case .ellipse: "AnnotationEllipse"
      case .pen: "AnnotationPen"
      case .text: "AnnotationText"
      case .number: "AnnotationNumber"
      case .magnifier: "AnnotationMagnifier"
      case .redact: "AnnotationRedact"
      case .mosaic: "AnnotationMosaic"
      case .eraser: "AnnotationEraser"
      }
    }

    var drawsMark: Bool { self != .eraser }

    // The toolbar follows the order chosen in Settings; new tools are appended and at least one stays visible.
    static func toolbarTools(order: [Int], disabled: [Int]) -> [Tool] {
      var tools: [Tool] = []
      for tool in order.compactMap(Tool.init(rawValue:)) + allCases where !tools.contains(tool) { tools.append(tool) }
      let enabled = tools.filter { !disabled.contains($0.rawValue) }
      return enabled.isEmpty ? [tools[0]] : enabled
    }
    var hasBoxHandles: Bool { [.rectangle, .ellipse, .redact, .mosaic, .magnifier].contains(self) }

    nonisolated enum StyleKind: Sendable { case line, font, mosaic, zoom }
    var styleKind: StyleKind? {
      switch self {
      case .text, .number: .font
      case .mosaic: .mosaic
      case .magnifier: .zoom
      case .redact, .eraser: nil
      default: .line
      }
    }
  }

  struct Mark {
    let tool: Tool
    var points: [NSPoint]
    var color: NSColor = .red
    var lineWidth: CGFloat = 4
    var text = ""
    var fontSize: CGFloat = 24
    var mosaic: CGImage?
    var zoom: CGFloat = 2

    static let minimumFontSize: CGFloat = 4
    static let maximumFontSize: CGFloat = 1000

    var numberDiameter: CGFloat { fontSize * 1.5 }
    var textFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
    var textSize: NSSize { (text as NSString).size(withAttributes: [.font: textFont]) }

    var shapeBounds: NSRect {
      guard let first = points.first, let last = points.last else { return .zero }
      return NSRect(
        x: min(first.x, last.x), y: min(first.y, last.y),
        width: abs(last.x - first.x), height: abs(last.y - first.y)
      )
    }

    var bounds: NSRect {
      guard let first = points.first else { return .zero }
      switch tool {
      case .text:
        return NSRect(origin: first, size: textSize)
      case .number:
        let diameter = numberDiameter
        return NSRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter)
      case .pen:
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? first.x, minY = ys.min() ?? first.y
        return NSRect(x: minX, y: minY, width: (xs.max() ?? minX) - minX, height: (ys.max() ?? minY) - minY)
      default:
        return shapeBounds
      }
    }

    var styleSize: CGFloat {
      get {
        switch tool.styleKind {
        case .font: fontSize
        case .zoom: zoom
        default: lineWidth
        }
      }
      set {
        switch tool.styleKind {
        case .font: fontSize = min(max(newValue, Self.minimumFontSize), Self.maximumFontSize)
        case .zoom: zoom = min(max(newValue, 1), 20)
        case .line, .mosaic: lineWidth = min(max(newValue, 0.5), 1000)
        case nil: break
        }
      }
    }

    var handlePoints: [NSPoint] {
      if tool == .arrow, let first = points.first, let last = points.last { return [first, last] }
      guard tool.hasBoxHandles || [.text, .number, .pen].contains(tool) else { return [] }
      let box = bounds
      return [
        NSPoint(x: box.minX, y: box.minY), NSPoint(x: box.maxX, y: box.minY),
        NSPoint(x: box.maxX, y: box.maxY), NSPoint(x: box.minX, y: box.maxY)
      ]
    }

    func moved(by dx: CGFloat, _ dy: CGFloat, within size: NSSize) -> Mark {
      let box = bounds
      let x = min(max(dx, -box.minX), max(-box.minX, size.width - box.maxX))
      let y = min(max(dy, -box.minY), max(-box.minY, size.height - box.maxY))
      var mark = self
      mark.points = points.map { NSPoint(x: $0.x + x, y: $0.y + y) }
      return mark
    }

    func resized(handle: Int, to point: NSPoint) -> Mark {
      let handles = handlePoints
      guard handles.indices.contains(handle) else { return self }
      var mark = self
      let anchorIndex = (handle + 2) % handles.count, anchor = handles[anchorIndex]
      if tool == .arrow {
        mark.points[handle == 0 ? 0 : points.count - 1] = point
      } else if tool == .text || tool == .number {
        // Text and markers scale their font uniformly, keeping the opposite corner in place.
        let box = bounds
        guard box.width > 0, box.height > 0 else { return self }
        let scale = max(abs(point.x - anchor.x) / box.width, abs(point.y - anchor.y) / box.height)
        mark.fontSize = min(max(fontSize * scale, Self.minimumFontSize), Self.maximumFontSize)
        let resized = mark.bounds
        let left = anchorIndex == 0 || anchorIndex == 3, bottom = anchorIndex < 2
        let dx = (left ? anchor.x : anchor.x - resized.width) - resized.minX
        let dy = (bottom ? anchor.y : anchor.y - resized.height) - resized.minY
        mark.points = mark.points.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
      } else if tool == .pen {
        let start = handles[handle]
        let sx = start.x == anchor.x ? 1 : (point.x - anchor.x) / (start.x - anchor.x)
        let sy = start.y == anchor.y ? 1 : (point.y - anchor.y) / (start.y - anchor.y)
        mark.points = points.map { NSPoint(x: anchor.x + ($0.x - anchor.x) * sx, y: anchor.y + ($0.y - anchor.y) * sy) }
      } else {
        mark.points = [handles[(handle + 2) % handles.count], point]
      }
      return mark
    }
  }

  private enum Edit {
    case append(Mark)
    case replace(index: Int, from: Mark, to: Mark)
    case remove([(index: Int, mark: Mark)])
  }

  let sourceImage: CGImage
  var imageSize: NSSize { NSSize(width: sourceImage.width, height: sourceImage.height) }
  private(set) var marks: [Mark] = []
  private(set) var revision = 0
  var nextNumber: Int {
    (marks.filter { $0.tool == .number }.compactMap { Int($0.text) }.max() ?? 0) + 1
  }
  private var undoEdits: [Edit] = []
  private var redoEdits: [Edit] = []
  var canUndo: Bool { !undoEdits.isEmpty }
  var canRedo: Bool { !redoEdits.isEmpty }

  init?(image: NSImage) {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          source.width > 0, source.height > 0,
          source.width <= ScreenshotImageLimits.maximumPixels / source.height else { return nil }
    sourceImage = source
  }

  @discardableResult
  func append(_ mark: Mark) -> Bool {
    guard let mark = validated(mark) else { return false }
    record(.append(mark))
    return true
  }

  func validated(_ mark: Mark) -> Mark? {
    var mark = mark
    guard mark.tool.drawsMark, !mark.points.isEmpty,
          mark.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
          mark.lineWidth.isFinite, mark.lineWidth > 0,
          mark.fontSize.isFinite, mark.fontSize > 0, mark.zoom.isFinite, mark.zoom >= 1 else { return nil }
    switch mark.tool {
    case .text:
      guard !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            mark.text.count <= 4096 else { return nil }
    case .number:
      guard !mark.text.isEmpty, mark.text.count <= 6 else { return nil }
      mark.points = [mark.points[mark.points.count - 1]]
    default:
      guard mark.points.count >= 2, let first = mark.points.first, let last = mark.points.last else { return nil }
      if mark.tool == .pen {
        guard mark.points.contains(where: { hypot($0.x - first.x, $0.y - first.y) >= 1 }) else { return nil }
      } else if mark.tool == .arrow {
        guard hypot(last.x - first.x, last.y - first.y) >= 1 else { return nil }
      } else {
        guard abs(last.x - first.x) >= 1, abs(last.y - first.y) >= 1 else { return nil }
      }
    }
    if mark.tool == .mosaic {
      mark.mosaic = Self.pixelated(sourceImage, in: mark.shapeBounds, blockSize: mark.lineWidth)
    }
    return mark
  }

  @discardableResult
  func replaceMark(at index: Int, with mark: Mark) -> Bool {
    guard marks.indices.contains(index), marks[index].tool == mark.tool,
          marks[index].points != mark.points || marks[index].styleSize != mark.styleSize,
          let mark = validated(mark) else { return false }
    record(.replace(index: index, from: marks[index], to: mark))
    return true
  }

  @discardableResult
  func restyleMark(at index: Int, size: CGFloat, merging: Bool = false) -> Bool {
    guard marks.indices.contains(index), marks[index].tool.styleKind != nil, size.isFinite else { return false }
    var mark = marks[index]
    mark.styleSize = size
    guard mark.styleSize != marks[index].styleSize, let mark = validated(mark) else { return false }
    if merging, let last = undoEdits.last, case .replace(let previous, let original, _) = last, previous == index {
      undoEdits[undoEdits.count - 1] = .replace(index: index, from: original, to: mark)
      marks[index] = mark
      redoEdits.removeAll()
      revision += 1
      return true
    }
    record(.replace(index: index, from: marks[index], to: mark))
    return true
  }

  @discardableResult
  func removeMarks(at indices: Set<Int>) -> Bool {
    let removed = indices.filter { marks.indices.contains($0) }.sorted().map { (index: $0, mark: marks[$0]) }
    guard !removed.isEmpty else { return false }
    record(.remove(removed))
    return true
  }

  func markIndex(at point: NSPoint, tolerance: CGFloat, excluding excluded: Set<Int> = []) -> Int? {
    // Solid covers are drawn above every other mark, so they are hit first.
    let order = marks.indices.filter { marks[$0].tool != .redact } + marks.indices.filter { marks[$0].tool == .redact }
    return order.reversed().first {
      !excluded.contains($0) && Self.mark(marks[$0], contains: point, tolerance: tolerance)
    }
  }

  private static func mark(_ mark: Mark, contains point: NSPoint, tolerance: CGFloat) -> Bool {
    guard let first = mark.points.first else { return false }
    let last = mark.points.last ?? first
    let reach = tolerance + mark.lineWidth / 2
    switch mark.tool {
    case .text:
      return NSRect(origin: first, size: mark.textSize).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case .number:
      return hypot(point.x - first.x, point.y - first.y) <= mark.numberDiameter / 2 + tolerance
    case .magnifier:
      let bounds = mark.shapeBounds
      let radiusX = max(bounds.width / 2, 0.5), radiusY = max(bounds.height / 2, 0.5)
      let normalized = hypot((point.x - bounds.midX) / radiusX, (point.y - bounds.midY) / radiusY)
      return normalized <= 1 + (tolerance + mark.lineWidth / 2) / min(radiusX, radiusY)
    case .redact, .mosaic:
      return mark.shapeBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case .arrow:
      return distance(from: point, toSegment: first, last) <= reach
    case .pen:
      if mark.points.count == 1 { return hypot(point.x - first.x, point.y - first.y) <= reach }
      return zip(mark.points, mark.points.dropFirst()).contains { distance(from: point, toSegment: $0, $1) <= reach }
    case .rectangle:
      let bounds = mark.shapeBounds
      let outer = bounds.insetBy(dx: -reach, dy: -reach)
      let inner = bounds.insetBy(dx: reach, dy: reach)
      return outer.contains(point) && (inner.isEmpty || !inner.contains(point))
    case .ellipse:
      let bounds = mark.shapeBounds
      let radiusX = max(bounds.width / 2, 0.5), radiusY = max(bounds.height / 2, 0.5)
      let normalized = hypot((point.x - bounds.midX) / radiusX, (point.y - bounds.midY) / radiusY)
      return abs(normalized - 1) * min(radiusX, radiusY) <= reach
    case .eraser:
      return false
    }
  }

  private static func distance(from point: NSPoint, toSegment start: NSPoint, _ end: NSPoint) -> CGFloat {
    let dx = end.x - start.x, dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
  }

  nonisolated static func pixelated(_ source: CGImage, in bounds: NSRect, blockSize: CGFloat) -> CGImage? {
    let rect = bounds.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    guard !rect.isEmpty, blockSize.isFinite else { return nil }
    let block = max(2, blockSize.rounded())
    let flipped = CGRect(x: rect.minX, y: CGFloat(source.height) - rect.maxY, width: rect.width, height: rect.height)
    guard let region = source.cropping(to: flipped),
          let context = CGContext(
            data: nil, width: max(1, Int((rect.width / block).rounded(.up))),
            height: max(1, Int((rect.height / block).rounded(.up))), bitsPerComponent: 8, bytesPerRow: 0,
            space: ScreenshotColorSpace.rgb(source.colorSpace), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.interpolationQuality = .high
    context.draw(region, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
    return context.makeImage()
  }

  func textMarkIndex(at point: NSPoint, padding: CGFloat) -> Int? {
    guard !marks.contains(where: { $0.tool == .redact && $0.shapeBounds.integral.contains(point) }) else { return nil }
    return marks.indices.reversed().first { index in
      let mark = marks[index]
      guard mark.tool == .text, let origin = mark.points.first else { return false }
      let covered = marks[(index + 1)...].contains { $0.tool == .mosaic && $0.shapeBounds.integral.contains(point) }
      guard !covered else { return false }
      return NSRect(origin: origin, size: mark.textSize).insetBy(dx: -padding, dy: -padding).contains(point)
    }
  }

  @discardableResult
  func moveText(at index: Int, to position: NSPoint) -> Bool {
    guard marks.indices.contains(index), marks[index].tool == .text,
          position.x.isFinite, position.y.isFinite else { return false }
    var mark = marks[index]
    mark.points[0] = position
    return replaceMark(at: index, with: mark)
  }

  func undo() {
    guard let edit = undoEdits.popLast() else { return }
    switch edit {
    case .append: marks.removeLast()
    case .replace(let index, let original, _): marks[index] = original
    case .remove(let removed):
      for entry in removed { marks.insert(entry.mark, at: entry.index) }
    }
    redoEdits.append(edit)
    revision += 1
  }

  func redo() {
    guard let edit = redoEdits.popLast() else { return }
    apply(edit)
    undoEdits.append(edit)
    revision += 1
  }

  private func record(_ edit: Edit) {
    apply(edit)
    undoEdits.append(edit)
    redoEdits.removeAll()
    revision += 1
  }

  private func apply(_ edit: Edit) {
    switch edit {
    case .append(let mark): marks.append(mark)
    case .replace(let index, _, let mark): marks[index] = mark
    case .remove(let removed):
      for entry in removed.reversed() { marks.remove(at: entry.index) }
    }
  }

  func pngData() -> Data? {
    guard let image = renderedImage() else { return nil }
    return RenderSnapshot.pngData(image)
  }

  func renderedImage() -> CGImage? {
    renderSnapshot().render()
  }

  func renderSnapshot() -> RenderSnapshot {
    RenderSnapshot(source: sourceImage, marks: marks.map { RenderMark($0) })
  }

  nonisolated struct RenderMark: Sendable {
    let tool: Tool
    let points: [CGPoint]
    let color: CGColor
    let lineWidth: CGFloat
    let text: String
    let fontName: String
    let fontSize: CGFloat
    let shapeBounds: CGRect
    let mosaic: CGImage?
    let zoom: CGFloat

    @MainActor init(_ mark: Mark) {
      tool = mark.tool
      points = mark.points
      color = (mark.color.usingType(.componentBased) ?? .red).withAlphaComponent(1).cgColor
      lineWidth = mark.lineWidth
      text = mark.text
      fontName = mark.textFont.fontName
      fontSize = mark.fontSize
      shapeBounds = mark.shapeBounds
      mosaic = mark.mosaic
      zoom = mark.zoom
    }
  }

  nonisolated struct RenderSnapshot: Sendable {
    let source: CGImage
    let marks: [RenderMark]

    nonisolated static func pngData(_ image: CGImage) -> Data? {
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
      else { return nil }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else { return nil }
      return data as Data
    }

    nonisolated func render(croppingTo crop: CGRect? = nil) -> CGImage? {
      let sourceBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
      let pixels = crop?.integral.intersection(sourceBounds) ?? sourceBounds
      guard !pixels.isEmpty else { return nil }
      if pixels == sourceBounds, marks.isEmpty { return source }
      guard let context = CGContext(
              data: nil, width: Int(pixels.width), height: Int(pixels.height), bitsPerComponent: 8,
              bytesPerRow: 0, space: ScreenshotColorSpace.rgb(source.colorSpace),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
      context.interpolationQuality = .high
      context.translateBy(x: -pixels.minX, y: pixels.maxY - CGFloat(source.height))
      context.draw(source, in: sourceBounds)
      let lens = ScreenshotAnnotationDocument.lensSource(source, marks: marks)
      for mark in marks where mark.tool != .redact { ScreenshotAnnotationDocument.drawRenderedMark(mark, source: lens, in: context) }
      for mark in marks where mark.tool == .redact { ScreenshotAnnotationDocument.drawRenderedMark(mark, source: lens, in: context) }
      return context.makeImage()
    }
  }

  func draw(
    in context: CGContext, preview: Mark? = nil, replacing: (index: Int, mark: Mark)? = nil,
    hiddenMarks: Set<Int> = []
  ) {
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: NSRect(origin: .zero, size: imageSize))
    context.interpolationQuality = .high
    context.draw(sourceImage, in: NSRect(origin: .zero, size: imageSize))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    var visibleMarks = marks
    if let replacing, visibleMarks.indices.contains(replacing.index),
       visibleMarks[replacing.index].tool == replacing.mark.tool {
      var mark = replacing.mark
      if mark.tool == .mosaic, mark.points != visibleMarks[replacing.index].points {
        mark.mosaic = previewMosaic(in: mark.shapeBounds, blockSize: mark.lineWidth)
      }
      visibleMarks[replacing.index] = mark
    }
    if !hiddenMarks.isEmpty {
      visibleMarks = visibleMarks.enumerated().filter { !hiddenMarks.contains($0.offset) }.map(\.element)
    }
    if var preview, preview.tool.drawsMark {
      if preview.tool == .mosaic {
        preview.mosaic = previewMosaic(in: preview.shapeBounds, blockSize: preview.lineWidth)
      }
      visibleMarks.append(preview)
    }
    let rendered = visibleMarks.map(RenderMark.init)
    let lens = cachedLensSource(marks: rendered)
    for mark in rendered where mark.tool != .redact {
      Self.drawRenderedMark(mark, source: lens, in: context)
    }
    for mark in rendered where mark.tool == .redact {
      Self.drawRenderedMark(mark, source: lens, in: context)
    }
  }

  private struct CoverKey: Equatable {
    let tool: Tool
    let bounds: CGRect
    let lineWidth: CGFloat
    let color: CGColor
  }

  private var lensCache: (covers: [CoverKey], image: CGImage?)?
  private var mosaicCache: (bounds: CGRect, blockSize: CGFloat, image: CGImage?)?
  private(set) var lensSourceRenders = 0
  private(set) var previewMosaicRenders = 0

  private func previewMosaic(in bounds: CGRect, blockSize: CGFloat) -> CGImage? {
    if let mosaicCache, mosaicCache.bounds == bounds, mosaicCache.blockSize == blockSize { return mosaicCache.image }
    let image = Self.pixelated(sourceImage, in: bounds, blockSize: blockSize)
    previewMosaicRenders += 1
    mosaicCache = (bounds, blockSize, image)
    return image
  }

  private func cachedLensSource(marks: [RenderMark]) -> CGImage? {
    guard marks.contains(where: { $0.tool == .magnifier }) else { return nil }
    let covers = Self.covers(marks).map {
      CoverKey(tool: $0.tool, bounds: $0.shapeBounds, lineWidth: $0.lineWidth, color: $0.color)
    }
    if let lensCache, lensCache.covers == covers { return lensCache.image }
    let image = Self.lensSource(sourceImage, marks: marks)
    lensSourceRenders += 1
    lensCache = (covers, image)
    return image
  }

  nonisolated private static func covers(_ marks: [RenderMark]) -> [RenderMark] {
    marks.filter { $0.tool == .mosaic } + marks.filter { $0.tool == .redact }
  }

  // A magnifier enlarges the screenshot with every mosaic and solid cover applied, so it never reveals hidden content.
  nonisolated static func lensSource(_ source: CGImage, marks: [RenderMark]) -> CGImage? {
    guard marks.contains(where: { $0.tool == .magnifier }) else { return nil }
    let covers = covers(marks)
    guard !covers.isEmpty else { return source }
    guard let context = CGContext(
            data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: ScreenshotColorSpace.rgb(source.colorSpace),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
    for mark in covers { drawRenderedMark(mark, source: nil, in: context) }
    return context.makeImage()
  }

  nonisolated private static func drawRenderedMark(_ mark: RenderMark, source: CGImage?, in context: CGContext) {
    guard let first = mark.points.first else { return }
    let last = mark.points.last ?? first
    context.saveGState()
    defer { context.restoreGState() }
    let color = mark.color
    context.setStrokeColor(color)
    context.setLineWidth(mark.lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    switch mark.tool {
    case .arrow:
      context.move(to: first)
      context.addLine(to: last)
      let angle = atan2(last.y - first.y, last.x - first.x)
      let length = min(max(12, mark.lineWidth * 3.5), hypot(last.x - first.x, last.y - first.y) * 0.45)
      for offset: CGFloat in [-0.5, 0.5] {
        context.move(to: last)
        context.addLine(to: NSPoint(
          x: last.x - length * cos(angle + offset), y: last.y - length * sin(angle + offset)
        ))
      }
      context.strokePath()
    case .rectangle:
      context.stroke(mark.shapeBounds)
    case .ellipse:
      context.strokeEllipse(in: mark.shapeBounds)
    case .pen:
      context.addLines(between: mark.points)
      context.strokePath()
    case .text:
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      (mark.text as NSString).draw(at: first, withAttributes: [
        .font: NSFont(name: mark.fontName, size: mark.fontSize) ?? .systemFont(ofSize: mark.fontSize, weight: .semibold),
        .foregroundColor: NSColor(cgColor: color) ?? .red
      ])
    case .number:
      let diameter = mark.fontSize * 1.5
      let circle = CGRect(x: first.x - diameter / 2, y: first.y - diameter / 2, width: diameter, height: diameter)
      context.setFillColor(color)
      context.fillEllipse(in: circle)
      let rgb = NSColor(cgColor: color)?.usingColorSpace(.sRGB)
      let luminance = 0.299 * (rgb?.redComponent ?? 1) + 0.587 * (rgb?.greenComponent ?? 0) + 0.114 * (rgb?.blueComponent ?? 0)
      NSGraphicsContext.saveGraphicsState()
      defer { NSGraphicsContext.restoreGraphicsState() }
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      let label = mark.text as NSString
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: mark.fontSize * (mark.text.count > 2 ? 0.6 : 0.85), weight: .bold),
        .foregroundColor: luminance > 0.6 ? NSColor.black : NSColor.white
      ]
      let size = label.size(withAttributes: attributes)
      label.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2), withAttributes: attributes)
    case .magnifier:
      let lens = mark.shapeBounds
      guard lens.width >= 1, lens.height >= 1 else { return }
      let zoom = max(1, mark.zoom)
      context.saveGState()
      context.addEllipse(in: lens)
      context.clip()
      context.interpolationQuality = .high
      if let source {
        context.draw(source, in: CGRect(
          x: lens.midX * (1 - zoom), y: lens.midY * (1 - zoom),
          width: CGFloat(source.width) * zoom, height: CGFloat(source.height) * zoom
        ))
      } else {
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(lens)
      }
      context.restoreGState()
      context.strokeEllipse(in: lens)
    case .redact:
      context.setShouldAntialias(false)
      context.setBlendMode(.copy)
      context.setFillColor(color)
      context.fill(mark.shapeBounds.integral)
    case .mosaic:
      context.setShouldAntialias(false)
      context.setBlendMode(.copy)
      guard let mosaic = mark.mosaic else {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(mark.shapeBounds.integral)
        return
      }
      context.interpolationQuality = .none
      context.draw(mosaic, in: mark.shapeBounds.integral)
    case .eraser:
      break
    }
  }
}
