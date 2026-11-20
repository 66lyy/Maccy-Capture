import AppKit
import ApplicationServices

@MainActor
final class ScreenshotSelectionView: NSView {
  var onBegin: (() -> Void)?
  var onCapture: ((NSRect, Bool) -> Void)?
  var onChooseDrawingTool: (() -> Void)?
  var onValidSelection: ((NSRect?) -> Void)?
  var canAdjustSelection: (() -> Bool)?
  var onCancel: (() -> Void)?
  var movePointer: ((NSPoint) -> Void)?
  var findElements: (@Sendable (NSPoint) -> [NSRect])?
  private(set) var selectedRect: NSRect?
  var frozen: NSImage? {
    didSet { needsDisplay = true }
  }

  private enum Drag {
    case new(NSPoint)
    case move(NSPoint, NSRect)
    case resize(NSPoint)
  }

  private let scale: CGFloat
  private let pinImmediately: Bool
  private var drag: Drag?
  private var clickSnap: NSRect?
  private var pointer: NSPoint?
  private var snapRects: [NSRect] = []
  private var snapIndex = 0
  private var lastProbe: NSPoint?
  private var probing = false
  private var wantsSnapping = false
  private var elementTask: Task<Void, Never>?
  private let selectionHint = GlassSelectionLabel()
  private let elementHint = GlassSelectionLabel()

