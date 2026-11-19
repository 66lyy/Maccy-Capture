import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class ScreenshotSelectionController {
  struct Display: Sendable {
    let frame: NSRect
    let captureFrame: NSRect
    let scale: CGFloat
    var displayID: CGDirectDisplayID = 0
    var visibleFrame: NSRect?
  }

  struct Selection: Equatable {
    let captureRect: NSRect
    let anchor: NSPoint
    let pinToScreen: Bool
    var renderedData: Data?

    var screenRect: NSRect {
      NSRect(
        x: anchor.x - captureRect.width / 2, y: anchor.y - captureRect.height / 2,
        width: captureRect.width, height: captureRect.height
      )
    }
  }

  private(set) var windows: [ScreenshotSelectionWindow] = []
  var isSelecting: Bool { continuation != nil }

  private let displays: @MainActor () -> [Display]
  private let presentWindow: @MainActor (ScreenshotSelectionWindow) -> Void
  private let captureRegion: @MainActor (Display, NSRect, Set<CGWindowID>) async throws -> NSImage
  private var continuation: CheckedContinuation<Selection?, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?

  init(
    displays: @escaping @MainActor () -> [Display] = {
      NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
          return nil
        }
        return Display(
          frame: screen.frame, captureFrame: CGDisplayBounds(number.uint32Value), scale: screen.backingScaleFactor,
          displayID: number.uint32Value, visibleFrame: screen.visibleFrame
        )
      }
    },
    presentWindow: @escaping @MainActor (ScreenshotSelectionWindow) -> Void = { window in
      window.orderFrontRegardless()
      if window.frame.contains(NSEvent.mouseLocation) {
        window.makeKeyAndOrderFront(nil)
      }
    },
    captureRegion: @escaping @MainActor (Display, NSRect, Set<CGWindowID>) async throws -> NSImage = {
      try await ScreenshotCaptureSession.captureSelection(on: $0, rectangle: $1, excluding: $2)
    }
  ) {
    self.displays = displays
    self.presentWindow = presentWindow
    self.captureRegion = captureRegion
  }

  func select(pinImmediately: Bool, timeout: Duration = .seconds(120)) async throws -> Selection? {
    guard !isSelecting else { throw ScreenshotCaptureSession.Failure.alreadyCapturing }
    try Task.checkCancellation()
    let availableDisplays = displays()
    guard !availableDisplays.isEmpty else { throw ScreenshotCaptureSession.Failure.captureFailed }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        windows = availableDisplays.map { display in
          makeWindow(display: display, pinImmediately: pinImmediately)
        }
        screenObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.cancel() }
        }
        timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
            self?.cancel()
          } catch {
            return
          }
        }
        windows.forEach(presentWindow)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel() }
    }
  }

  func cancel() {
    finish(nil)
  }

  static func captureRectangle(_ localRect: NSRect, display: Display) -> NSRect {
    NSRect(
      x: display.captureFrame.minX + localRect.minX,
      y: display.captureFrame.minY + display.frame.height - localRect.maxY,
      width: localRect.width,
      height: localRect.height
    ).integral
  }

  nonisolated static func screenRectangle(_ captureRect: NSRect, display: Display) -> NSRect {
    NSRect(
      x: display.frame.minX + captureRect.minX - display.captureFrame.minX,
      y: display.frame.maxY - (captureRect.maxY - display.captureFrame.minY),
      width: captureRect.width, height: captureRect.height
    )
  }

  private func makeWindow(display: Display, pinImmediately: Bool) -> ScreenshotSelectionWindow {
    let window = ScreenshotSelectionWindow(
      frame: display.frame, visibleFrame: display.visibleFrame ?? display.frame,
      scale: display.scale, pinImmediately: pinImmediately
    )
    window.onCancel = { [weak self] in self?.cancel() }
    window.selectionView.movePointer = { point in
      CGWarpMouseCursorPosition(CGPoint(
        x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y
      ))
    }
    window.selectionView.findElements = { point in
      let global = NSPoint(x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y)
      return ScreenshotElementDetection.rectangles(at: global).map {
        Self.screenRectangle($0, display: display).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
      }
    }
    window.selectionView.onBegin = { [weak self, weak window] in
      guard let self, let window else { return }
      for other in windows where other !== window {
        other.selectionView.clearSelection()
      }
    }
    window.selectionView.canAdjustSelection = { [weak self] in
      self?.windows.allSatisfy { $0.canvas == nil && !$0.isPreparingImage } ?? false
    }
    func selection(_ rectangle: NSRect, pinToScreen: Bool, data: Data? = nil) -> Selection {
      let captureRect = Self.captureRectangle(rectangle, display: display)
      let screenRect = Self.screenRectangle(captureRect, display: display)
      return Selection(
        captureRect: captureRect,
        anchor: NSPoint(x: screenRect.midX, y: screenRect.midY),
        pinToScreen: pinToScreen, renderedData: data
      )
    }
    window.selectionView.onCapture = { [weak self] rectangle, pinToScreen in
      self?.finish(selection(rectangle, pinToScreen: pinToScreen))
    }
    window.loadSelectionImage = { [weak self, weak window] in
      guard let self, let window, let rectangle = window.selectionView.selectedRect else { throw CancellationError() }
      let captureRect = Self.captureRectangle(rectangle, display: display)
      let globalFrame = Self.screenRectangle(captureRect, display: display)
      let overlayIDs = Set(windows.filter {
        $0.isVisible && $0.frame.intersects(window.frame)
      }.compactMap { CGWindowID(exactly: $0.windowNumber) })
      let image = try await captureRegion(display, captureRect, overlayIDs)
      return (image, globalFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
    }
    window.onCanvasReady = { [weak self, weak window] in
      guard let self, let window else { return }
      timeoutTask?.cancel()
      timeoutTask = nil
      for other in windows where other !== window { other.orderOut(nil) }
      window.invalidateCursorRects(for: window.selectionView)
    }
    window.onOutput = { [weak self, weak window] data, _, action in
      guard let self, let rectangle = window?.selectionView.selectedRect else { throw CancellationError() }
      finish(selection(rectangle, pinToScreen: action == .pin, data: data))
    }
    return window
  }

  private func finish(_ selection: Selection?) {
    guard let continuation else { return }
    self.continuation = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
    for window in windows {
      window.onCancel = nil
      window.selectionView.finishInteraction()
      window.orderOut(nil)
      window.close()
    }
    windows.removeAll()
    continuation.resume(returning: selection)
  }
}

