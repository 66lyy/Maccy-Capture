import AppKit
import CoreGraphics

@MainActor
final class ScreenshotSelectionController {
  struct Display {
    let frame: NSRect
    let captureFrame: NSRect
    let scale: CGFloat
  }

  struct Selection: Equatable {
    let captureRect: NSRect
    let anchor: NSPoint
    let pinToScreen: Bool
    var annotate = false
  }

  private(set) var windows: [ScreenshotSelectionWindow] = []
  var isSelecting: Bool { continuation != nil }

  private let displays: @MainActor () -> [Display]
  private let presentWindow: @MainActor (ScreenshotSelectionWindow) -> Void
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
          frame: screen.frame, captureFrame: CGDisplayBounds(number.uint32Value), scale: screen.backingScaleFactor
        )
      }
    },
    presentWindow: @escaping @MainActor (ScreenshotSelectionWindow) -> Void = { window in
      window.orderFrontRegardless()
      if window.frame.contains(NSEvent.mouseLocation) {
        window.makeKeyAndOrderFront(nil)
      }
    }
  ) {
    self.displays = displays
    self.presentWindow = presentWindow
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

  private func makeWindow(display: Display, pinImmediately: Bool) -> ScreenshotSelectionWindow {
    let window = ScreenshotSelectionWindow(frame: display.frame, scale: display.scale, pinImmediately: pinImmediately)
    window.onCancel = { [weak self] in self?.cancel() }
    window.selectionView.onBegin = { [weak self, weak window] in
      guard let self, let window else { return }
      for other in windows where other !== window {
        other.selectionView.clearSelection()
      }
    }
    window.selectionView.onCapture = { [weak self] rectangle, pinToScreen in
      self?.finish(Selection(
        captureRect: Self.captureRectangle(rectangle, display: display),
        anchor: NSPoint(x: display.frame.minX + rectangle.midX, y: display.frame.minY + rectangle.midY),
        pinToScreen: pinToScreen
      ))
    }
    window.selectionView.onAnnotate = { [weak self] rectangle in
      self?.finish(Selection(
        captureRect: Self.captureRectangle(rectangle, display: display),
        anchor: NSPoint(x: display.frame.minX + rectangle.midX, y: display.frame.minY + rectangle.midY),
        pinToScreen: false, annotate: true
      ))
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
      window.selectionView.onBegin = nil
      window.selectionView.onCapture = nil
      window.selectionView.onAnnotate = nil
      window.orderOut(nil)
      window.close()
    }
    windows.removeAll()
    continuation.resume(returning: selection)
  }
}

@MainActor
final class ScreenshotSelectionWindow: NSPanel, NSWindowDelegate {
  var onCancel: (() -> Void)?
  let selectionView: ScreenshotSelectionView