  init(frame: NSRect, scale: CGFloat, pinImmediately: Bool) {
    self.scale = scale
    self.pinImmediately = pinImmediately
    super.init(frame: frame)
    setAccessibilityLabel(localized("ScreenshotSelectionHint"))
    addSubview(selectionHint)
    addSubview(elementHint)
    refreshOverlay()
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
  override var isOpaque: Bool { false }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
    if let selectedRect, drag == nil {
      addCursorRect(selectedRect, cursor: .openHand)
      for corner in Self.corners(of: selectedRect) {
        addCursorRect(NSRect(x: corner.x - 6, y: corner.y - 6, width: 12, height: 12), cursor: .crosshair)
      }
    }
    if let toolbar = (window as? ScreenshotSelectionWindow)?.annotationToolbar, !toolbar.isHidden {
      addCursorRect(toolbar.frame, cursor: .arrow)
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
      owner: self, userInfo: nil
    ))
  }

  override func mouseMoved(with event: NSEvent) {
    pointer = convert(event.locationInWindow, from: nil)
    updateProbe(enabled: true)
  }

  override func mouseExited(with event: NSEvent) {
    pointer = nil
    updateProbe(enabled: false)
  }

  override func flagsChanged(with event: NSEvent) {
    pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    updateProbe(enabled: true)
  }

  override func mouseDown(with event: NSEvent) {
    guard canAdjustSelection?() != false else { return }
    window?.makeKey()
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    pointer = point
    if event.clickCount == 2, selectedRect?.contains(point) == true {
      captureSelection(pinToScreen: pinImmediately)
      return
    }
    if event.modifierFlags.contains(.option),
       let snap = snapRectangle(near: point) {
      onBegin?()
      selectedRect = snap
      updateProbe(enabled: false)
      if pinImmediately { captureSelection(pinToScreen: true) }
      updateControls()
      return
    }
    beginSelection(at: point)
  }

  override func mouseDragged(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    pointer = point
    updateSelection(to: point)
  }

  override func mouseUp(with event: NSEvent) {
    endSelection(at: convert(event.locationInWindow, from: nil))
  }

  override func rightMouseDown(with event: NSEvent) {
    onCancel?()
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  override func keyDown(with event: NSEvent) {
    guard canAdjustSelection?() != false else {
      super.keyDown(with: event)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if handleSelectionShortcut(event) { return }
    if ScopedShortcut.closeCapture.matches(event) {
      onCancel?()
      return
    }
    if ScopedShortcut.pinCapture.matches(event) {
      captureSelection(pinToScreen: true)
      return
    }
    if ScopedShortcut.copyCapture.matches(event) || ScopedShortcut.copyCaptureWithCommand.matches(event) {
      if selectedRect == nil, let pointer, let snap = snapRectangle(near: pointer) {
        onBegin?()
        selectedRect = snap
        updateProbe(enabled: false)
        if pinImmediately { captureSelection(pinToScreen: true) }
        updateControls()
      } else {
        captureSelection(pinToScreen: pinImmediately)
      }
      return
    }
    switch event.keyCode {
    case 53:
      onCancel?()
    case 123...126:
      let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
      let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
      let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
      nudge(dx: dx, dy: dy)
    default: break
    }
  }

  func handleSelectionShortcut(_ event: NSEvent) -> Bool {
    guard canAdjustSelection?() != false else { return false }
    if ScopedShortcut.annotateSelection.matches(event) {
      annotateSelection()
    } else if wantsSnapping, ScopedShortcut.selectParent.matches(event) {
      cycleSnap(towardParent: true)
    } else if wantsSnapping, ScopedShortcut.selectChild.matches(event) {
      cycleSnap(towardParent: false)
    } else {
      return false
    }
    return true
  }

  func beginSelection(at point: NSPoint) {
    guard canAdjustSelection?() != false else { return }
    clickSnap = selectedRect == nil ? snapRectangle(near: point) : nil
    updateProbe(enabled: false)
    if let selectedRect, !pinImmediately {
      let corners = Self.corners(of: selectedRect)
      if let index = corners.firstIndex(where: { hypot($0.x - point.x, $0.y - point.y) <= 8 }) {
        drag = .resize(corners[3 - index])
        updateControls()
        return
      }
      if selectedRect.contains(point) {
        drag = .move(point, selectedRect)
        updateControls()
        return
      }
    }
    onBegin?()
    drag = .new(point)
    selectedRect = nil
    updateControls()
  }

  func updateSelection(to point: NSPoint) {
    guard let drag else { return }
    switch drag {
    case .new(let start), .resize(let start):
      selectedRect = Self.rectangle(from: start, to: point, bounds: bounds)
    case .move(let start, let rectangle):
      selectedRect = Self.translated(rectangle, dx: point.x - start.x, dy: point.y - start.y, bounds: bounds)
    }
    updateControls()
  }

  func endSelection(at point: NSPoint) {
    guard let drag else { return }
    updateSelection(to: point)
    if case .new = drag, let selectedRect,
       selectedRect.width < 3 || selectedRect.height < 3,
       let clickSnap {
      self.selectedRect = clickSnap
    }
    self.drag = nil
    clickSnap = nil
    guard let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3 else {
      clearSelection()
      return
    }
    if pinImmediately {
      captureSelection(pinToScreen: true)
    }
    updateControls()
  }

  func clearSelection() {
    drag = nil
    clickSnap = nil
    selectedRect = nil
    updateProbe(enabled: false)
    updateControls()
  }

  func finishInteraction() {
    elementTask?.cancel()
    elementTask = nil
    onBegin = nil
    onCapture = nil
    onChooseDrawingTool = nil
    onValidSelection = nil
    canAdjustSelection = nil
    onCancel = nil
    movePointer = nil
    findElements = nil
  }

  func nudge(dx: CGFloat, dy: CGFloat) {
    guard canAdjustSelection?() != false else { return }
    if drag != nil {
      let point = pointer ?? window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
      guard let point else { return }
      let next = moveCrosshair(from: point, dx: dx, dy: dy)
      updateSelection(to: next)
    } else if let selectedRect {
      self.selectedRect = Self.translated(selectedRect, dx: dx, dy: dy, bounds: bounds)
      updateControls()
    } else if let point = pointer ?? window.map({ convert($0.mouseLocationOutsideOfEventStream, from: nil) }) {
      _ = moveCrosshair(from: point, dx: dx, dy: dy)
      updateProbe(enabled: wantsSnapping)
    }
  }

  func captureSelection(pinToScreen: Bool) {
    guard canAdjustSelection?() != false,
          let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3 else { return }
    onCapture?(selectedRect, pinToScreen)
  }

  private func annotateSelection() {
    guard !pinImmediately, drag == nil, let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3 else { return }
    onChooseDrawingTool?()
  }

  private func updateControls() {
    if let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3, drag == nil, !pinImmediately {
      onValidSelection?(selectedRect)
    } else {
      onValidSelection?(nil)
    }
    window?.invalidateCursorRects(for: self)
    refreshOverlay()
  }

  private func moveCrosshair(from point: NSPoint, dx: CGFloat, dy: CGFloat) -> NSPoint {
    let next = NSPoint(
      x: max(bounds.minX, min((point.x + dx).rounded(), bounds.maxX - 1)),
      y: max(bounds.minY + 1, min((point.y + dy).rounded(), bounds.maxY))
    )
    pointer = next
    movePointer?(next)
    return next
  }

  private func updateProbe(enabled: Bool) {
    wantsSnapping = enabled && selectedRect == nil && drag == nil
    if !wantsSnapping {
      snapRects = []
      lastProbe = nil
      refreshOverlay()
      return
    }
    guard let pointer, bounds.contains(pointer), let findElements, !probing,
          lastProbe.map({ hypot($0.x - pointer.x, $0.y - pointer.y) >= 3 }) ?? true else { return }
    probing = true
    lastProbe = pointer
    snapRects = []
    elementTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) { findElements(pointer) }
      let rectangles = await worker.value
      try? await Task.sleep(for: .milliseconds(50))
      guard let self, !Task.isCancelled else { return }
      probing = false
      elementTask = nil
      if wantsSnapping, self.pointer.map({ hypot($0.x - pointer.x, $0.y - pointer.y) < 3 }) == true {
        snapRects = Self.snapCandidates(rectangles, containing: pointer, bounds: bounds)
        snapIndex = 0
      }
      refreshOverlay()
      if wantsSnapping { updateProbe(enabled: true) }
    }
  }

  private func cycleSnap(towardParent: Bool) {
    guard !snapRects.isEmpty else { return }
    snapIndex = max(0, min(snapRects.count - 1, snapIndex + (towardParent ? 1 : -1)))
    refreshOverlay()
  }

  func snapRectangle(near point: NSPoint) -> NSRect? {
    guard let lastProbe, hypot(lastProbe.x - point.x, lastProbe.y - point.y) < 3,
          snapRects.indices.contains(snapIndex) else { return nil }
    return snapRects[snapIndex]
  }

  static func snapCandidates(_ rectangles: [NSRect], containing point: NSPoint, bounds: NSRect) -> [NSRect] {
    rectangles.reduce(into: []) { result, rectangle in
      let clipped = rectangle.intersection(bounds)
      if clipped.width >= 3, clipped.height >= 3, clipped.contains(point), !result.contains(clipped) {
        result.append(clipped)
      }
    }
  }

  static func translated(_ rect: NSRect, dx: CGFloat, dy: CGFloat, bounds: NSRect) -> NSRect {
    NSRect(
      x: max(bounds.minX, min(rect.minX + dx, bounds.maxX - rect.width)),
      y: max(bounds.minY, min(rect.minY + dy, bounds.maxY - rect.height)),
      width: rect.width, height: rect.height
    )
  }

  private static func corners(of rect: NSRect) -> [NSPoint] {
    [NSPoint(x: rect.minX, y: rect.minY), NSPoint(x: rect.minX, y: rect.maxY),
     NSPoint(x: rect.maxX, y: rect.minY), NSPoint(x: rect.maxX, y: rect.maxY)]
  }

  static func rectangle(from start: NSPoint, to end: NSPoint, bounds: NSRect) -> NSRect {
    let startPoint = NSPoint(
      x: max(bounds.minX, min(start.x, bounds.maxX)), y: max(bounds.minY, min(start.y, bounds.maxY))
    )
    let endPoint = NSPoint(
      x: max(bounds.minX, min(end.x, bounds.maxX)), y: max(bounds.minY, min(end.y, bounds.maxY))
    )
    return NSRect(
      x: min(startPoint.x, endPoint.x), y: min(startPoint.y, endPoint.y),
      width: abs(endPoint.x - startPoint.x), height: abs(endPoint.y - startPoint.y)
    )
  }

  static func pixelPositionText(of point: NSPoint, in bounds: NSRect, scale: CGFloat) -> String {
    let x = min(max(point.x, bounds.minX), bounds.maxX) - bounds.minX
    let y = bounds.maxY - min(max(point.y, bounds.minY), bounds.maxY)
    return "X \(Int(x * scale))  Y \(Int(y * scale))"
  }

  private var activeRect: NSRect? {
    selectedRect ?? pointer.flatMap { snapRectangle(near: $0) }
  }

  private func refreshOverlay() {
    needsDisplay = true
    needsLayout = true
  }

  override func layout() {
    super.layout()
    if let activeRect {
      var dimensions = "\(Int(activeRect.width * scale)) × \(Int(activeRect.height * scale)) px"
      if drag != nil, let pointer {
        dimensions += "  ·  " + Self.pixelPositionText(of: pointer, in: bounds, scale: scale)
      }
      selectionHint.update(dimensions, near: NSPoint(x: activeRect.minX, y: activeRect.maxY + 8), in: bounds)
    } else {
      let key = pinImmediately ? "ScreenshotSelectionPinInstructions" : "ScreenshotSelectionInstructions"
      selectionHint.update(localized(key), near: NSPoint(x: bounds.midX - 190, y: bounds.maxY - 64), in: bounds)
    }
    elementHint.isHidden = !wantsSnapping || snapRects.isEmpty
    if !elementHint.isHidden {
      let title = AXIsProcessTrusted()
        ? String(localized: "ScreenshotElementActions", defaultValue: "Click to select · \(ScopedShortcut.selectParent.current?.description ?? "—") parent · \(ScopedShortcut.selectChild.current?.description ?? "—") child", table: "GeneralSettings")
        : localized("ScreenshotElementPermissionHint")
      elementHint.update(title, near: NSPoint(x: 12, y: 12), in: bounds)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    frozen?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
    let shade = NSBezierPath(rect: bounds)
    let activeRect = self.activeRect
    if let activeRect {
      shade.appendRect(activeRect)
    }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.12).setFill()
    shade.fill()
    if let activeRect {
      // A fully transparent hole would let clicks fall through to the window below.
      NSColor.black.withAlphaComponent(0.001).setFill()
      activeRect.fill(using: .sourceOver)
      NSColor.systemRed.setStroke()
      let border = NSBezierPath(rect: activeRect.insetBy(dx: 1, dy: 1))
      border.lineWidth = 2
      border.stroke()
      if selectedRect != nil, drag == nil {
        for corner in Self.corners(of: activeRect) {
          NSColor.white.setFill()
          let handle = NSBezierPath(ovalIn: NSRect(x: corner.x - 3, y: corner.y - 3, width: 6, height: 6))
          handle.fill()
          handle.stroke()
        }
      }
    }
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}

@MainActor
private final class GlassSelectionLabel: GlassSurfaceView {
  private let label = NSTextField(labelWithString: "")

  init() {
    super.init(frame: .zero, cornerRadius: 12)
    label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    label.lineBreakMode = .byTruncatingTail
    controlsView.addSubview(label)
  }

  required init?(coder: NSCoder) { nil }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(_ text: String, near point: NSPoint, in bounds: NSRect) {
    if label.stringValue != text { label.stringValue = text }
    let textSize = label.cell?.cellSize ?? label.intrinsicContentSize
    let size = NSSize(width: min(ceil(textSize.width) + 24, max(0, bounds.width - 16)),
                      height: ceil(textSize.height) + 10)
    frame = NSRect(
      x: max(bounds.minX + 8, min(point.x, bounds.maxX - size.width - 8)),
      y: max(bounds.minY + 8, min(point.y, bounds.maxY - size.height - 8)),
      width: size.width, height: size.height
    )
    label.frame = NSRect(origin: .zero, size: size).insetBy(dx: 10, dy: 5).integral
  }
}