@MainActor
final class ScreenshotSelectionWindow: ScreenshotAnnotationWindow {
  var onCancel: (() -> Void)?
  let selectionView: ScreenshotSelectionView

  init(frame: NSRect, visibleFrame: NSRect, scale: CGFloat, pinImmediately: Bool) {
    selectionView = ScreenshotSelectionView(
      frame: NSRect(origin: .zero, size: frame.size), scale: scale, pinImmediately: pinImmediately
    )
    super.init(display: frame, visibleFrame: visibleFrame)
    contentView = selectionView
    initialFirstResponder = selectionView
    selectionView.onCancel = { [weak self] in self?.cancelOperation(nil) }
    selectionView.onValidSelection = { [weak self] rectangle in self?.showToolbar(beside: rectangle) }
    selectionView.onChooseDrawingTool = { [weak self] in self?.chooseTool(.arrow) }
  }

  override func complete(_ action: OutputAction) {
    if canvas != nil {
      super.complete(action)
    } else if !isPreparingImage {
      selectionView.captureSelection(pinToScreen: action == .pin)
    }
  }

  override func keyDown(with event: NSEvent) {
    if canvas != nil || isPreparingImage {
      super.keyDown(with: event)
    } else if event.keyCode == 53 {
      onCancel?()
    } else {
      selectionView.keyDown(with: event)
    }
  }

