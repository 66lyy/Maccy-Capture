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
    animationBehavior = .none
    level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
    collectionBehavior.insert(.canJoinAllApplications)
    ignoresMouseEvents = false
    contentView = selectionView
    initialFirstResponder = selectionView
    selectionView.onCancel = { [weak self] in self?.cancelOperation(nil) }
    selectionView.onValidSelection = { [weak self] rectangle in
      guard let self else { return }
      showToolbar(beside: rectangle)
      longScreenshotButton?.isHidden = selectionView.selectedWindows.count > 1
    }
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
    if canvas == nil, !isPreparingImage, selectionView.isPickingColor, selectionView.handleColorShortcut(event) {
      return true
    }
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
  private static let mask: NSEvent.EventTypeMask = [.scrollWheel, .mouseMoved, .leftMouseDragged,
    .leftMouseDown, .rightMouseDown, .otherMouseDown]
  private let addLocal: (@escaping (NSEvent) -> NSEvent?) -> Any?
  private let addGlobal: (@escaping (NSEvent) -> Void) -> Any?
  private let remove: (Any) -> Void
  private var tokens: [Any] = []
  private(set) var monitorsLocalClicks = false
  var isMonitoring: Bool { !tokens.isEmpty }

  init(
    addLocal: @escaping (@escaping (NSEvent) -> NSEvent?) -> Any? = {
      NSEvent.addLocalMonitorForEvents(matching: ScrollingScreenshotActivityMonitor.mask, handler: $0)
    },
    addGlobal: @escaping (@escaping (NSEvent) -> Void) -> Any? = {
      AppDelegate.isTesting ? nil : NSEvent.addGlobalMonitorForEvents(matching: ScrollingScreenshotActivityMonitor.mask, handler: $0)
    },
    remove: @escaping (Any) -> Void = { NSEvent.removeMonitor($0) }
  ) {
    self.addLocal = addLocal
    self.addGlobal = addGlobal
    self.remove = remove
  }

  func start(stopOnClick: @escaping () -> Bool = { false }, _ observe: @escaping (NSEvent) -> Void) {
    stop()
    func handle(_ event: NSEvent) -> NSEvent? {
      switch event.type {
      case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        if stopOnClick() { return nil }
      default: observe(event)
      }
      return event
    }
    let local = addLocal(handle)
    monitorsLocalClicks = local != nil
    tokens = [local, addGlobal { _ = handle($0) }].compactMap { $0 }
  }

  func stop() {
    tokens.forEach(remove)
    tokens.removeAll()
    monitorsLocalClicks = false
  }

  isolated deinit { tokens.forEach(remove) }
}

