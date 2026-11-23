import AppKit
import CoreGraphics

@MainActor
final class ScreenshotSelectionWindow: ScreenshotAnnotationWindow {
  var onCancel: (() -> Void)?
  let selectionView: ScreenshotSelectionView
  let allowsLongScreenshot: Bool
  var onLongScreenshot: (() -> Void)?
  var longScreenshotButton: NSButton?
  var scrollingPanel: ScrollingScreenshotPanel?

  @objc func beginLongScreenshot() {
    guard allowsLongScreenshot, canvas == nil, !isPreparingImage, selectionView.selectedRect != nil else { return }
    onLongScreenshot?()
  }

  init(frame: NSRect, visibleFrame: NSRect, scale: CGFloat, pinImmediately: Bool, frozen: CGImage? = nil) {
    allowsLongScreenshot = !pinImmediately
    selectionView = ScreenshotSelectionView(
      frame: NSRect(origin: .zero, size: frame.size), scale: scale, pinImmediately: pinImmediately
    )
    selectionView.setFrozenImage(frozen)
    super.init(display: frame, visibleFrame: visibleFrame, deferToolbar: true)
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
    collectionBehavior.insert(.canJoinAllApplications)
    ignoresMouseEvents = false
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
      cancelOperation(nil)
    } else {
      selectionView.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if canvas == nil, !isPreparingImage, selectionView.handleSelectionShortcut(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  override func windowWillClose(_ notification: Notification) {
    scrollingPanel?.orderOut(nil)
    scrollingPanel?.close()
    scrollingPanel = nil
    onLongScreenshot = nil
    let handler = onCancel
    onCancel = nil
    super.windowWillClose(notification)
    handler?()
  }
}

@MainActor
final class ScrollingScreenshotPanel: NSPanel {
  var onFinish: ((Bool) -> Void)?
  var onCancel: (() -> Void)?
  var onScrollActivity: (() -> Void)?
  private var localScrollMonitor: Any?
  private var globalScrollMonitor: Any?
  private var controls: [NSButton] = []
  private(set) var image: CGImage?
  private let thumbnail = NSImageView()
  private let dimensions = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private var outputButtons: [NSButton] = []

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  isolated deinit {
    if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
    if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
  }

  nonisolated static func placement(beside rectangle: NSRect, bounds: NSRect, size: NSSize) -> NSRect {
    guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
      return NSRect(origin: bounds.origin, size: .zero)
    }
    let size = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
    let x = min(max(rectangle.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
    let y = min(max(rectangle.midY - size.height / 2, bounds.minY), bounds.maxY - size.height)
    let below = rectangle.minY - bounds.minY - size.height
    let above = bounds.maxY - rectangle.maxY - size.height
    let right = bounds.maxX - rectangle.maxX - size.width
    let left = rectangle.minX - bounds.minX - size.width
    let candidates = [
      NSPoint(x: x, y: rectangle.minY - size.height - min(8, max(0, below))),
      NSPoint(x: x, y: rectangle.maxY + min(8, max(0, above))),
      NSPoint(x: rectangle.maxX + min(8, max(0, right)), y: y),
      NSPoint(x: rectangle.minX - size.width - min(8, max(0, left)), y: y)
    ]
    for origin in candidates {
      let frame = NSRect(origin: origin, size: size)
      if bounds.contains(frame), !frame.intersects(rectangle) { return frame }
    }
    return NSRect(x: min(max(rectangle.maxX - size.width, bounds.minX), bounds.maxX - size.width),
      y: min(max(rectangle.minY - size.height - 8, bounds.minY), bounds.maxY - size.height),
      width: size.width, height: size.height)
  }

  init(beside rectangle: NSRect, bounds: NSRect, level: Int) {
    let frame = Self.placement(
      beside: rectangle, bounds: bounds, size: NSSize(width: 330, height: 240)
    )
    super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    self.level = NSWindow.Level(rawValue: level)
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
    isReleasedWhenClosed = false
    hidesOnDeactivate = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    let surface = GlassSurfaceView(frame: NSRect(origin: .zero, size: frame.size), cornerRadius: 16)
    let group = GlassContainerView(frame: surface.bounds)
    group.autoresizingMask = [.width, .height]
    surface.controlsView.addSubview(group)
    contentView = surface
    thumbnail.imageScaling = .scaleProportionallyUpOrDown
    thumbnail.heightAnchor.constraint(equalToConstant: 120).isActive = true
    thumbnail.widthAnchor.constraint(equalToConstant: 264).isActive = true
    dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    hint.stringValue = text("ScreenshotLongHint")
    hint.font = .systemFont(ofSize: 12)
    hint.preferredMaxLayoutWidth = 264
    let copy = NSButton(title: text("AnnotationCopy"), target: self, action: #selector(copyResult))
    let pin = NSButton(title: text("ScreenshotPinImage"), target: self, action: #selector(pinResult))
    let cancel = NSButton(title: text("ScreenshotCancel"), target: self, action: #selector(cancelResult))
    outputButtons = [copy, pin]
    controls = [copy, pin, cancel]
    for button in controls {
      button.bezelStyle = .rounded
      _ = button.applyGlassBezel()
    }
    outputButtons.forEach { $0.isEnabled = false }
    let actions = NSStackView(views: [copy, pin, cancel])
    actions.spacing = 8
    let stack = NSStackView(views: [thumbnail, dimensions, hint, actions])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    group.controlsView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: group.controlsView.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: group.controlsView.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: group.controlsView.widthAnchor, constant: -24)
    ])
    let events: NSEvent.EventTypeMask = [.scrollWheel, .mouseMoved, .leftMouseDragged]
    localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
      if event.type == .scrollWheel { self?.onScrollActivity?() }
      else { self?.updateMousePassthrough(at: NSEvent.mouseLocation) }
      return event
    }
    globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
      if event.type == .scrollWheel { self?.onScrollActivity?() }
      else { self?.updateMousePassthrough(at: NSEvent.mouseLocation) }
    }
    surface.layoutSubtreeIfNeeded()
    updateMousePassthrough(at: NSEvent.mouseLocation)
  }

  nonisolated static func ignoresMouse(at point: NSPoint, controls: [NSRect]) -> Bool {
    !controls.contains { $0.contains(point) }
  }

  func updateMousePassthrough(at point: NSPoint) {
    let frames = controls.map { convertToScreen($0.convert($0.bounds, to: nil)) }
    ignoresMouseEvents = Self.ignoresMouse(at: point, controls: frames)
  }

  override func close() {
    if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
    if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
    localScrollMonitor = nil
    globalScrollMonitor = nil
    onScrollActivity = nil
    ignoresMouseEvents = false
    super.close()
  }

  func update(_ image: CGImage, width: Int, height: Int, capped: Bool) {
    self.image = image
    thumbnail.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    dimensions.stringValue = "\(width) × \(height) px"
    outputButtons.forEach { $0.isEnabled = true }
    updateHint(capped: capped, showSlowScrollHint: false)
  }

  func updateHint(capped: Bool, showSlowScrollHint: Bool) {
    hint.stringValue = text(capped ? "ScreenshotLongLimit"
      : showSlowScrollHint ? "ScreenshotLongSlowScroll" : "ScreenshotLongHint")
  }

  override func keyDown(with event: NSEvent) {
    if !handleKey(event) { super.keyDown(with: event) }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    handleKey(event) || super.performKeyEquivalent(with: event)
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    let key = event.charactersIgnoringModifiers?.lowercased()
    if (event.keyCode == 53 && modifiers.isEmpty) || (key == "w" && modifiers == .command) {
      cancelResult()
    } else if ((event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty)
                || (key == "c" && modifiers == .command) {
      if image != nil { copyResult() }
    } else if key == "p" && modifiers.isEmpty {
      if image != nil { pinResult() }
    } else { return false }
    return true
  }

  @objc private func copyResult() { onFinish?(false) }
  @objc private func pinResult() { onFinish?(true) }
  @objc private func cancelResult() { onCancel?() }

  private func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}