  override func windowWillClose(_ notification: Notification) {
    let handler = onCancel
    onCancel = nil
    super.windowWillClose(notification)
    handler?()
  }
}

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

  private enum Drag {
    case new(NSPoint)
    case move(NSPoint, NSRect)
    case resize(NSPoint)
  }

  private let scale: CGFloat
  private let pinImmediately: Bool
  private var drag: Drag?
  private var pointer: NSPoint?
  private var snapRects: [NSRect] = []
  private var snapIndex = 0
  private var lastProbe: NSPoint?
  private var probing = false
  private var wantsSnapping = false
  private var elementTask: Task<Void, Never>?

  init(frame: NSRect, scale: CGFloat, pinImmediately: Bool) {
    self.scale = scale
    self.pinImmediately = pinImmediately
    super.init(frame: frame)
    setAccessibilityLabel(localized("ScreenshotSelectionHint"))
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
    updateProbe(enabled: event.modifierFlags.contains(.option))
  }

  override func mouseExited(with event: NSEvent) {
    pointer = nil
    updateProbe(enabled: false)
  }

  override func flagsChanged(with event: NSEvent) {
    pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    updateProbe(enabled: event.modifierFlags.contains(.option))
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
    updateProbe(enabled: false)
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
    switch event.keyCode {
    case 53:
      onCancel?()
    case 36, 76:
      if selectedRect == nil, let pointer, let snap = snapRectangle(near: pointer) {
        onBegin?()
        selectedRect = snap
        updateProbe(enabled: false)
        if pinImmediately { captureSelection(pinToScreen: true) }
        updateControls()
      } else {
        captureSelection(pinToScreen: pinImmediately)
      }
    case 48 where wantsSnapping:
      cycleSnap(towardParent: !modifiers.contains(.shift))
    case 123...126:
      let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
      let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
      let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
      nudge(dx: dx, dy: dy)
    default:
      if event.charactersIgnoringModifiers?.lowercased() == "p" {
        captureSelection(pinToScreen: true)
      } else if event.charactersIgnoringModifiers?.lowercased() == "e" {
        annotateSelection()
      }
    }
  }

  func beginSelection(at point: NSPoint) {
    guard canAdjustSelection?() != false else { return }
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
    guard drag != nil else { return }
    updateSelection(to: point)
    drag = nil
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
    needsDisplay = true
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
      needsDisplay = true
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
      needsDisplay = true
      if wantsSnapping { updateProbe(enabled: true) }
    }
  }

  private func cycleSnap(towardParent: Bool) {
    guard !snapRects.isEmpty else { return }
    snapIndex = max(0, min(snapRects.count - 1, snapIndex + (towardParent ? 1 : -1)))
    needsDisplay = true
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

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    let shade = NSBezierPath(rect: bounds)
    let activeRect = selectedRect ?? pointer.flatMap { snapRectangle(near: $0) }
    if let activeRect {
      shade.appendRect(activeRect)
    }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.12).setFill()
    shade.fill()
    if let activeRect {
      NSColor.systemCyan.setStroke()
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
      let dimensions = "\(Int(activeRect.width * scale)) × \(Int(activeRect.height * scale)) px"
      drawPill(dimensions, near: NSPoint(x: activeRect.minX, y: activeRect.maxY + 8))
    } else {
      let key = pinImmediately ? "ScreenshotSelectionPinInstructions" : "ScreenshotSelectionInstructions"
      drawPill(localized(key), near: NSPoint(x: bounds.midX - 190, y: bounds.maxY - 64))
    }
    if wantsSnapping {
      let key = AXIsProcessTrusted() ? "ScreenshotElementHint" : "ScreenshotElementPermissionHint"
      drawPill(localized(key), near: NSPoint(x: 12, y: 12))
    }
  }

  private func drawPill(_ text: String, near point: NSPoint) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    let rectangle = NSRect(
      x: max(8, min(point.x, bounds.maxX - size.width - 24)),
      y: max(8, min(point.y, bounds.maxY - size.height - 20)),
      width: size.width + 16, height: size.height + 12
    )
    NSColor.black.withAlphaComponent(0.8).setFill()
    NSBezierPath(roundedRect: rectangle, xRadius: 6, yRadius: 6).fill()
    (text as NSString).draw(at: NSPoint(x: rectangle.minX + 8, y: rectangle.minY + 6), withAttributes: attributes)
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}

enum ScreenshotElementDetection {
  nonisolated static func rectangles(at point: NSPoint) -> [NSRect] {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    for window in windows {
      guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
            window[kCGWindowLayer as String] as? Int == 0,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let rectangle = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { continue }
      guard rectangle.contains(point) else { continue }
      guard AXIsProcessTrusted() else { return [rectangle] }
      let application = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application, 0.06)
      var hit: AXUIElement?
      guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success
      else { return [rectangle] }
      var rectangles: [NSRect] = []
      for _ in 0..<6 {
        guard let element = hit else { break }
        AXUIElementSetMessagingTimeout(element, 0.04)
        if let position: CGPoint = value(kAXPositionAttribute, element: element, type: .cgPoint, zero: .zero),
           let size: CGSize = value(kAXSizeAttribute, element: element, type: .cgSize, zero: .zero) {
          let frame = NSRect(origin: position, size: size).intersection(rectangle)
          if frame.contains(point) { rectangles.append(frame) }
        }
        var parent: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
              let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(parent, element) else { break }
        hit = (parent as! AXUIElement)
      }
      return rectangles + [rectangle]
    }
    return []
  }

  nonisolated private static func value<Value>(
    _ attribute: String, element: AXUIElement, type: AXValueType, zero: Value
  ) -> Value? {
    var raw: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
          let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
    let value = raw as! AXValue
    guard AXValueGetType(value) == type else { return nil }
    var result = zero
    return withUnsafeMutablePointer(to: &result) { pointer in
      AXValueGetValue(value, type, pointer)
    } ? result : nil
  }
}
