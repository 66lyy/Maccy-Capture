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
  var canPickColor: (() -> Bool)?
  var findElementWindow: ((NSPoint) -> ScreenshotElementDetection.Window?)?
  var findElements: (@Sendable (NSPoint, ScreenshotElementDetection.Window) -> ScreenshotElementDetection.Result)?
  var elementProbe = ScreenshotElementProbe()
  private(set) var selectedRect: NSRect?
  var hasSelectionInteraction: Bool { selectedRect != nil || drag != nil || colorCopyTask != nil }
  private(set) var frozen: NSImage?
  var isScrolling = false {
    didSet {
      selectionHint.isHidden = isScrolling
      elementHint.isHidden = isScrolling
      updateLoupe()
      needsDisplay = true
    }
  }

  private enum Drag {
    case new(NSPoint)
    case move(NSPoint, NSRect)
    case resize(NSPoint)
  }

  private let scale: CGFloat
  private let pixelSize: CGSize?
  private let pinImmediately: Bool
  private var drag: Drag?
  private var clickSnap: NSRect?
  private var pointer: NSPoint?
  private var snapRects: [NSRect] = []
  private var snapIndex = 0
  private var lastProbe: NSPoint?
  private var probeID: UUID?
  private var probePID: pid_t?
  private var drawnBounds: NSRect?
  private var drawnActiveRect: NSRect?
  private var drawnHandles = false
  private var wantsSnapping = false
  private let selectionHint = GlassSelectionLabel()
  private let elementHint = GlassSelectionLabel()
  private let loupe = ScreenshotPixelLoupe()
  private var colorCopyTask: Task<Void, Never>?

  init(frame: NSRect, scale: CGFloat, pinImmediately: Bool, pixelSize: CGSize? = nil) {
    self.scale = scale
    self.pixelSize = pixelSize
    self.pinImmediately = pinImmediately
    super.init(frame: frame)
    setAccessibilityLabel(localized("ScreenshotSelectionHint"))
    addSubview(selectionHint)
    addSubview(elementHint)
    addSubview(loupe)
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
    moveHover(to: convert(event.locationInWindow, from: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    moveHover(to: convert(event.locationInWindow, from: nil))
  }

  func moveHover(to point: NSPoint) {
    pointer = point
    if canShowLoupe, let window, window.isVisible, !window.isKeyWindow {
      window.makeKey()
      window.makeFirstResponder(self)
    }
    updateProbe(enabled: true)
  }

  override func mouseExited(with event: NSEvent) {
    pointer = nil
    updateProbe(enabled: false)
  }

  override func flagsChanged(with event: NSEvent) {
    if pointer == nil, let window, window.isKeyWindow {
      pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }
    updateProbe(enabled: true)
  }

  override func mouseDown(with event: NSEvent) {
    guard colorCopyTask == nil, canAdjustSelection?() != false else { return }
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
    guard colorCopyTask == nil else { return }
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
    if handleColorShortcut(event) { return }
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

  func setFrozenImage(_ image: CGImage?) {
    frozen = image.map { NSImage(cgImage: $0, size: bounds.size) }
    loupe.source = image
    updateLoupe()
    needsDisplay = true
  }

  func handleColorShortcut(_ event: NSEvent, to target: NSPasteboard? = nil) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift, .function])
    guard event.charactersIgnoringModifiers?.lowercased() == "c",
          modifiers.isEmpty || modifiers == .shift, !loupe.isHidden,
          let color = loupe.color else { return false }
    guard colorCopyTask == nil else { return true }
    let pasteboard = target ?? .general
    pasteboard.clearContents()
    let value = modifiers == .shift ? color.rgb : color.hex
    guard pasteboard.setString(value, forType: .string) else { return true }
    loupe.copied = localized("AnnotationTextCopied")
    colorCopyTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
      self?.onCancel?()
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
    colorCopyTask?.cancel()
    colorCopyTask = nil
    probeID = nil
    probePID = nil
    onBegin = nil
    onCapture = nil
    onChooseDrawingTool = nil
    onValidSelection = nil
    canAdjustSelection = nil
    onCancel = nil
    movePointer = nil
    canPickColor = nil
    findElements = nil
    findElementWindow = nil
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
      if canShowLoupe, let image = loupe.source {
        let next = ScreenshotPixelLoupe.nudged(point, dx: dx, dy: dy, in: bounds, image: image)
        pointer = next
        movePointer?(next)
      } else {
        _ = moveCrosshair(from: point, dx: dx, dy: dy)
      }
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
    updateLoupe()
    wantsSnapping = enabled && selectedRect == nil && drag == nil
    if !wantsSnapping {
      snapRects = []
      lastProbe = nil
      refreshOverlay()
      return
    }
    guard let pointer, bounds.contains(pointer), let findElements,
          lastProbe.map({ hypot($0.x - pointer.x, $0.y - pointer.y) >= 3 }) ?? true else { return }
    guard let window = findElementWindow?(pointer) else {
      probeID = nil
      probePID = nil
      snapRects = []
      lastProbe = pointer
      refreshOverlay()
      return
    }
    guard probeID == nil || probePID != window.pid else { return }
    let id = UUID()
    probeID = id
    probePID = window.pid
    lastProbe = pointer
    snapRects = []
    refreshOverlay()
    let started = elementProbe.start(at: pointer, in: window, detect: findElements) { [weak self] result in
      guard let self, probeID == id else { return }
      probeID = nil
      probePID = nil
      if wantsSnapping, self.pointer.map({ hypot($0.x - pointer.x, $0.y - pointer.y) < 3 }) == true {
        snapRects = Self.snapCandidates(result.rectangles, containing: pointer, bounds: bounds)
        snapIndex = 0
      }
      refreshOverlay()
      if wantsSnapping { updateProbe(enabled: true) }
    }
    if !started {
      probeID = nil
      probePID = nil
      snapRects = Self.snapCandidates([window.frame], containing: pointer, bounds: bounds)
      snapIndex = 0
      refreshOverlay()
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

  static func pixelPositionText(of point: NSPoint, in bounds: NSRect, scale: CGFloat, verticalScale: CGFloat? = nil) -> String {
    let x = min(max(point.x, bounds.minX), bounds.maxX) - bounds.minX
    let y = bounds.maxY - min(max(point.y, bounds.minY), bounds.maxY)
    return "X \(Int(x * scale))  Y \(Int(y * (verticalScale ?? scale)))"
  }

  private var activeRect: NSRect? {
    selectedRect ?? pointer.flatMap { snapRectangle(near: $0) }
  }

  private func refreshOverlay() {
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  private var canShowLoupe: Bool {
    loupe.source != nil && !isScrolling && drag == nil && selectedRect == nil && canPickColor?() != false
  }

  private func updateLoupe() {
    guard colorCopyTask == nil else { return }
    let oldFrame = loupe.isHidden ? nil : loupe.frame
    if canShowLoupe, let pointer,
       pointer.x >= bounds.minX, pointer.x <= bounds.maxX,
       pointer.y >= bounds.minY, pointer.y <= bounds.maxY {
      loupe.update(near: pointer, in: bounds)
      loupe.isHidden = false
    } else {
      loupe.isHidden = true
    }
    let newFrame = loupe.isHidden ? nil : loupe.frame
    if oldFrame != newFrame {
      for frame in [oldFrame, newFrame].compactMap({ $0 }) {
        setNeedsDisplay(frame.intersection(bounds))
      }
    }
  }

  static func dirtyRect(from old: NSRect?, to new: NSRect?, in bounds: NSRect) -> NSRect? {
    let rectangles = [old, new].compactMap { $0 }.filter { !$0.isEmpty }
    guard let first = rectangles.first else { return nil }
    return rectangles.dropFirst().reduce(first) { $0.union($1) }
      .insetBy(dx: -8, dy: -8).integral.intersection(bounds)
  }

  override func layout() {
    super.layout()
    updateLoupe()
    let showsHandles = selectedRect != nil && drag == nil && !isScrolling
    let oldLabels = [selectionHint, elementHint].filter { !$0.isHidden }.map(\.frame)
    defer {
      if drawnBounds != bounds {
        needsDisplay = true
      } else if drawnActiveRect != activeRect || drawnHandles != showsHandles,
                let dirty = Self.dirtyRect(from: drawnActiveRect, to: activeRect, in: bounds) {
        setNeedsDisplay(dirty)
      }
      let newLabels = [selectionHint, elementHint].filter { !$0.isHidden }.map(\.frame)
      for rect in oldLabels + newLabels {
        setNeedsDisplay(rect.insetBy(dx: -8, dy: -8).intersection(bounds))
      }
      drawnBounds = bounds
      drawnActiveRect = activeRect
      drawnHandles = showsHandles
    }
    if isScrolling {
      selectionHint.isHidden = true
      elementHint.isHidden = true
      return
    }
    if let activeRect {
      let rasterSize = loupe.source.map { CGSize(width: $0.width, height: $0.height) } ?? pixelSize
        ?? CGSize(width: bounds.width * scale, height: bounds.height * scale)
      let topLeftRect = CGRect(
        x: activeRect.minX - bounds.minX, y: bounds.maxY - activeRect.maxY,
        width: activeRect.width, height: activeRect.height
      ).integral
      let pixels = ScreenshotSelectionController.Display.pixelBounds(
        for: topLeftRect, canvasSize: bounds.size, rasterSize: rasterSize
      )
      var dimensions = "\(Int(pixels.width)) × \(Int(pixels.height)) px"
      if drag != nil, let pointer, !bounds.isEmpty {
        dimensions += "  ·  " + Self.pixelPositionText(
          of: pointer, in: bounds, scale: rasterSize.width / bounds.width, verticalScale: rasterSize.height / bounds.height
        )
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
    if !isScrolling { frozen?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1) }
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
      if !isScrolling {
        NSColor.black.withAlphaComponent(0.001).setFill()
        activeRect.fill(using: .sourceOver)
      }
      NSColor.systemRed.setStroke()
      let border = NSBezierPath(rect: activeRect.insetBy(dx: 1, dy: 1))
      border.lineWidth = 2
      border.stroke()
      if selectedRect != nil, drag == nil, !isScrolling {
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
final class ScreenshotPixelLoupe: NSView {
  struct Color: Equatable {
    let red: Int
    let green: Int
    let blue: Int

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }
  }

  var source: CGImage? {
    didSet { currentPixel = nil }
  }
  private(set) var color: Color?
  var copied: String? {
    didSet { needsDisplay = true }
  }
  private var currentPixel: CGPoint?
  private var patch: NSImage?
  private var patchFrame: NSRect = .zero
  private let cell: CGFloat = 12
  private let radius: CGFloat = 4
  private let size = NSSize(width: 176, height: 176)
  private var grid: NSRect {
    let side = (2 * radius + 1) * cell
    return NSRect(x: (size.width - side) / 2, y: 60, width: side, height: side)
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  static func pixel(at point: NSPoint, in bounds: NSRect, image: CGImage) -> CGPoint {
    CGPoint(
      x: max(0, min(floor((point.x - bounds.minX) * CGFloat(image.width) / bounds.width), CGFloat(image.width - 1))),
      y: max(0, min(floor((bounds.maxY - point.y) * CGFloat(image.height) / bounds.height), CGFloat(image.height - 1)))
    )
  }

  static func nudged(_ point: NSPoint, dx: CGFloat, dy: CGFloat, in bounds: NSRect, image: CGImage) -> NSPoint {
    let start = pixel(at: point, in: bounds, image: image)
    let x = max(0, min(start.x + dx, CGFloat(image.width - 1)))
    let y = max(0, min(start.y - dy, CGFloat(image.height - 1)))
    return NSPoint(
      x: bounds.minX + (x + 0.5) * bounds.width / CGFloat(image.width),
      y: bounds.maxY - (y + 0.5) * bounds.height / CGFloat(image.height)
    )
  }

  static func sample(_ image: CGImage, at pixel: CGPoint) -> Color? {
    guard let crop = image.cropping(to: CGRect(origin: pixel, size: CGSize(width: 1, height: 1))),
          let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: ScreenshotColorSpace.rgb(image.colorSpace),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
          ), let rgba = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Color(red: Int(rgba[0]), green: Int(rgba[1]), blue: Int(rgba[2]))
  }

  func update(near point: NSPoint, in bounds: NSRect) {
    guard let source, !bounds.isEmpty else { return }
    let gap: CGFloat = 20
    let right = point.x + gap
    let above = point.y + gap
    let x = right + size.width <= bounds.maxX ? right : point.x - gap - size.width
    let y = above + size.height <= bounds.maxY ? above : point.y - gap - size.height
    let origin = NSPoint(
      x: max(bounds.minX, min(x.rounded(), bounds.maxX - size.width)),
      y: max(bounds.minY, min(y.rounded(), bounds.maxY - size.height))
    )
    let nextFrame = NSRect(origin: origin, size: size)
    if frame != nextFrame { frame = nextFrame }

    let pixel = Self.pixel(at: point, in: bounds, image: source)
    guard currentPixel != pixel else { return }
    currentPixel = pixel
    color = Self.sample(source, at: pixel)
    let side = 2 * radius + 1
    let neighborhood = CGRect(x: pixel.x - radius, y: pixel.y - radius, width: side, height: side)
    let crop = neighborhood.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    patch = source.cropping(to: crop).map { NSImage(cgImage: $0, size: crop.size) }
    patchFrame = NSRect(
      x: grid.minX + (crop.minX - neighborhood.minX) * cell,
      y: grid.minY + (neighborhood.maxY - crop.maxY) * cell,
      width: crop.width * cell, height: crop.height * cell
    )
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    NSColor(white: 0.13, alpha: 0.97).setFill()
    background.fill()
    NSColor.white.withAlphaComponent(0.35).setStroke()
    background.stroke()
    NSColor(white: 0.23, alpha: 1).setFill()
    grid.fill()
    patch?.draw(in: patchFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none])

    let lines = NSBezierPath()
    for index in 0...Int(2 * radius + 1) {
      let offset = CGFloat(index) * cell
      lines.move(to: NSPoint(x: grid.minX + offset, y: grid.minY))
      lines.line(to: NSPoint(x: grid.minX + offset, y: grid.maxY))
      lines.move(to: NSPoint(x: grid.minX, y: grid.minY + offset))
      lines.line(to: NSPoint(x: grid.maxX, y: grid.minY + offset))
    }
    NSColor.black.withAlphaComponent(0.45).setStroke()
    lines.stroke()
    let center = NSRect(x: grid.midX - cell / 2, y: grid.midY - cell / 2, width: cell, height: cell)
    NSColor.black.setStroke()
    NSBezierPath.stroke(center.insetBy(dx: -1.5, dy: -1.5))
    NSColor.white.setStroke()
    NSBezierPath.stroke(center.insetBy(dx: -0.5, dy: -0.5))

    if let color {
      drawLabel(color.hex, at: 41, size: 13, color: .white)
      drawLabel(color.rgb, at: 25, size: 12, color: .white)
      drawLabel(copied ?? "C → HEX   ·   ⇧C → RGB", at: 8, size: 11, color: NSColor(white: 0.82, alpha: 1))
    }
  }

  private func drawLabel(_ text: String, at y: CGFloat, size: CGFloat, color: NSColor) {
    let label = NSAttributedString(string: text, attributes: [
      .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium), .foregroundColor: color
    ])
    label.draw(at: NSPoint(x: round((bounds.width - label.size().width) / 2), y: y))
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
