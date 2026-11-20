import AppKit

@MainActor
final class ScreenshotAnnotationCanvas: NSView, NSTextFieldDelegate {
  private struct MarkDrag {
    let index: Int
    let start: NSPoint
    let original: ScreenshotAnnotationDocument.Mark
    let handle: Int?
    var current: ScreenshotAnnotationDocument.Mark
  }

  private static let handleSize: CGFloat = 8

  let document: ScreenshotAnnotationDocument
  var onChange: (() -> Void)?
  var onCancel: (() -> Void)?
  var onBeginMark: (() -> Void)?
  var tool: ScreenshotAnnotationDocument.Tool = .arrow
  var color = NSColor.red
  var lineWidth: CGFloat = 3
  var fontSize: CGFloat = 24
  var mosaicSize: CGFloat = 12
  var magnifierZoom: CGFloat = 2
  var imageInset: CGFloat = 16
  var canvasBackgroundColor = NSColor.underPageBackgroundColor
  private(set) var textField: NSTextField?
  private var textOrigin: NSPoint?
  private var textScale: CGFloat = 1
  private var pendingMark: ScreenshotAnnotationDocument.Mark?
  private var markDrag: MarkDrag?
  private var erasing: (last: NSPoint, indices: Set<Int>)?
  private var selection: (index: Int, revision: Int)?
  var isMovingMark: Bool { markDrag != nil }
  var isMovingText: Bool { isMovingMark }
  var selectedMarkIndex: Int? {
    if let markDrag { return markDrag.index }
    guard let selection, selection.revision == document.revision,
          document.marks.indices.contains(selection.index) else { return nil }
    return selection.index
  }

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
    document.draw(
      in: context, preview: pendingMark, replacing: markDrag.map { ($0.index, $0.current) },
      hiddenMarks: erasing?.indices ?? []
    )
    context.restoreGState()
    drawSelection()
  }

  private func drawSelection() {
    guard erasing == nil, let index = selectedMarkIndex else { return }
    let mark = markDrag?.current ?? document.marks[index]
    let origin = imageRect.origin, scale = imageScale
    func view(_ point: NSPoint) -> NSPoint { NSPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale) }
    let box = mark.bounds
    let frame = NSRect(origin: view(box.origin), size: NSSize(width: box.width * scale, height: box.height * scale))
      .insetBy(dx: -3, dy: -3)
    let outline = NSBezierPath(rect: frame)
    outline.lineWidth = 1
    outline.setLineDash([4, 3], count: 2, phase: 0)
    NSColor.controlAccentColor.setStroke()
    outline.stroke()
    for point in mark.handlePoints.map(view) {
      let handle = NSBezierPath(rect: NSRect(
        x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize
      ))
      NSColor.white.setFill()
      handle.fill()
      handle.lineWidth = 1
      NSColor.controlAccentColor.setStroke()
      handle.stroke()
    }
  }

  override func keyDown(with event: NSEvent) {
    if [51, 117].contains(event.keyCode), event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
       deleteSelectedMark() {
      return
    }
    super.keyDown(with: event)
  }

  @discardableResult
  func deleteSelectedMark() -> Bool {
    guard markDrag == nil, let index = selectedMarkIndex else { return false }
    selection = nil
    guard document.removeMarks(at: [index]) else { return false }
    changed()
    return true
  }

  override func mouseDown(with event: NSEvent) {
    commitText()
    window?.makeFirstResponder(self)
    beginMark(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseDragged(with event: NSEvent) {
    updateMark(to: convert(event.locationInWindow, from: nil))
    if isMovingMark { NSCursor.closedHand.set() }
  }

  override func mouseUp(with event: NSEvent) {
    let wasMoving = isMovingMark
    endMark(at: convert(event.locationInWindow, from: nil))
    if wasMoving { (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set() }
  }

  override func rightMouseDown(with event: NSEvent) {
    onCancel?()
  }

  func beginMark(at point: NSPoint) {
    if tool != .pen, tool != .eraser, let handle = handleDrag(at: point) {
      onBeginMark?()
      markDrag = handle
      needsDisplay = true
      return
    }
    guard let imagePoint = imagePoint(at: point) else { return }
    onBeginMark?()
    if tool != .pen, tool != .eraser,
       let index = document.markIndex(at: imagePoint, tolerance: (tool == .text ? 3 : 4) / imageScale) {
      let mark = document.marks[index]
      markDrag = MarkDrag(index: index, start: point, original: mark, handle: nil, current: mark)
      needsDisplay = true
      return
    }
    selection = nil
    if tool == .text {
      beginText(at: point)
      return
    }
    if tool == .eraser {
      erasing = (imagePoint, [])
      erase(along: imagePoint, to: imagePoint)
      return
    }
    pendingMark = ScreenshotAnnotationDocument.Mark(
      tool: tool, points: [imagePoint], color: color,
      lineWidth: (tool == .mosaic ? mosaicSize : tool == .magnifier ? 3 : lineWidth) / imageScale,
      text: tool == .number ? "\(document.nextNumber)" : "",
      fontSize: fontSize / imageScale, zoom: magnifierZoom
    )
    needsDisplay = true
  }

  private func handleDrag(at point: NSPoint) -> MarkDrag? {
    guard let index = selectedMarkIndex, imageScale > 0 else { return nil }
    let mark = document.marks[index]
    let origin = imageRect.origin
    let reach = Self.handleSize / 2 + 2
    guard let handle = mark.handlePoints.firstIndex(where: {
      hypot(origin.x + $0.x * imageScale - point.x, origin.y + $0.y * imageScale - point.y) <= reach
    }) else { return nil }
    return MarkDrag(index: index, start: point, original: mark, handle: handle, current: mark)
  }

  func updateMark(to point: NSPoint) {
    if let drag = markDrag {
      guard point.x.isFinite, point.y.isFinite, imageScale > 0 else { return }
      let dx = (point.x - drag.start.x) / imageScale, dy = (point.y - drag.start.y) / imageScale
      if point == drag.start {
        markDrag?.current = drag.original
      } else if let handle = drag.handle {
        let start = drag.original.handlePoints[handle]
        let size = document.imageSize
        markDrag?.current = drag.original.resized(handle: handle, to: NSPoint(
          x: max(0, min(size.width, start.x + dx)), y: max(0, min(size.height, start.y + dy))
        ))
      } else {
        markDrag?.current = drag.original.moved(by: dx, dy, within: document.imageSize)
      }
      needsDisplay = true
      return
    }
    if let last = erasing?.last {
      guard let imagePoint = imagePoint(at: point, clamped: true) else { return }
      erase(along: last, to: imagePoint)
      return
    }
    guard let tool = pendingMark?.tool, let imagePoint = imagePoint(at: point, clamped: true) else { return }
    if tool == .pen {
      if (pendingMark?.points.count ?? 0) < 50_000 { pendingMark?.points.append(imagePoint) }
    } else if tool == .number {
      pendingMark?.points = [imagePoint]
    } else {
      guard let first = pendingMark?.points.first else { return }
      pendingMark?.points = [first, imagePoint]
    }
    needsDisplay = true
  }

  func endMark(at point: NSPoint) {
    updateMark(to: point)
    if let drag = markDrag {
      markDrag = nil
      document.replaceMark(at: drag.index, with: drag.current)
      select(drag.index)
      changed()
      return
    }
    if let erased = erasing?.indices {
      erasing = nil
      document.removeMarks(at: erased)
      changed()
      return
    }
    guard let mark = pendingMark else { return }
    pendingMark = nil
    if document.append(mark), mark.tool != .pen { select(document.marks.count - 1) }
    changed()
  }

  private func select(_ index: Int) {
    selection = (index, document.revision)
  }

  func commitText() {
    guard let field = textField, let origin = textOrigin else { return }
    textField = nil
    textOrigin = nil
    let value = field.currentEditor()?.string ?? field.stringValue
    field.removeFromSuperview()
    if document.append(.init(
      tool: .text, points: [origin], color: field.textColor ?? color,
      text: value, fontSize: (field.font?.pointSize ?? fontSize) / textScale
    )) {
      select(document.marks.count - 1)
    }
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
    guard isMovingMark || erasing != nil else { return }
    markDrag = nil
    erasing = nil
    needsDisplay = true
  }

  private func erase(along start: NSPoint, to end: NSPoint) {
    guard imageScale > 0 else { return }
    let tolerance = 5 / imageScale
    let steps = max(1, Int((hypot(end.x - start.x, end.y - start.y) / tolerance).rounded(.up)))
    var indices = erasing?.indices ?? []
    for step in 0...steps {
      let fraction = CGFloat(step) / CGFloat(steps)
      let point = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
      if let index = document.markIndex(at: point, tolerance: tolerance, excluding: indices) {
        indices.insert(index)
      }
    }
    erasing = (end, indices)
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
