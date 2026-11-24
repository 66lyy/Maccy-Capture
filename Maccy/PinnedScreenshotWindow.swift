import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class PinnedScreenshotWindow: NSPanel, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onCloseAll: (() -> Void)?
  var onAnnotate: ((NSImage) -> Void)?
  var onClickThroughChange: (() -> Void)?
  weak var thumbnailStack: PinnedScreenshotStack?
  private(set) var keepsOpenSeparately = false

  nonisolated static let minimumOpacity: CGFloat = 0.1

  var isClickThrough = false {
    didSet {
      guard isClickThrough != oldValue else { return }
      if isClickThrough { thumbnailStack?.detach(self) }
      ignoresMouseEvents = isClickThrough
      controls.isHidden = isClickThrough
      clickThroughSign.isHidden = !isClickThrough
      clickThroughItem.state = isClickThrough ? .on : .off
      if isClickThrough {
        showClickThroughControls()
      } else {
        closeClickThroughControls()
      }
      onClickThroughChange?()
    }
  }

  private(set) var image: NSImage
  fileprivate let createdAt = ContinuousClock.now
  private let imageView = PinnedScreenshotImageView()
  private let controls: GlassControlStrip
  private let thumbnailControls: GlassControlStrip
  private let pageLabel = PinnedScreenshotPageLabel(labelWithString: "")
  private let clickThroughSign = PinnedClickThroughSignView()
  private var clickThroughControls: [PinnedClickThroughControlPanel] = []
  private let clickThroughItem = NSMenuItem()
  private let initialVisibleFrame: NSRect
  private var expandedPresentation: (frame: NSRect, opacity: CGFloat)?
  var editingFrame: NSRect { expandedPresentation?.frame ?? frame }
  private var imageScale: CGFloat
  private var isApplyingZoom = false
  private var isRequestingKeyboardFocus = false

  init(image: NSImage, visibleFrame: NSRect, anchor: NSPoint, captureFrame: NSRect? = nil) {
    let initialFrame = Self.initialFrame(
      imageSize: image.size, visibleFrame: visibleFrame, anchor: anchor, captureFrame: captureFrame
    )
    self.image = image
    initialVisibleFrame = visibleFrame
    imageScale = min(initialFrame.width / image.size.width, initialFrame.height / image.size.height)
    let closeLabel = Self.localized("ScreenshotClose")
    let closeButton = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel) ?? NSImage(),
      target: nil, action: #selector(closeImage)
    )
    closeButton.setAccessibilityLabel(closeLabel)
    closeButton.toolTip = closeLabel
    controls = GlassControlStrip(buttons: [closeButton])
    let restoreLabel = Self.localized("PinnedStackRestore")
    let restoreButton = NSButton(
      image: NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: restoreLabel)
        ?? NSImage(),
      target: nil, action: #selector(restoreFromThumbnail)
    )
    restoreButton.setAccessibilityLabel(restoreLabel)
    restoreButton.toolTip = restoreLabel
    thumbnailControls = GlassControlStrip(buttons: [restoreButton])
    super.init(
      contentRect: initialFrame,
      styleMask: [.borderless, .resizable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    delegate = self
    isReleasedWhenClosed = false
    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    isMovableByWindowBackground = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    contentAspectRatio = image.size
    contentMinSize = Self.minimumSize(for: image.size, in: frame)
    title = Self.localized("PinScreenshot")
    setAccessibilityLabel(Self.localized("PinScreenshot"))

    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    imageView.frame = container.bounds
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.autoresizingMask = [.width, .height]
    imageView.setAccessibilityLabel(Self.localized("ScreenshotTitle"))
    imageView.toolTip = Self.localized("ScreenshotZoomHelp")
    container.addSubview(imageView)

    closeButton.target = self
    controls.frame.origin = NSPoint(x: container.bounds.maxX - controls.frame.width - 4,
                                    y: container.bounds.maxY - controls.frame.height - 4)
    controls.autoresizingMask = [.minXMargin, .minYMargin]
    container.addSubview(controls)

    restoreButton.target = self
    thumbnailControls.frame.origin = NSPoint(x: 4, y: container.bounds.maxY - thumbnailControls.frame.height - 4)
    thumbnailControls.autoresizingMask = [.minYMargin]
    thumbnailControls.isHidden = true
    container.addSubview(thumbnailControls)
    pageLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    pageLabel.textColor = .white
    pageLabel.drawsBackground = true
    pageLabel.backgroundColor = .black.withAlphaComponent(0.72)
    pageLabel.alignment = .center
    pageLabel.isHidden = true
    container.addSubview(pageLabel)

    clickThroughSign.frame = container.bounds
    clickThroughSign.autoresizingMask = [.width, .height]
    clickThroughSign.isHidden = true
    clickThroughSign.setAccessibilityLabel(Self.localized("PinnedClickThrough"))
    container.addSubview(clickThroughSign)

    let menu = NSMenu()
    let copyItem = NSMenuItem(title: Self.localized("ScreenshotCopy"), action: #selector(copyImage), keyEquivalent: "")
    copyItem.target = self
    menu.addItem(copyItem)
    let annotateItem = NSMenuItem(title: Self.localized("AnnotationEdit"), action: #selector(annotateImage), keyEquivalent: "")
    annotateItem.target = self
    menu.addItem(annotateItem)
    clickThroughItem.title = Self.localized("PinnedClickThrough")
    clickThroughItem.action = #selector(toggleClickThrough)
    clickThroughItem.target = self
    menu.addItem(clickThroughItem)
    menu.addItem(.separator())
    let closeItem = NSMenuItem(title: Self.localized("ScreenshotClose"), action: #selector(closeImage), keyEquivalent: "")
    closeItem.target = self
    menu.addItem(closeItem)
    let closeAllItem = NSMenuItem(
      title: Self.localized("ScreenshotCloseAllPinned"), action: #selector(closeAllImages), keyEquivalent: ""
    )
    closeAllItem.target = self
    menu.addItem(closeAllItem)
    imageView.menu = menu
    contentView = container
    initialFirstResponder = imageView
  }

  override var canBecomeKey: Bool { isRequestingKeyboardFocus || isKeyWindow }
  override var canBecomeMain: Bool { false }

  func present() {
    orderFrontRegardless()
  }

  func focusForInteraction() {
    isRequestingKeyboardFocus = true
    defer { isRequestingKeyboardFocus = false }
    makeKey()
  }

  func showThumbnail(in thumbnailFrame: NSRect, page: Int, total: Int) {
    if expandedPresentation == nil { expandedPresentation = (frame, alphaValue) }
    backgroundColor = .windowBackgroundColor
    alphaValue = 1
    contentMinSize = .zero
    contentAspectRatio = thumbnailFrame.size
    setFrame(thumbnailFrame, display: true)
    thumbnailControls.isHidden = false
    pageLabel.stringValue = "\(page) / \(total)"
    pageLabel.sizeToFit()
    pageLabel.frame = NSRect(x: 6, y: 6, width: pageLabel.frame.width + 8, height: pageLabel.frame.height + 4)
    pageLabel.isHidden = false
    imageView.toolTip = Self.localized("PinnedStackHelp")
    present()
  }

  func restoreExpandedPresentation() {
    defer { present() }
    guard let expandedPresentation else { return }
    self.expandedPresentation = nil
    backgroundColor = .clear
    alphaValue = expandedPresentation.opacity
    contentAspectRatio = image.size
    contentMinSize = Self.minimumSize(for: image.size, in: expandedPresentation.frame)
    setFrame(expandedPresentation.frame, display: true)
    imageScale = min(frame.width / image.size.width, frame.height / image.size.height)
    thumbnailControls.isHidden = true
    pageLabel.isHidden = true
    imageView.toolTip = Self.localized("ScreenshotZoomHelp")
  }

  @objc func restoreFromThumbnail() {
    guard let thumbnailStack else { return }
    keepsOpenSeparately = true
    thumbnailStack.detach(self)
  }

  override func scrollWheel(with event: NSEvent) {
    guard event.momentumPhase.isEmpty else { return }
    let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
    let delta = event.scrollingDeltaY * direction
    if let thumbnailStack {
      if !event.modifierFlags.contains(.option) {
        thumbnailStack.scroll(delta, precise: event.hasPreciseScrollingDeltas, phase: event.phase, from: self)
      }
      return
    }
    guard event.phase != .cancelled, delta.isFinite, delta != 0 else { return }
    if event.modifierFlags.contains(.option) {
      let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
      zoom(by: exp(max(-0.5, min(0.5, delta * sensitivity))), with: event)
    } else {
      alphaValue = Self.adjustedOpacity(alphaValue, delta: delta, precise: event.hasPreciseScrollingDeltas)
    }
  }

  nonisolated static func adjustedOpacity(_ opacity: CGFloat, delta: CGFloat, precise: Bool) -> CGFloat {
    guard opacity.isFinite, delta.isFinite else { return opacity }
    let step = max(-0.25, min(0.25, delta * (precise ? 0.004 : 0.05)))
    return max(minimumOpacity, min(1, opacity + step))
  }

  override func magnify(with event: NSEvent) {
    guard thumbnailStack == nil, event.phase != .cancelled,
          event.magnification.isFinite, event.magnification != 0 else { return }
    zoom(by: max(0.01, 1 + event.magnification), with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      close()
    } else if let thumbnailStack, [123, 124, 125, 126].contains(event.keyCode),
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]) {
      thumbnailStack.step(by: [123, 126].contains(event.keyCode) ? -1 : 1, from: self)
    } else if !handleShortcut(event) {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if handleShortcut(event) { return true }
    return super.performKeyEquivalent(with: event)
  }

  private func handleShortcut(_ event: NSEvent) -> Bool {
    if ScopedShortcut.closePinnedImage.matches(event) {
      close()
    } else if ScopedShortcut.copyPinnedImage.matches(event) {
      copyImage()
    } else if ScopedShortcut.editPinnedImage.matches(event) {
      annotateImage()
    } else if ScopedShortcut.clickThroughPinnedImage.matches(event) {
      toggleClickThrough()
    } else {
      return false
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    thumbnailStack?.remove(self)
    closeClickThroughControls()
    onAnnotate = nil
    onCloseAll = nil
    onClickThroughChange = nil
    let handler = onClose
    onClose = nil
    handler?()
  }

  func replaceImage(_ replacement: NSImage) {
    guard replacement.isValid, replacement.size.width > 0, replacement.size.height > 0 else { return }
    let oldFrame = editingFrame
    let displayScale = min(oldFrame.width / replacement.size.width, oldFrame.height / replacement.size.height)
    let newFrame = NSRect(
      x: oldFrame.midX - replacement.size.width * displayScale / 2,
      y: oldFrame.midY - replacement.size.height * displayScale / 2,
      width: replacement.size.width * displayScale,
      height: replacement.size.height * displayScale
    )
    image = replacement
    imageView.image = replacement
    if let expandedPresentation {
      self.expandedPresentation = (newFrame, expandedPresentation.opacity)
    } else {
      contentAspectRatio = replacement.size
      contentMinSize = Self.minimumSize(for: replacement.size, in: newFrame)
      setFrame(newFrame, display: true)
      imageScale = displayScale
    }
  }

  @objc func annotateImage() {
    onAnnotate?(image)
  }

  func windowDidResize(_ notification: Notification) {
    positionClickThroughControls()
    guard !isApplyingZoom else { return }
    imageScale = min(frame.width / image.size.width, frame.height / image.size.height)
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    thumbnailStack != nil ? frame.size : frameSize
  }

  private static func minimumSize(for imageSize: NSSize, in frame: NSRect) -> NSSize {
    let scale = min(1, 40 / min(imageSize.width, imageSize.height), frame.width / imageSize.width)
    return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
  }

  nonisolated static func initialFrame(
    imageSize: NSSize, visibleFrame: NSRect, anchor: NSPoint, captureFrame: NSRect? = nil
  ) -> NSRect {
    if let captureFrame, captureFrame.width <= visibleFrame.width, captureFrame.height <= visibleFrame.height {
      return captureFrame
    }
    guard imageSize.width.isFinite, imageSize.height.isFinite,
          imageSize.width > 0, imageSize.height > 0,
          visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }
    let scale = min(1, visibleFrame.width / imageSize.width, visibleFrame.height / imageSize.height)
    let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return NSRect(
      x: max(visibleFrame.minX, min(anchor.x - size.width / 2, visibleFrame.maxX - size.width)),
      y: max(visibleFrame.minY, min(anchor.y - size.height / 2, visibleFrame.maxY - size.height)),
      width: size.width,
      height: size.height
    )
  }

  static func zoomedFrame(
    imageSize: NSSize,
    frame: NSRect,
    factor: CGFloat,
    visibleFrame: NSRect,
    anchor: NSPoint
  ) -> NSRect {
    guard factor.isFinite, factor > 0,
          imageSize.width.isFinite, imageSize.height.isFinite,
          imageSize.width > 0, imageSize.height > 0,
          frame.width > 0, frame.height > 0,
          visibleFrame.width > 0, visibleFrame.height > 0,
          anchor.x.isFinite, anchor.y.isFinite else { return frame }
    let currentScale = min(frame.width / imageSize.width, frame.height / imageSize.height)
    let maximumScale = min(5, visibleFrame.width / imageSize.width, visibleFrame.height / imageSize.height)
    let minimumScale = min(1, 40 / min(imageSize.width, imageSize.height), maximumScale * 0.7)
    let scale = max(minimumScale, min(maximumScale, currentScale * factor))
    let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
    let fractionX = max(0, min(1, (anchor.x - frame.minX) / frame.width))
    let fractionY = max(0, min(1, (anchor.y - frame.minY) / frame.height))
    return NSRect(
      x: max(visibleFrame.minX, min(anchor.x - fractionX * size.width, visibleFrame.maxX - size.width)),
      y: max(visibleFrame.minY, min(anchor.y - fractionY * size.height, visibleFrame.maxY - size.height)),
      width: size.width,
      height: size.height
    )
  }

  private func zoom(by factor: CGFloat, with event: NSEvent) {
    let imageFrame = NSRect(
      x: frame.midX - image.size.width * imageScale / 2,
      y: frame.midY - image.size.height * imageScale / 2,
      width: image.size.width * imageScale,
      height: image.size.height * imageScale
    )
    let targetFrame = Self.zoomedFrame(
      imageSize: image.size, frame: imageFrame, factor: factor,
      visibleFrame: screen?.visibleFrame ?? initialVisibleFrame,
      anchor: convertPoint(toScreen: event.locationInWindow)
    )
    imageScale = targetFrame.width / image.size.width
    isApplyingZoom = true
    setFrame(targetFrame, display: true)
    isApplyingZoom = false
  }

  @objc private func closeImage() {
    close()
  }

  private func showClickThroughControls() {
    clickThroughControls = ClickThroughTarget.allCases.map { target in
      let closesPin = target == .badge
      return PinnedClickThroughControlPanel(
        label: Self.localized(closesPin ? "ScreenshotClose" : "PinnedClickThroughOff"),
        showsCloseIcon: closesPin, target: self, action: closesPin ? #selector(closeImage) : #selector(toggleClickThrough)
      )
    }
    positionClickThroughControls()
    for panel in clickThroughControls { addChildWindow(panel, ordered: .above) }
  }

  private func positionClickThroughControls() {
    guard !clickThroughControls.isEmpty, let contentView else { return }
    let contentFrame = convertToScreen(contentView.convert(contentView.bounds, to: nil))
    let visibleFrame = screen?.visibleFrame ?? initialVisibleFrame
    for (target, panel) in zip(ClickThroughTarget.allCases, clickThroughControls) {
      panel.setFrame(target.frame(in: contentFrame, visibleFrame: visibleFrame), display: true)
    }
  }

  private func closeClickThroughControls() {
    for panel in clickThroughControls {
      removeChildWindow(panel)
      panel.close()
    }
    clickThroughControls.removeAll()
  }

  private enum ClickThroughTarget: CaseIterable {
    case left, right, bottom, top, badge

    func frame(in bounds: NSRect, visibleFrame: NSRect) -> NSRect {
      let inset = max(1, min(4, min(bounds.width, bounds.height) / 3))
      switch self {
      case .left: return NSRect(x: bounds.minX, y: bounds.minY, width: inset, height: bounds.height)
      case .right: return NSRect(x: bounds.maxX - inset, y: bounds.minY, width: inset, height: bounds.height)
      case .bottom: return NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: inset)
      case .top: return NSRect(x: bounds.minX, y: bounds.maxY - inset, width: bounds.width, height: inset)
      case .badge:
        let size = PinnedClickThroughControlPanel.badgeSize
        let margin: CGFloat = 6
        var x = bounds.maxX - size - margin
        var y = bounds.maxY - size - margin
        if bounds.height < size + 2 * margin {
          y = bounds.maxY + size <= visibleFrame.maxY ? bounds.maxY : bounds.minY - size
        } else if bounds.width < size + 2 * margin {
          x = bounds.maxX + size <= visibleFrame.maxX ? bounds.maxX : bounds.minX - size
        }
        return NSRect(x: max(visibleFrame.minX, min(x, visibleFrame.maxX - size)),
                      y: max(visibleFrame.minY, min(y, visibleFrame.maxY - size)), width: size, height: size)
      }
    }
  }

  @objc func toggleClickThrough() {
    isClickThrough.toggle()
  }

  @objc func closeAllImages() {
    onCloseAll?()
  }

  @objc private func copyImage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  static func localized(_ key: String) -> String {
    let table = "GeneralSettings"
    let label = NSLocalizedString(key, tableName: table, comment: "")
    guard label == key, let url = Bundle.main.url(forResource: "en", withExtension: "lproj"),
          let fallback = Bundle(url: url) else { return label }
    return fallback.localizedString(forKey: key, value: nil, table: table)
  }
}

@MainActor
final class PinnedScreenshotStack {
  private(set) var pins: [PinnedScreenshotWindow] = []
  private(set) weak var visiblePin: PinnedScreenshotWindow?
  private var visibleFrame: NSRect = .zero
  private var scrollDistance: CGFloat = 0
  private var pagedInGesture = false

  func add(_ pin: PinnedScreenshotWindow, alongside candidates: [PinnedScreenshotWindow], visibleFrame: NSRect) {
    self.visibleFrame = visibleFrame
    for candidate in candidates + [pin]
    where candidate.thumbnailStack == nil && !candidate.isClickThrough && !candidate.keepsOpenSeparately {
      pins.append(candidate)
      candidate.thumbnailStack = self
    }
    if pins.count == 1 {
      pins.removeAll()
      pin.thumbnailStack = nil
      pin.present()
    } else {
      pins.sort { $0.createdAt < $1.createdAt }
      show(pin)
    }
  }

  func detach(_ pin: PinnedScreenshotWindow) {
    remove(pin)
    pin.restoreExpandedPresentation()
  }

  func restoreAll() {
    let previousPins = pins
    pins.removeAll()
    visiblePin = nil
    scrollDistance = 0
    pagedInGesture = false
    for pin in previousPins {
      pin.thumbnailStack = nil
      pin.restoreExpandedPresentation()
    }
  }

  func remove(_ pin: PinnedScreenshotWindow) {
    guard let index = pins.firstIndex(where: { $0 === pin }) else { return }
    pin.thumbnailStack = nil
    pins.remove(at: index)
    let next = visiblePin === pin ? (pins.isEmpty ? nil : pins[min(index, pins.count - 1)]) : visiblePin
    visiblePin = nil
    if pins.count == 1, let remaining = pins.first {
      pins.removeAll()
      remaining.thumbnailStack = nil
      remaining.restoreExpandedPresentation()
    } else if let next {
      show(next)
    }
  }

  func step(by direction: Int, from pin: PinnedScreenshotWindow) {
    guard pin === visiblePin, let index = pins.firstIndex(where: { $0 === pin }), pins.count > 1 else { return }
    let next = pins[(index + (direction < 0 ? -1 : 1) + pins.count) % pins.count]
    let wasKey = pin.isKeyWindow
    show(next)
    if wasKey { next.focusForInteraction() }
  }

  func scroll(_ delta: CGFloat, precise: Bool, phase: NSEvent.Phase, from pin: PinnedScreenshotWindow) {
    if phase == .began || phase == .ended || phase == .cancelled {
      scrollDistance = 0
      pagedInGesture = false
    }
    guard delta.isFinite, delta != 0, phase != .ended, phase != .cancelled else { return }
    if precise && !phase.isEmpty {
      guard !pagedInGesture else { return }
      scrollDistance += delta
      guard abs(scrollDistance) >= 28 else { return }
      pagedInGesture = true
      step(by: scrollDistance > 0 ? -1 : 1, from: pin)
    } else {
      step(by: delta > 0 ? -1 : 1, from: pin)
    }
  }

  private func show(_ pin: PinnedScreenshotWindow) {
    guard let index = pins.firstIndex(where: { $0 === pin }) else { return }
    for other in pins where other !== pin && other.isVisible { other.orderOut(nil) }
    visiblePin = pin
    pin.showThumbnail(in: Self.thumbnailFrame(in: visibleFrame), page: index + 1, total: pins.count)
  }

  static func thumbnailFrame(in visibleFrame: NSRect) -> NSRect {
    let margin = min(16, visibleFrame.width / 8, visibleFrame.height / 8)
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    let size = NSSize(width: min(176, bounds.width), height: min(112, bounds.height))
    return NSRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height)
  }
}

