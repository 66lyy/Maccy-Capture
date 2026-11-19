import AppKit

@MainActor
final class PinnedScreenshotWindow: NSPanel, NSWindowDelegate {
  var onClose: (() -> Void)?
  var onCloseAll: (() -> Void)?
  var onAnnotate: ((NSImage) -> Void)?

  private(set) var image: NSImage
  private let imageView = PinnedScreenshotImageView()
  private let initialVisibleFrame: NSRect
  private var imageScale: CGFloat
  private var isApplyingZoom = false

  init(image: NSImage, visibleFrame: NSRect, anchor: NSPoint) {
    let initialFrame = Self.initialFrame(imageSize: image.size, visibleFrame: visibleFrame, anchor: anchor)
    self.image = image
    initialVisibleFrame = visibleFrame
    imageScale = min(initialFrame.width / image.size.width, initialFrame.height / image.size.height)
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
    title = localized("PinScreenshot")
    setAccessibilityLabel(localized("PinScreenshot"))

    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    imageView.frame = container.bounds
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.autoresizingMask = [.width, .height]
    imageView.setAccessibilityLabel(localized("ScreenshotTitle"))
    imageView.toolTip = localized("ScreenshotZoomHelp")
    container.addSubview(imageView)

    let closeLabel = localized("ScreenshotClose")
    let closeButton = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: closeLabel) ?? NSImage(),
      target: self, action: #selector(closeImage)
    )
    closeButton.setAccessibilityLabel(closeLabel)
    closeButton.toolTip = closeLabel
    let controls = GlassControlStrip(buttons: [closeButton])
    controls.frame.origin = NSPoint(x: container.bounds.maxX - controls.frame.width - 4,
                                    y: container.bounds.maxY - controls.frame.height - 4)
    controls.autoresizingMask = [.minXMargin, .minYMargin]
    container.addSubview(controls)

    let menu = NSMenu()
    let copyItem = NSMenuItem(title: localized("ScreenshotCopy"), action: #selector(copyImage), keyEquivalent: "")
    copyItem.target = self
    menu.addItem(copyItem)
    let annotateItem = NSMenuItem(title: localized("AnnotationEdit"), action: #selector(annotateImage), keyEquivalent: "")
    annotateItem.target = self
    menu.addItem(annotateItem)
    menu.addItem(.separator())
    let closeItem = NSMenuItem(title: localized("ScreenshotClose"), action: #selector(closeImage), keyEquivalent: "")
    closeItem.target = self
    menu.addItem(closeItem)
    let closeAllItem = NSMenuItem(
      title: localized("ScreenshotCloseAllPinned"), action: #selector(closeAllImages), keyEquivalent: ""
    )
    closeAllItem.target = self
    menu.addItem(closeAllItem)
    imageView.menu = menu
    contentView = container
    initialFirstResponder = imageView
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func scrollWheel(with event: NSEvent) {
    guard event.momentumPhase.isEmpty, event.phase != .cancelled else { return }
    let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
    let delta = event.scrollingDeltaY * direction
    guard delta.isFinite, delta != 0 else { return }
    let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.08
    zoom(by: exp(max(-0.5, min(0.5, delta * sensitivity))), with: event)
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
    } else {
      return false
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    onAnnotate = nil
    onCloseAll = nil
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
    guard !isApplyingZoom else { return }
    imageScale = min(frame.width / image.size.width, frame.height / image.size.height)
  }

  static func initialFrame(imageSize: NSSize, visibleFrame: NSRect, anchor: NSPoint) -> NSRect {
    guard imageSize.width > 0, imageSize.height > 0,
          visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }
    let scale = min(1, visibleFrame.width * 0.7 / imageSize.width, visibleFrame.height * 0.7 / imageSize.height)
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

  @objc func closeAllImages() {
    onCloseAll?()
  }

  @objc private func copyImage() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}

private final class PinnedScreenshotImageView: NSImageView {
  override func scrollWheel(with event: NSEvent) {
    window?.scrollWheel(with: event)
  }

  override func magnify(with event: NSEvent) {
    window?.magnify(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 {
      window?.close()
    } else {
      window?.makeKey()
      window?.performDrag(with: event)
    }
  }
}