@MainActor
final class ScrollingScreenshotPanel: NSPanel {
  var onFinish: ((Bool) -> Void)?
  var onEdit: (() -> Void)?
  var onCancel: (() -> Void)?
  var onScrollActivity: (() -> Void)?
  var onAutoScroll: ((ScrollingScreenshotAutoScroll.Direction) -> Void)?
  var onStopAutoScroll: (() -> Void)?
  private(set) var isAutoScrolling = false
  private var autoHint: String?
  private var autoButtons: [NSButton] = []
  private let autoLine = NSStackView()
  private let activityMonitor: ScrollingScreenshotActivityMonitor
  private var controls: [NSButton] = []
  private(set) var image: CGImage?
  private let thumbnail = NSImageView()
  private let editorScroll = NSScrollView()
  private let editor = ScrollingScreenshotEditView()
  private let preview = NSView()
  private var previewHeight: NSLayoutConstraint?
  private var editButton: NSButton?
  private var undoButton: NSButton?
  private var editing = false
  var edit: ScrollingScreenshotEdit? { editor.edit }
  private let dimensions = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private let warningIcon = NSImageView()
  private var outputButtons: [NSButton] = []
  var isMonitoringScrollEvents: Bool { activityMonitor.isMonitoring }
  var canBeginAutoScroll: Bool {
    !editing && !isAutoScrolling && activityMonitor.monitorsLocalClicks && autoButtons.first?.isEnabled == true
  }

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
      beside: rectangle, bounds: bounds, size: NSSize(width: 330, height: 276)
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
    previewHeight = preview.heightAnchor.constraint(equalToConstant: 120)
    previewHeight?.isActive = true
    preview.widthAnchor.constraint(equalToConstant: 264).isActive = true
    for view in [thumbnail, editorScroll] {
      view.frame = preview.bounds
      view.autoresizingMask = [.width, .height]
      preview.addSubview(view)
    }
    editorScroll.hasVerticalScroller = true
    editorScroll.drawsBackground = false
    editorScroll.documentView = editor
    editorScroll.isHidden = true
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
    let edit = NSButton(title: text("ScreenshotLongFinishScrolling"), target: self, action: #selector(beginEditing))
    let undo = NSButton(title: text("AnnotationUndo"), target: self, action: #selector(undoEdit))
    editButton = edit
    undoButton = undo
    autoButtons = [NSButton(title: text("ScreenshotLongAutoUp"), target: self, action: #selector(autoUp)),
      NSButton(title: text("ScreenshotLongAutoDown"), target: self, action: #selector(autoDown))]
    autoButtons.forEach { $0.isEnabled = false; autoLine.addArrangedSubview($0) }
    controls = [copy, pin, cancel, edit] + autoButtons
    for button in controls {
      button.bezelStyle = .rounded
      _ = button.applyGlassBezel()
    }
    outputButtons.forEach { $0.isEnabled = false }
    edit.isEnabled = false
    undo.isHidden = true
    undo.bezelStyle = .rounded
    _ = undo.applyGlassBezel()
    let actions = NSStackView(views: [copy, pin, cancel])
    actions.spacing = 8
    let editLine = NSStackView(views: [dimensions, edit, undo])
    editLine.spacing = 8
    let stack = NSStackView(views: [preview, editLine, autoLine, hintLine, actions])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    group.controlsView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: group.controlsView.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: group.controlsView.centerYAnchor),
      stack.widthAnchor.constraint(lessThanOrEqualTo: group.controlsView.widthAnchor, constant: -24)
    ])
    editor.onChange = { [weak self] in
      guard let self, let edit = self.editor.edit else { return }
      dimensions.stringValue = "\(edit.width) × \(edit.rows.count) px"
      undoButton?.isEnabled = self.editor.canUndo
    }
    let notifications = NotificationCenter.default
    notifications.addObserver(self, selector: #selector(pauseScrollMonitoring(_:)),
                              name: NSApplication.didHideNotification, object: nil)
    notifications.addObserver(self, selector: #selector(resumeScrollMonitoring(_:)),
                              name: NSApplication.didUnhideNotification, object: nil)
  }

  private func startMonitoringScrollEvents() {
    guard isVisible, !editing, !isMonitoringScrollEvents else { return }
    activityMonitor.start(stopOnClick: { [weak self] in
      guard let self, isAutoScrolling else { return false }
      onStopAutoScroll?()
      return true
    }) { [weak self] event in
      if event.type == .scrollWheel { self?.onScrollActivity?() }
      else { self?.updateMousePassthrough(at: NSEvent.mouseLocation) }
    }
    contentView?.layoutSubtreeIfNeeded()
    updateMousePassthrough(at: NSEvent.mouseLocation)
  }

  private func stopMonitoringScrollEvents() {
    if isAutoScrolling { onStopAutoScroll?() }
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
    onAutoScroll = nil
    onStopAutoScroll = nil
    onEdit = nil
    ignoresMouseEvents = false
    super.close()
  }

  func stopMonitoring() { stopMonitoringScrollEvents() }

  @objc private func autoUp() { onAutoScroll?(.up) }
  @objc private func autoDown() { onAutoScroll?(.down) }

  func setAutoScrolling(_ active: Bool, hintKey: String) {
    isAutoScrolling = active
    autoHint = hintKey
    updateHint(capped: false, warning: .normal)
  }

  func update(_ image: CGImage, width: Int, height: Int, capped: Bool) {
    self.image = image
    thumbnail.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    dimensions.stringValue = "\(width) × \(height) px"
    outputButtons.forEach { $0.isEnabled = true }
    editButton?.isEnabled = true
    autoButtons.forEach { $0.isEnabled = !capped }
    updateHint(capped: capped, showSlowScrollHint: false)
  }

  func updateHint(capped: Bool, showSlowScrollHint: Bool) {
    updateHint(capped: capped, warning: showSlowScrollHint ? .tooFast : .normal)
  }

  func updateHint(capped: Bool, warning: ScrollingScreenshotHintState.Warning) {
    guard !editing else { return }
    hint.stringValue = text(capped ? "ScreenshotLongLimit"
      : warning == .lostTrack ? "ScreenshotLongLostTrack"
      : warning == .tooFast && !isAutoScrolling ? "ScreenshotLongSlowScroll" : autoHint ?? "ScreenshotLongHint")
    let warns = !capped && warning != .normal
    hint.textColor = warns ? .systemOrange : .labelColor
    warningIcon.alphaValue = warns ? 1 : 0
    contentView?.wantsLayer = true
    contentView?.layer?.cornerRadius = 16
    contentView?.layer?.borderWidth = warns ? 2 : 0
    contentView?.layer?.borderColor = NSColor.systemOrange.cgColor
  }

  @objc private func beginEditing() {
    guard !editing, image != nil, let onEdit else { return }
    updateHint(capped: false, warning: .normal)
    editing = true
    stopMonitoringScrollEvents()
    autoLine.isHidden = true
    ignoresMouseEvents = false
    editButton?.isEnabled = false
    outputButtons.forEach { $0.isEnabled = false }
    onEdit()
  }

  func showEditor(_ image: CGImage, width: Int, height: Int, frame: NSRect) {
    let instructions = text("ScreenshotLongEditHint")
    hint.stringValue = instructions
    previewHeight?.constant += frame.height - self.frame.height
    setFrame(frame, display: true)
    thumbnail.isHidden = true
    editorScroll.isHidden = false
    editButton?.isHidden = true
    undoButton?.isHidden = false
    contentView?.layoutSubtreeIfNeeded()
    editor.setAccessibilityLabel(instructions)
    editor.load(image, width: width, height: height, viewport: editorScroll.contentSize)
    editorScroll.contentView.scroll(to: .zero)
    editorScroll.reflectScrolledClipView(editorScroll.contentView)
    outputButtons.forEach { $0.isEnabled = true }
  }

  @objc private func undoEdit() { editor.undo() }

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
      if outputButtons.first?.isEnabled == true { copyResult() }
    } else if key == "p" && modifiers.isEmpty {
      if outputButtons.last?.isEnabled == true { pinResult() }
    } else if key == "z" && modifiers == .command && editing {
      undoEdit()
    } else { return false }
    return true
  }

  @objc private func copyResult() { onFinish?(false) }
  @objc private func pinResult() { onFinish?(true) }
  @objc private func cancelResult() { onCancel?() }

  private func text(_ key: String) -> String {
    PinnedScreenshotWindow.localized(key)
  }
}

