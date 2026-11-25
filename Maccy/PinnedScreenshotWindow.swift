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
    NotificationCenter.default.addObserver(
      self, selector: #selector(screenParametersDidChange(_:)),
      name: NSApplication.didChangeScreenParametersNotification, object: nil
    )
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
    setExpandedFrame(Self.reachableFrame(expandedPresentation.frame, in: NSScreen.screens.map(\.visibleFrame)))
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
    imageView.cancelPendingExport()
    NotificationCenter.default.removeObserver(
      self, name: NSApplication.didChangeScreenParametersNotification, object: nil
    )
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
    let replacementFrame = NSRect(
      x: oldFrame.midX - replacement.size.width * displayScale / 2,
      y: oldFrame.midY - replacement.size.height * displayScale / 2,
      width: replacement.size.width * displayScale,
      height: replacement.size.height * displayScale
    )
    let newFrame = Self.reachableFrame(replacementFrame, in: NSScreen.screens.map(\.visibleFrame))
    image = replacement
    imageView.image = replacement
    if let expandedPresentation {
      self.expandedPresentation = (newFrame, expandedPresentation.opacity)
    } else {
      setExpandedFrame(newFrame)
    }
  }

  private func setExpandedFrame(_ frame: NSRect) {
    contentAspectRatio = image.size
    contentMinSize = Self.minimumSize(for: image.size, in: frame)
    setFrame(frame, display: true)
    imageScale = min(self.frame.width / image.size.width, self.frame.height / image.size.height)
  }

  @objc private func screenParametersDidChange(_ notification: Notification) {
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)
    let reachable = Self.reachableFrame(frame, in: visibleFrames)
    if let expandedPresentation {
      self.expandedPresentation = (
        Self.reachableFrame(expandedPresentation.frame, in: visibleFrames), expandedPresentation.opacity
      )
      if reachable != frame { setFrame(reachable, display: true) }
    } else if reachable != frame {
      setExpandedFrame(reachable)
    }
    positionClickThroughControls()
  }

  @objc func annotateImage() {
    onAnnotate?(image)
  }

  func windowDidResize(_ notification: Notification) {
    positionClickThroughControls()
    guard !isApplyingZoom else { return }
    imageScale = min(frame.width / image.size.width, frame.height / image.size.height)
  }

  func windowDidMove(_ notification: Notification) {
    thumbnailStack?.constrain(self)
  }

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
    thumbnailStack != nil ? frame.size : frameSize
  }

  private static func minimumSize(for imageSize: NSSize, in frame: NSRect) -> NSSize {
    let scale = min(1, 40 / min(imageSize.width, imageSize.height), frame.width / imageSize.width)
    return NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
  }

  nonisolated static func reachableFrame(_ frame: NSRect, in visibleFrames: [NSRect]) -> NSRect {
    guard !frame.isEmpty else { return frame }
    let screens = visibleFrames.filter { !$0.isEmpty }
    let grabWidth = min(40, frame.width)
    let grabHeight = min(40, frame.height)
    if screens.contains(where: { screen in
      let intersection = screen.intersection(frame)
      return frame.width <= screen.width && frame.height <= screen.height
        && intersection.width >= grabWidth && intersection.height >= grabHeight
    }) { return frame }

    func distance(to screen: NSRect) -> CGFloat {
      let dx = max(screen.minX - frame.midX, 0, frame.midX - screen.maxX)
      let dy = max(screen.minY - frame.midY, 0, frame.midY - screen.maxY)
      return hypot(dx, dy)
    }
    guard let screen = screens.min(by: { distance(to: $0) < distance(to: $1) }) else { return frame }
    let scale = min(1, screen.width / frame.width, screen.height / frame.height)
    let size = NSSize(width: frame.width * scale, height: frame.height * scale)
    return NSRect(
      x: max(screen.minX, min(frame.minX, screen.maxX - size.width)),
      y: max(screen.minY, min(frame.minY, screen.maxY - size.height)),
      width: size.width,
      height: size.height
    )
  }

  nonisolated static func initialFrame(
    imageSize: NSSize, visibleFrame: NSRect, anchor: NSPoint, captureFrame: NSRect? = nil
  ) -> NSRect {
    if let captureFrame, captureFrame.width <= visibleFrame.width, captureFrame.height <= visibleFrame.height {
      return reachableFrame(captureFrame, in: [visibleFrame])
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
    let board = Clipboard.shared.pasteboard
    board.prepareForNewContents(with: .currentHostOnly)
    if board.writeObjects([image]) { board.setString("", forType: Clipboard.hostOnlyType) }
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
  private let visibleFrames: () -> [NSRect]
  private let onEmpty: (() -> Void)?

  init(visibleFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) },
       onEmpty: (() -> Void)? = nil) {
    self.visibleFrames = visibleFrames
    self.onEmpty = onEmpty
  }

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
    if pins.count == 1, let remaining = pins.first {
      visiblePin = nil
      pins.removeAll()
      remaining.thumbnailStack = nil
      remaining.restoreExpandedPresentation()
    } else if let next {
      show(next)
    } else {
      visiblePin = nil
    }
    if pins.isEmpty { onEmpty?() }
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
    var frame = Self.thumbnailFrame(in: visibleFrame)
    if let visiblePin {
      frame.origin = visiblePin.frame.origin
      frame.origin = Self.constrainedOrigin(of: frame, in: visibleFrame)
    }
    for other in pins where other !== pin && other.isVisible { other.orderOut(nil) }
    visiblePin = pin
    let reachable = PinnedScreenshotWindow.reachableFrame(frame, in: visibleFrames())
    pin.showThumbnail(in: reachable, page: index + 1, total: pins.count)
  }

  func constrain(_ pin: PinnedScreenshotWindow) {
    guard pin === visiblePin, visibleFrames().contains(visibleFrame) else { return }
    let origin = Self.constrainedOrigin(of: pin.frame, in: visibleFrame)
    if pin.frame.origin != origin { pin.setFrameOrigin(origin) }
  }

  static func constrainedOrigin(of frame: NSRect, in bounds: NSRect) -> NSPoint {
    NSPoint(x: max(bounds.minX, min(frame.minX, bounds.maxX - frame.width)),
            y: max(bounds.minY, min(frame.minY, bounds.maxY - frame.height)))
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

struct PinnedScreenshotDragGesture {
  enum MouseDownAction: Equatable {
    case move, close, export
  }

  let origin: NSPoint

  static func action(for event: NSEvent) -> MouseDownAction {
    if event.modifierFlags.contains(.option) { return .export }
    return event.clickCount == 2 ? .close : .move
  }

  func crossedThreshold(with event: NSEvent) -> Bool {
    let point = event.locationInWindow
    return hypot(point.x - origin.x, point.y - origin.y) >= 4
  }
}

final class PinnedScreenshotImageView: NSImageView, NSDraggingSource {
  private var exportGesture: PinnedScreenshotDragGesture?
  private var lastDragEvent: NSEvent?
  private(set) var exportTask: Task<Void, Never>?
  var stageExport: @Sendable (CGImage) throws -> URL = { try PinnedScreenshotDragExport.stage($0) }
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
    cancelPendingExport()
    window.focusForInteraction()
    switch PinnedScreenshotDragGesture.action(for: event) {
    case .export:
      exportGesture = PinnedScreenshotDragGesture(origin: event.locationInWindow)
    case .close:
      window.close()
    case .move:
      window.performDrag(with: event)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let exportGesture, exportedFile == nil else { return }
    lastDragEvent = event
    guard exportTask == nil, exportGesture.crossedThreshold(with: event),
          let image, let raster = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    exportTask = Task { [weak self, stageExport] in
      guard !Task.isCancelled else { return }
      let worker = Task.detached(priority: .userInitiated) { try? stageExport(raster) }
      let file = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      if Task.isCancelled {
        if let file { PinnedScreenshotDragExport.remove(file) }
        return
      }
      guard let self, canStartDrag else {
        self?.cancelPendingExport()
        if let file { PinnedScreenshotDragExport.remove(file) }
        return
      }
      let dragEvent = lastDragEvent
      exportTask = nil
      cancelPendingExport()
      guard let file else { return }
      guard let dragEvent else { PinnedScreenshotDragExport.remove(file); return }
      startDrag(file, image: image, with: dragEvent)
    }
  }

  private var canStartDrag: Bool {
    window?.isVisible == true && window?.ignoresMouseEvents == false && exportGesture != nil
      && NSEvent.pressedMouseButtons & 1 != 0
  }

  override func mouseUp(with event: NSEvent) {
    cancelPendingExport()
  }

  func cancelPendingExport() {
    exportTask?.cancel()
    exportTask = nil
    exportGesture = nil
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

  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    if let exportedFile { PinnedScreenshotDragExport.finish(exportedFile, copied: operation.contains(.copy)) }
    exportedFile = nil
  }
}

nonisolated enum PinnedScreenshotDragExport {
  private static let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("MaccyCapturePinExports", isDirectory: true)

  static func stage(_ image: CGImage, in root: URL = root) throws -> URL {
    try Task.checkCancellation()
    let files = FileManager.default
    try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    removeExpired(in: root)
    try Task.checkCancellation()
    let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent("Screenshot.png")
    var completed = false
    defer { if !completed { remove(file) } }
    guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    try Task.checkCancellation()
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    try Task.checkCancellation()
    completed = true
    return file
  }

  static func remove(_ file: URL) {
    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
  }

  static func finish(_ file: URL, copied: Bool) {
    if !copied { remove(file) }
  }

  // A receiving app may read the file asynchronously after accepting the drop.
  static func removeExpired(in root: URL = root) {
    let files = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
    let directories = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
    let cutoff = Date(timeIntervalSinceNow: -86_400)
    for directory in directories ?? [] where UUID(uuidString: directory.lastPathComponent) != nil {
      if let values = try? directory.resourceValues(forKeys: keys), values.isDirectory == true,
         values.isSymbolicLink == false, let date = values.contentModificationDate, date < cutoff {
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
