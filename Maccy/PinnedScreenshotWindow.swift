import AppKit

@MainActor
final class PinnedScreenshotWindow: NSPanel, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onCloseAll: (() -> Void)?
  var onAnnotate: ((NSImage) -> Void)?
  var onClickThroughChange: (() -> Void)?

  nonisolated static let minimumOpacity: CGFloat = 0.1

  var isClickThrough = false {
    didSet {
      guard isClickThrough != oldValue else { return }
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
  private let imageView = PinnedScreenshotImageView()
  private let controls: GlassControlStrip
  private let clickThroughSign = PinnedClickThroughSignView()
  private var clickThroughControls: [PinnedClickThroughControlPanel] = []
  private let clickThroughItem = NSMenuItem()
  private let initialVisibleFrame: NSRect
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
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    contentAspectRatio = image.size
    let minimumScale = min(1, 40 / min(image.size.width, image.size.height), frame.width / image.size.width)
    contentMinSize = NSSize(width: image.size.width * minimumScale, height: image.size.height * minimumScale)
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

  override func scrollWheel(with event: NSEvent) {
    guard event.momentumPhase.isEmpty, event.phase != .cancelled else { return }
    let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
    let delta = event.scrollingDeltaY * direction
    guard delta.isFinite, delta != 0 else { return }
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
    guard event.phase != .cancelled, event.magnification.isFinite, event.magnification != 0 else { return }
    zoom(by: max(0.01, 1 + event.magnification), with: event)
  }

  override func cancelOperation(_ sender: Any?) {
    close()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      close()
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
    closeClickThroughControls()
    onAnnotate = nil
    onCloseAll = nil
    onClickThroughChange = nil
    let handler = onClose
    onClose = nil
    handler?()
  }

  func replaceImage(_ replacement: NSImage) {
    guard replacement.isValid else { return }
    let displayScale = min(frame.width / replacement.size.width, frame.height / replacement.size.height)
    image = replacement
    imageView.image = replacement
    contentAspectRatio = replacement.size
    imageScale = displayScale
  }

  @objc func annotateImage() {
    onAnnotate?(image)
  }

  func windowDidResize(_ notification: Notification) {
    positionClickThroughControls()
    guard !isApplyingZoom else { return }
    imageScale = min(frame.width / image.size.width, frame.height / image.size.height)
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

  private static func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}

private final class PinnedScreenshotImageView: NSImageView {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func scrollWheel(with event: NSEvent) {
    window?.scrollWheel(with: event)
  }

  override func magnify(with event: NSEvent) {
    window?.magnify(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    guard let window = window as? PinnedScreenshotWindow else { return }
    if event.clickCount == 2 {
      window.close()
    } else {
      window.focusForInteraction()
      window.performDrag(with: event)
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