@MainActor
private final class ScrollingScreenshotEditView: NSView {
  private enum Drag { case top, bottom, mosaic }

  private(set) var edit: ScrollingScreenshotEdit?
  var onChange: (() -> Void)?
  var canUndo: Bool { !undoStack.isEmpty }
  private var thumbnail: CGImage?
  private var displayImage: NSImage?
  private var tiles: [ScrollingScreenshotEdit.Cell: NSImage] = [:]
  private var imageRect = NSRect.zero
  private var drag: Drag?
  private var dragStart: ScrollingScreenshotEdit?
  private var previousPoint = NSPoint.zero
  private var cropOffset: CGFloat = 0
  private var undoStack: [ScrollingScreenshotEdit] = []
  override var isFlipped: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  func load(_ image: CGImage, width: Int, height: Int, viewport: NSSize) {
    thumbnail = image
    displayImage = NSImage(cgImage: image, size: .zero)
    let scale = min(1, max(1, viewport.width - 24) / CGFloat(width), 16_384 / CGFloat(height))
    let displayWidth = CGFloat(width) * scale
    let displayHeight = CGFloat(height) * scale
    imageRect = NSRect(x: (viewport.width - displayWidth) / 2, y: 10, width: displayWidth, height: displayHeight)
    frame.size = NSSize(width: viewport.width, height: max(viewport.height, imageRect.maxY + 10))
    edit = ScrollingScreenshotEdit(width: width, height: height, blockSize: max(6, Int(8 / scale)))
    onChange?()
    needsDisplay = true
  }

