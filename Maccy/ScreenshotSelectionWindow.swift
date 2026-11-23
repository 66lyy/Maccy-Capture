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

  init(
    frame: NSRect, visibleFrame: NSRect, scale: CGFloat, pinImmediately: Bool,
    frozen: CGImage? = nil, pixelSize: CGSize? = nil
  ) {
    allowsLongScreenshot = !pinImmediately
    selectionView = ScreenshotSelectionView(
      frame: NSRect(origin: .zero, size: frame.size), scale: scale, pinImmediately: pinImmediately, pixelSize: pixelSize
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
final class ScrollingScreenshotActivityMonitor {
  private let addLocal: (@escaping (NSEvent) -> NSEvent?) -> Any?
  private let addGlobal: (@escaping (NSEvent) -> Void) -> Any?
  private let remove: (Any) -> Void
  private var tokens: [Any] = []
  var isMonitoring: Bool { !tokens.isEmpty }

  init(
    addLocal: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = {
      NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .leftMouseDragged], handler: $0)
    },
    addGlobal: @escaping (@escaping (NSEvent) -> Void) -> Any? = {
      NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .mouseMoved, .leftMouseDragged], handler: $0)
    },
    remove: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
  ) {
    self.addLocal = addLocal
    self.addGlobal = addGlobal
    self.remove = remove
  }

  func start(_ observe: @escaping (NSEvent) -> Void) {
    stop()
    tokens = [addLocal { event in observe(event); return event }, addGlobal(observe)].compactMap { $0 }
  }

  func stop() {
    tokens.forEach(remove)
    tokens.removeAll()
  }

  isolated deinit { tokens.forEach(remove) }
}

@MainActor
final class ScrollingScreenshotPanel: NSPanel {
  var onFinish: ((Bool) -> Void)?
  var onCancel: (() -> Void)?
  var onScrollActivity: (() -> Void)?
  private let activityMonitor: ScrollingScreenshotActivityMonitor
  private var controls: [NSButton] = []
  private(set) var image: CGImage?
  private let thumbnail = NSImageView()
  private let dimensions = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private let warningIcon = NSImageView()
  private var outputButtons: [NSButton] = []
  var isMonitoringScrollEvents: Bool { activityMonitor.isMonitoring }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  isolated deinit {
    stopMonitoringScrollEvents()
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

  init(beside rectangle: NSRect, bounds: NSRect, level: Int,
       activityMonitor: ScrollingScreenshotActivityMonitor = .init()) {
    self.activityMonitor = activityMonitor
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
    hint.preferredMaxLayoutWidth = 244
    warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
    warningIcon.contentTintColor = .systemOrange
    warningIcon.alphaValue = 0
    warningIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    warningIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
    let hintLine = NSStackView(views: [warningIcon, hint])
    hintLine.spacing = 6
    hintLine.alignment = .centerY
    hintLine.heightAnchor.constraint(equalToConstant: 32).isActive = true
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
    let stack = NSStackView(views: [thumbnail, dimensions, hintLine, actions])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    group.controlsView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: group.controlsView.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: group.controlsView.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: group.controlsView.widthAnchor, constant: -24)
    ])
    let notifications = NotificationCenter.default
    notifications.addObserver(self, selector: #selector(pauseScrollMonitoring(_:)),
                              name: NSApplication.didHideNotification, object: nil)
    notifications.addObserver(self, selector: #selector(resumeScrollMonitoring(_:)),
                              name: NSApplication.didUnhideNotification, object: nil)
  }

  private func startMonitoringScrollEvents() {
    guard isVisible, !isMonitoringScrollEvents else { return }
    activityMonitor.start { [weak self] event in
      if event.type == .scrollWheel { self?.onScrollActivity?() }
      else { self?.updateMousePassthrough(at: NSEvent.mouseLocation) }
    }
    contentView?.layoutSubtreeIfNeeded()
    updateMousePassthrough(at: NSEvent.mouseLocation)
  }

  private func stopMonitoringScrollEvents() {
    activityMonitor.stop()
  }

  @objc private func pauseScrollMonitoring(_ notification: Notification) { stopMonitoringScrollEvents() }
  @objc private func resumeScrollMonitoring(_ notification: Notification) { startMonitoringScrollEvents() }

  nonisolated static func ignoresMouse(at point: NSPoint, controls: [NSRect]) -> Bool {
    !controls.contains { $0.contains(point) }
  }

  func updateMousePassthrough(at point: NSPoint) {
    let frames = controls.map { convertToScreen($0.convert($0.bounds, to: nil)) }
    ignoresMouseEvents = Self.ignoresMouse(at: point, controls: frames)
  }

  override func orderFrontRegardless() {
    super.orderFrontRegardless()
    startMonitoringScrollEvents()
  }

  override func orderFront(_ sender: Any?) {
    super.orderFront(sender)
    startMonitoringScrollEvents()
  }

  override func makeKeyAndOrderFront(_ sender: Any?) {
    super.makeKeyAndOrderFront(sender)
    startMonitoringScrollEvents()
  }

  override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    if place == .out { stopMonitoringScrollEvents() }
    super.order(place, relativeTo: otherWin)
    if place != .out { startMonitoringScrollEvents() }
  }

  override func orderOut(_ sender: Any?) {
    stopMonitoringScrollEvents()
    super.orderOut(sender)
  }

  override func close() {
    stopMonitoringScrollEvents()
    onScrollActivity = nil
    ignoresMouseEvents = false
    super.close()
  }

  func stopMonitoring() { stopMonitoringScrollEvents() }

  func update(_ image: CGImage, width: Int, height: Int, capped: Bool) {
    self.image = image
    thumbnail.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    dimensions.stringValue = "\(width) × \(height) px"
    outputButtons.forEach { $0.isEnabled = true }
    updateHint(capped: capped, showSlowScrollHint: false)
  }

  func updateHint(capped: Bool, showSlowScrollHint: Bool) {
    updateHint(capped: capped, warning: showSlowScrollHint ? .tooFast : .normal)
  }

  func updateHint(capped: Bool, warning: ScrollingScreenshotHintState.Warning) {
    hint.stringValue = text(capped ? "ScreenshotLongLimit"
      : warning == .lostTrack ? "ScreenshotLongLostTrack"
      : warning == .tooFast ? "ScreenshotLongSlowScroll" : "ScreenshotLongHint")
    let warns = !capped && warning != .normal
    hint.textColor = warns ? .systemOrange : .labelColor
    warningIcon.alphaValue = warns ? 1 : 0
    contentView?.wantsLayer = true
    contentView?.layer?.cornerRadius = 16
    contentView?.layer?.borderWidth = warns ? 2 : 0
    contentView?.layer?.borderColor = NSColor.systemOrange.cgColor
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