  init(frame: NSRect, scale: CGFloat, pinImmediately: Bool) {
    selectionView = ScreenshotSelectionView(
      frame: NSRect(origin: .zero, size: frame.size), scale: scale, pinImmediately: pinImmediately
    )
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    delegate = self
    isReleasedWhenClosed = false
    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    acceptsMouseMovedEvents = true
    becomesKeyOnlyIfNeeded = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    contentView = selectionView
    initialFirstResponder = selectionView
    selectionView.onCancel = { [weak self] in self?.onCancel?() }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  override func cancelOperation(_ sender: Any?) {
    onCancel?()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onCancel?()
    } else {
      selectionView.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
       event.charactersIgnoringModifiers?.lowercased() == "w" {
      onCancel?()
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  func windowWillClose(_ notification: Notification) {
    let handler = onCancel
    onCancel = nil
    handler?()
  }
}

@MainActor
final class ScreenshotSelectionView: NSView {
  var onBegin: (() -> Void)?
  var onCapture: ((NSRect, Bool) -> Void)?
  var onAnnotate: ((NSRect) -> Void)?
  var onCancel: (() -> Void)?
  private(set) var selectedRect: NSRect?
  private(set) var actionBar = NSView()

  private let scale: CGFloat
  private let pinImmediately: Bool
  private var anchor: NSPoint?

  init(frame: NSRect, scale: CGFloat, pinImmediately: Bool) {
    self.scale = scale
    self.pinImmediately = pinImmediately
    super.init(frame: frame)
    configureActionBar()
    setAccessibilityLabel(localized("ScreenshotSelectionHint"))
  }

  required init?(coder: NSCoder) { nil }
  override var acceptsFirstResponder: Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
  override var isOpaque: Bool { false }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeKey()
    window?.makeFirstResponder(self)
    beginSelection(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseDragged(with event: NSEvent) {
    updateSelection(to: convert(event.locationInWindow, from: nil))
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
    switch event.keyCode {
    case 53:
      onCancel?()
    case 36, 76:
      captureSelection(pinToScreen: pinImmediately)
    default:
      if event.charactersIgnoringModifiers?.lowercased() == "p" {
        captureSelection(pinToScreen: true)
      } else if event.charactersIgnoringModifiers?.lowercased() == "e" {
        annotateSelection()
      }
    }
  }

  func beginSelection(at point: NSPoint) {
    onBegin?()
    anchor = point
    selectedRect = nil
    actionBar.isHidden = true
    needsDisplay = true
  }

  func updateSelection(to point: NSPoint) {
    guard let anchor else { return }
    selectedRect = Self.rectangle(from: anchor, to: point, bounds: bounds)
    needsDisplay = true
  }

  func endSelection(at point: NSPoint) {
    updateSelection(to: point)
    anchor = nil
    guard let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3 else {
      clearSelection()
      return
    }
    if pinImmediately {
      captureSelection(pinToScreen: true)
    } else {
      positionActionBar(beside: selectedRect)
      actionBar.isHidden = false
    }
  }

  func clearSelection() {
    anchor = nil
    selectedRect = nil
    actionBar.isHidden = true
    needsDisplay = true
  }

  func captureSelection(pinToScreen: Bool) {
    guard let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3 else { return }
    onCapture?(selectedRect, pinToScreen)
  }

  @objc func annotateSelection() {
    guard let selectedRect, selectedRect.width >= 3, selectedRect.height >= 3 else { return }
    onAnnotate?(selectedRect)
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
    if let selectedRect {
      shade.appendRect(selectedRect)
    }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.12).setFill()
    shade.fill()
    if let selectedRect {
      NSColor.controlAccentColor.setStroke()
      let border = NSBezierPath(rect: selectedRect.insetBy(dx: 1, dy: 1))
      border.lineWidth = 2
      border.stroke()
      let dimensions = "\(Int(selectedRect.width * scale)) × \(Int(selectedRect.height * scale)) px"
      drawPill(dimensions, near: NSPoint(x: selectedRect.minX, y: selectedRect.maxY + 8))
    } else {
      let key = pinImmediately ? "ScreenshotSelectionPinInstructions" : "ScreenshotSelectionInstructions"
      drawPill(localized(key), near: NSPoint(x: bounds.midX - 190, y: bounds.maxY - 64))
    }
  }

  private func configureActionBar() {
    actionBar.wantsLayer = true
    actionBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    actionBar.layer?.cornerRadius = 8
    actionBar.isHidden = true
    let buttons = [
      actionButton("ScreenshotCancel", symbol: "xmark", action: #selector(cancelSelection)),
      actionButton("ScreenshotCopy", symbol: "doc.on.doc", action: #selector(copySelection)),
      actionButton("ScreenshotPinImage", symbol: "pin.fill", action: #selector(pinSelection)),
      actionButton("AnnotationEdit", symbol: "pencil.tip", action: #selector(annotateSelection))
    ]
    var offset: CGFloat = 8
    for button in buttons {
      button.frame = NSRect(x: offset, y: 7, width: max(60, button.fittingSize.width), height: 28)
      actionBar.addSubview(button)
      offset = button.frame.maxX + 8
    }
    actionBar.frame.size = NSSize(width: offset, height: 42)
    addSubview(actionBar)
  }

  private func actionButton(_ key: String, symbol: String, action: Selector) -> NSButton {
    let button = NSButton(title: localized(key), target: self, action: action)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    button.imagePosition = .imageLeading
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(localized(key))
    return button
  }

  private func positionActionBar(beside rectangle: NSRect) {
    let size = actionBar.frame.size
    let below = rectangle.minY - size.height - 8
    actionBar.frame = NSRect(
      x: max(8, min(rectangle.maxX - size.width, bounds.maxX - size.width - 8)),
      y: max(8, min(below >= 8 ? below : rectangle.maxY + 8, bounds.maxY - size.height - 8)),
      width: size.width, height: size.height
    )
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

  @objc private func cancelSelection() { onCancel?() }
  @objc private func copySelection() { captureSelection(pinToScreen: false) }
  @objc private func pinSelection() { captureSelection(pinToScreen: true) }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}