  private func position(of row: Int) -> CGFloat {
    imageRect.minY + CGFloat(row) * imageRect.height / CGFloat(edit?.height ?? 1)
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let edit else { return }
    displayImage?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1,
      respectFlipped: true, hints: nil)
    for cell in edit.cells {
      let x = CGFloat(cell.x * edit.blockSize) * imageRect.width / CGFloat(edit.width)
      let y = position(of: cell.y * edit.blockSize)
      let rect = NSRect(x: imageRect.minX + x, y: y,
        width: CGFloat(edit.blockSize) * imageRect.width / CGFloat(edit.width),
        height: CGFloat(edit.blockSize) * imageRect.height / CGFloat(edit.height)).intersection(imageRect)
      guard dirtyRect.intersects(rect), let tile = tile(for: cell, rect: rect) else { continue }
      tile.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
    let top = position(of: edit.rows.lowerBound)
    let bottom = position(of: edit.rows.upperBound)
    NSColor.black.withAlphaComponent(0.6).setFill()
    NSRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: top - imageRect.minY).fill()
    NSRect(x: imageRect.minX, y: bottom, width: imageRect.width, height: imageRect.maxY - bottom).fill()
    for (edge, y) in [(Drag.top, top), (.bottom, bottom)] {
      NSColor.controlAccentColor.setFill()
      NSRect(x: imageRect.minX, y: y - 1, width: imageRect.width, height: 2).fill()
      let center = handleCenter(edge)
      NSBezierPath(roundedRect: NSRect(x: center.x - 12, y: center.y - 4, width: 24, height: 8),
        xRadius: 4, yRadius: 4).fill()
      NSColor.white.setFill()
      NSRect(x: center.x - 6, y: center.y - 1, width: 12, height: 2).fill()
    }
  }

  private func handleCenter(_ edge: Drag) -> NSPoint {
    guard let edit else { return .zero }
    let top = edge == .top
    return NSPoint(x: imageRect.midX + (top ? -16 : 16),
      y: position(of: top ? edit.rows.lowerBound : edit.rows.upperBound))
  }

  private func tile(for cell: ScrollingScreenshotEdit.Cell, rect: NSRect) -> NSImage? {
    if let tile = tiles[cell] { return tile }
    guard let thumbnail else { return nil }
    let x = CGFloat(thumbnail.width) / imageRect.width
    let y = CGFloat(thumbnail.height) / imageRect.height
    let sample = NSRect(x: (rect.minX - imageRect.minX) * x, y: (imageRect.maxY - rect.maxY) * y,
      width: rect.width * x, height: rect.height * y)
    guard let pixel = ScreenshotAnnotationDocument.pixelated(thumbnail, in: sample,
      blockSize: max(sample.width, sample.height).rounded(.up) + 2) else { return nil }
    let tile = NSImage(cgImage: pixel, size: .zero)
    tiles[cell] = tile
    return tile
  }

  override func mouseDown(with event: NSEvent) {
    guard let edit else { return }
    let point = convert(event.locationInWindow, from: nil)
    let handles = [Drag.top, .bottom].map { edge in (edge, handleCenter(edge)) }
    if let (edge, center) = handles.first(where: {
      abs(point.x - $0.1.x) <= 14 && abs(point.y - $0.1.y) <= 7
    }) {
      drag = edge
      cropOffset = point.y - center.y
    } else if imageRect.contains(point) {
      drag = .mosaic
      previousPoint = point
    } else { return }
    dragStart = edit
    if drag == .mosaic { applyDrag(at: point) }
  }

  override func mouseDragged(with event: NSEvent) {
    guard drag != nil else { return }
    autoscroll(with: event)
    applyDrag(at: convert(event.locationInWindow, from: nil))
  }

  override func mouseUp(with event: NSEvent) {
    guard let original = dragStart, let edit else { return }
    if original.rows != edit.rows || original.cells != edit.cells {
      undoStack.append(original)
    }
    drag = nil
    dragStart = nil
    onChange?()
  }

  private func applyDrag(at point: NSPoint) {
    guard let drag, var edit else { return }
    switch drag {
    case .top, .bottom:
      edit.crop(at: (point.y - cropOffset - imageRect.minY) / imageRect.height, top: drag == .top)
    case .mosaic:
      let point = NSPoint(x: min(imageRect.maxX, max(imageRect.minX, point.x)),
        y: min(imageRect.maxY, max(imageRect.minY, point.y)))
      let dx = point.x - previousPoint.x
      let dy = point.y - previousPoint.y
      let steps = max(1, Int(ceil(hypot(dx, dy) / 4)))
      for step in 1...steps {
        let progress = CGFloat(step) / CGFloat(steps)
        let x = previousPoint.x + dx * progress - imageRect.minX
        let y = previousPoint.y + dy * progress - imageRect.minY
        edit.paint(NSRect(x: (x - 10) / imageRect.width, y: (y - 10) / imageRect.height,
          width: 20 / imageRect.width, height: 20 / imageRect.height))
      }
      previousPoint = point
    }
    self.edit = edit
    onChange?()
    needsDisplay = true
  }

  func undo() {
    guard drag == nil, let previous = undoStack.popLast() else { return }
    edit = previous
    onChange?()
    needsDisplay = true
  }
}
