import AppKit

@MainActor
final class ScreenshotAnnotationCanvas: NSView, NSTextFieldDelegate {
  private struct TextDrag {
    let index: Int
    let start: NSPoint
    let origin: NSPoint
    let size: NSSize
    var position: NSPoint
  }

  let document: ScreenshotAnnotationDocument
  var onChange: (() -> Void)?
  var onCancel: (() -> Void)?
  var onBeginMark: (() -> Void)?
  var tool: ScreenshotAnnotationDocument.Tool = .arrow
  var color = NSColor.red
  var lineWidth: CGFloat = 3
  var fontSize: CGFloat = 24
  var imageInset: CGFloat = 16
  var canvasBackgroundColor = NSColor.underPageBackgroundColor
  private(set) var textField: NSTextField?
  private var textOrigin: NSPoint?
  private var textScale: CGFloat = 1
  private var pendingMark: ScreenshotAnnotationDocument.Mark?
  private var textDrag: TextDrag?
  var isMovingText: Bool { textDrag != nil }

  var imageRect: NSRect {
    Self.imageRect(imageSize: document.imageSize, bounds: bounds.insetBy(dx: imageInset, dy: imageInset))
  }
  private var imageScale: CGFloat { imageRect.width / document.imageSize.width }

  init(document: ScreenshotAnnotationDocument) {
    self.document = document
    super.init(frame: .zero)
    setAccessibilityLabel(text("AnnotationCanvasHelp"))
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func resetCursorRects() {
    addCursorRect(imageRect, cursor: tool == .text ? .iBeam : .crosshair)
  }

  override func draw(_ dirtyRect: NSRect) {
    canvasBackgroundColor.setFill()
    bounds.fill(using: .copy)
    guard let context = NSGraphicsContext.current?.cgContext, imageScale > 0 else { return }
    context.saveGState()
    context.translateBy(x: imageRect.minX, y: imageRect.minY)
    context.scaleBy(x: imageScale, y: imageScale)
    document.draw(in: context, preview: pendingMark, movingText: textDrag.map { ($0.index, $0.position) })
    context.restoreGState()
  }

  override func mouseDown(with event: NSEvent) {
    commitText()
    window?.makeFirstResponder(self)
    beginMark(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseDragged(with event: NSEvent) {
    updateMark(to: convert(event.locationInWindow, from: nil))
    if isMovingText { NSCursor.closedHand.set() }
  }

  override func mouseUp(with event: NSEvent) {
    let wasMovingText = isMovingText
    endMark(at: convert(event.locationInWindow, from: nil))
    if wasMovingText { NSCursor.iBeam.set() }
  }

  override func rightMouseDown(with event: NSEvent) {
    onCancel?()
  }

  func beginMark(at point: NSPoint) {
    guard let imagePoint = imagePoint(at: point) else { return }
    onBeginMark?()
    if tool == .text {
      if let index = document.textMarkIndex(at: imagePoint, padding: 3 / imageScale),
         let origin = document.marks[index].points.first {
        textDrag = TextDrag(index: index, start: point, origin: origin,
                            size: document.marks[index].textSize, position: origin)
      } else {
        beginText(at: point)
      }
      return
    }
    pendingMark = ScreenshotAnnotationDocument.Mark(
      tool: tool, points: [imagePoint], color: color, lineWidth: lineWidth / imageScale,
      fontSize: fontSize / imageScale
    )
    needsDisplay = true
  }

  func updateMark(to point: NSPoint) {
    if let drag = textDrag {
      guard point.x.isFinite, point.y.isFinite, imageScale > 0 else { return }
      let maxX = max(0, document.imageSize.width - ceil(drag.size.width))
      let maxY = max(0, document.imageSize.height - ceil(drag.size.height))
      textDrag?.position = point == drag.start ? drag.origin : NSPoint(
        x: max(0, min(maxX, drag.origin.x + (point.x - drag.start.x) / imageScale)),
        y: max(0, min(maxY, drag.origin.y + (point.y - drag.start.y) / imageScale))
      )
      needsDisplay = true
      return
    }
    guard let tool = pendingMark?.tool, let imagePoint = imagePoint(at: point, clamped: true) else { return }
    if tool == .pen {
      if (pendingMark?.points.count ?? 0) < 50_000 { pendingMark?.points.append(imagePoint) }
    } else {
      guard let first = pendingMark?.points.first else { return }
      pendingMark?.points = [first, imagePoint]
    }
    needsDisplay = true
  }

  func endMark(at point: NSPoint) {
    updateMark(to: point)
    if let drag = textDrag {
      textDrag = nil
      document.moveText(at: drag.index, to: drag.position)
      changed()
      return
    }
    guard let mark = pendingMark else { return }
    pendingMark = nil
    document.append(mark)
    changed()
  }

  func commitText() {
    guard let field = textField, let origin = textOrigin else { return }
    textField = nil
    textOrigin = nil
    let value = field.currentEditor()?.string ?? field.stringValue
    field.removeFromSuperview()
    document.append(.init(
      tool: .text, points: [origin], color: field.textColor ?? color,
      text: value, fontSize: (field.font?.pointSize ?? fontSize) / textScale
    ))
    changed()
  }

  func discardPendingMark() {
    cancelTextDrag()
    pendingMark = nil
    let field = textField
    textField = nil
    textOrigin = nil
    field?.removeFromSuperview()
    changed()
  }

  func cancelTextDrag() {
    guard isMovingText else { return }
    textDrag = nil
    needsDisplay = true
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    commitText()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      commitText()
      window?.makeFirstResponder(self)
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      discardPendingMark()
      window?.makeFirstResponder(self)
      return true
    }
    return false
  }

  func imagePoint(at point: NSPoint, clamped: Bool = false) -> NSPoint? {
    let rectangle = imageRect
    guard point.x.isFinite, point.y.isFinite, imageScale > 0,
          clamped || rectangle.contains(point) else { return nil }
    return NSPoint(
      x: max(0, min(document.imageSize.width, (point.x - rectangle.minX) / imageScale)),
      y: max(0, min(document.imageSize.height, (point.y - rectangle.minY) / imageScale))
    )
  }

  static func imageRect(imageSize: NSSize, bounds: NSRect) -> NSRect {
    guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return NSRect(
      x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height
    )
  }

  private func beginText(at point: NSPoint) {
    let field = NSTextField()
    field.font = .systemFont(ofSize: fontSize, weight: .semibold)
    field.textColor = color.withAlphaComponent(1)
    field.backgroundColor = .textBackgroundColor
    field.drawsBackground = true
    field.isBordered = true
    field.placeholderString = text("AnnotationEnterText")
    field.delegate = self
    let width = min(360, imageRect.width)
    let height = min(fontSize + 12, imageRect.height)
    field.frame = NSRect(
      x: max(imageRect.minX, min(point.x, imageRect.maxX - width)),
      y: max(imageRect.minY, min(point.y, imageRect.maxY - height)), width: width, height: height
    )
    textOrigin = imagePoint(at: field.frame.origin, clamped: true)
    textScale = imageScale
    textField = field
    addSubview(field)
    window?.makeFirstResponder(field)
  }

  private func changed() {
    needsDisplay = true
    onChange?()
  }

  private func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}
