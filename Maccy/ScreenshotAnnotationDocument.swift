import AppKit

@MainActor
final class ScreenshotAnnotationDocument {
  enum Tool: Int, CaseIterable {
    case arrow, rectangle, ellipse, pen, text, redact

    var titleKey: String {
      switch self {
      case .arrow: "AnnotationArrow"
      case .rectangle: "AnnotationRectangle"
      case .ellipse: "AnnotationEllipse"
      case .pen: "AnnotationPen"
      case .text: "AnnotationText"
      case .redact: "AnnotationRedact"
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

    var textFont: NSFont { .systemFont(ofSize: fontSize, weight: .semibold) }
    var textSize: NSSize { (text as NSString).size(withAttributes: [.font: textFont]) }

    var shapeBounds: NSRect {
      guard let first = points.first, let last = points.last else { return .zero }
      return NSRect(
        x: min(first.x, last.x), y: min(first.y, last.y),
        width: abs(last.x - first.x), height: abs(last.y - first.y)
      )
    }
  }

  private enum Edit {
    case append(Mark)
    case moveText(index: Int, from: NSPoint, to: NSPoint)
  }

  let sourceImage: CGImage
  var imageSize: NSSize { NSSize(width: sourceImage.width, height: sourceImage.height) }
  private(set) var marks: [Mark] = []
  private var undoEdits: [Edit] = []
  private var redoEdits: [Edit] = []
  var canUndo: Bool { !undoEdits.isEmpty }
  var canRedo: Bool { !redoEdits.isEmpty }

  init?(image: NSImage) {
    guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          source.width > 0, source.height > 0,
          source.width <= 100_000_000 / source.height else { return nil }
    sourceImage = source
  }

  @discardableResult
  func append(_ mark: Mark) -> Bool {
    guard !mark.points.isEmpty,
          mark.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
          mark.lineWidth.isFinite, mark.lineWidth > 0,
          mark.fontSize.isFinite, mark.fontSize > 0 else { return false }
    if mark.tool == .text {
      guard !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            mark.text.count <= 4096 else { return false }
    } else {
      guard mark.points.count >= 2, let first = mark.points.first, let last = mark.points.last else { return false }
      if mark.tool == .pen {
        guard mark.points.contains(where: { hypot($0.x - first.x, $0.y - first.y) >= 1 }) else { return false }
      } else if mark.tool == .arrow {
        guard hypot(last.x - first.x, last.y - first.y) >= 1 else { return false }
      } else {
        guard abs(last.x - first.x) >= 1, abs(last.y - first.y) >= 1 else { return false }
      }
    }
    record(.append(mark))
    return true
  }

  func textMarkIndex(at point: NSPoint, padding: CGFloat) -> Int? {
    guard !marks.contains(where: { $0.tool == .redact && $0.shapeBounds.integral.contains(point) }) else { return nil }
    return marks.indices.reversed().first { index in
      let mark = marks[index]
      guard mark.tool == .text, let origin = mark.points.first else { return false }
      return NSRect(origin: origin, size: mark.textSize).insetBy(dx: -padding, dy: -padding).contains(point)
    }
  }

  @discardableResult
  func moveText(at index: Int, to position: NSPoint) -> Bool {
    guard marks.indices.contains(index), marks[index].tool == .text,
          let origin = marks[index].points.first, position != origin,
          position.x.isFinite, position.y.isFinite else { return false }
    record(.moveText(index: index, from: origin, to: position))
    return true
  }

  func undo() {
    guard let edit = undoEdits.popLast() else { return }
    switch edit {
    case .append: marks.removeLast()
    case .moveText(let index, let origin, _): marks[index].points[0] = origin
    }
    redoEdits.append(edit)
  }

  func redo() {
    guard let edit = redoEdits.popLast() else { return }
    apply(edit)
    undoEdits.append(edit)
  }

  private func record(_ edit: Edit) {
    apply(edit)
    undoEdits.append(edit)
    redoEdits.removeAll()
  }

  private func apply(_ edit: Edit) {
    switch edit {
    case .append(let mark): marks.append(mark)
    case .moveText(let index, _, let position): marks[index].points[0] = position
    }
  }

  func pngData() -> Data? {
    guard let image = renderedImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  func renderedImage() -> CGImage? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: sourceImage.width, height: sourceImage.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return nil }
    draw(in: context)
    return context.makeImage()
  }

  func draw(in context: CGContext, preview: Mark? = nil, movingText: (index: Int, position: NSPoint)? = nil) {
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: NSRect(origin: .zero, size: imageSize))
    context.interpolationQuality = .high
    context.draw(sourceImage, in: NSRect(origin: .zero, size: imageSize))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    var visibleMarks = marks
    if let movingText, visibleMarks.indices.contains(movingText.index),
       visibleMarks[movingText.index].tool == .text {
      visibleMarks[movingText.index].points[0] = movingText.position
    }
    if let preview { visibleMarks.append(preview) }
    for mark in visibleMarks where mark.tool != .redact {
      draw(mark, in: context)
    }
    for mark in visibleMarks where mark.tool == .redact {
      draw(mark, in: context)
    }
  }

  private func draw(_ mark: Mark, in context: CGContext) {
    guard let first = mark.points.first else { return }
    let last = mark.points.last ?? first
    context.saveGState()
    defer { context.restoreGState() }
    let color = (mark.color.usingColorSpace(.sRGB) ?? .red).withAlphaComponent(1)
    context.setStrokeColor(color.cgColor)
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
      (mark.text as NSString).draw(at: first, withAttributes: [
        .font: mark.textFont,
        .foregroundColor: color
      ])
    case .redact:
      context.setShouldAntialias(false)
      context.setBlendMode(.copy)
      context.setFillColor(color.cgColor)
      context.fill(mark.shapeBounds.integral)
    }
  }
}