private final class PinnedScreenshotPageLabel: NSTextField {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PinnedScreenshotImageView: NSImageView, NSDraggingSource {
  private var dragStart: NSPoint?
  private var lastDragEvent: NSEvent?
  private var exportTask: Task<Void, Never>?
  private var exportedFile: URL?

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override var mouseDownCanMoveWindow: Bool { false }

  override func scrollWheel(with event: NSEvent) {
    window?.scrollWheel(with: event)
  }

  override func magnify(with event: NSEvent) {
    window?.magnify(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    guard let window = window as? PinnedScreenshotWindow else { return }
    resetDrag()
    window.focusForInteraction()
    if event.modifierFlags.contains(.command) {
      if window.thumbnailStack == nil { window.performDrag(with: event) }
    } else if event.clickCount == 2 {
      window.annotateImage()
    } else {
      dragStart = event.locationInWindow
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStart, exportedFile == nil else { return }
    lastDragEvent = event
    let point = event.locationInWindow
    guard exportTask == nil, hypot(point.x - dragStart.x, point.y - dragStart.y) >= 4,
          let image, let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    exportTask = Task { [weak self] in
      let file = await Task.detached(priority: .userInitiated) { try? PinnedScreenshotDragExport.stage(raster) }.value
      if Task.isCancelled {
        if let file { PinnedScreenshotDragExport.remove(file) }
        return
      }
      guard let self, canStartDrag else {
        self?.resetDrag()
        if let file { PinnedScreenshotDragExport.remove(file) }
        return
      }
      exportTask = nil
      let dragEvent = lastDragEvent
      resetDrag()
      guard let file else { NSSound.beep(); return }
      guard let dragEvent else { PinnedScreenshotDragExport.remove(file); return }
      startDrag(file, image: image, with: dragEvent)
    }
  }

  private var canStartDrag: Bool {
    window?.isVisible == true && dragStart != nil && NSEvent.pressedMouseButtons & 1 != 0
  }

  override func mouseUp(with event: NSEvent) {
    resetDrag()
  }

  private func resetDrag() {
    exportTask?.cancel()
    exportTask = nil
    dragStart = nil
    lastDragEvent = nil
  }

  private func startDrag(_ file: URL, image: NSImage, with event: NSEvent) {
    let item = NSDraggingItem(pasteboardWriter: file as NSURL)
    let point = convert(event.locationInWindow, from: nil)
    let scale = min(96 / image.size.width, 72 / image.size.height)
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    item.setDraggingFrame(
      NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
      contents: image
    )
    exportedFile = file
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
    -> NSDragOperation {
    context == .outsideApplication ? .copy : []
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    if operation.isEmpty, let exportedFile { PinnedScreenshotDragExport.remove(exportedFile) }
    exportedFile = nil
  }
}

nonisolated enum PinnedScreenshotDragExport {
  private static let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("MaccyCapturePinExports", isDirectory: true)

  static func stage(_ image: CGImage, in root: URL = root) throws -> URL {
    let files = FileManager.default
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    removeExpired(in: root)
    let file = directory.appendingPathComponent("Screenshot.png")
    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { remove(file); throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { remove(file); throw CocoaError(.fileWriteUnknown) }
    return file
  }

  static func remove(_ file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
  }

  // A receiving app may read the file asynchronously after accepting the drop.
  private static func removeExpired(in root: URL) {
    let files = FileManager.default
    let keys: Set<URLResourceKey> = [.contentModificationDateKey]
    let directories = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
    let cutoff = Date(timeIntervalSinceNow: -86_400)
    for directory in directories ?? [] where UUID(uuidString: directory.lastPathComponent) != nil {
      if let date = try? directory.resourceValues(forKeys: keys).contentModificationDate, date < cutoff {
        try? files.removeItem(at: directory)
      }
    }
  }
}

private final class PinnedClickThroughControlPanel: NSPanel {
  static let badgeSize: CGFloat = 22

  init(label: String, showsCloseIcon: Bool, target: PinnedScreenshotWindow, action: Selector) {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isReleasedWhenClosed = false
    isOpaque = false
    backgroundColor = showsCloseIcon ? .clear : NSColor.black.withAlphaComponent(0.02)
    hasShadow = false
    hidesOnDeactivate = false
    let button = PinnedClickThroughButton(title: "", target: target, action: action)
    button.isTransparent = !showsCloseIcon
    if showsCloseIcon {
      button.isBordered = false
      button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
      button.imagePosition = .imageOnly
      button.contentTintColor = .white
      button.wantsLayer = true
      button.layer?.cornerRadius = Self.badgeSize / 2
      button.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
    }
    button.toolTip = label
    button.setAccessibilityLabel(label)
    contentView = button
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private final class PinnedClickThroughButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Marks a click-through pin with a dashed edge, leaving the image itself untinted.
final class PinnedClickThroughSignView: NSView {
  private let border = CAShapeLayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    border.fillColor = nil
    border.lineWidth = 2
    border.lineDashPattern = [6, 4]
    layer?.addSublayer(border)
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    border.frame = bounds
    border.path = CGPath(rect: bounds.insetBy(dx: border.lineWidth / 2, dy: border.lineWidth / 2), transform: nil)
    updateColors()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateColors()
  }

  private func updateColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      border.strokeColor = NSColor.controlAccentColor.cgColor
    }
  }
}
