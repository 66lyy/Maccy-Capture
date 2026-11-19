import AppKit

@MainActor
final class ScreenshotPreviewWindow: NSPanel, NSWindowDelegate {
  var onClose: (() -> Void)?
  let imageView: NSImageView

  private let dismissalDelay: Duration
  private var dismissalTask: Task<Void, Never>?
  private var pinHandler: (@MainActor () -> Void)?
  private var annotationHandler: (@MainActor () -> Void)?

  init(
    image: NSImage,
    visibleFrame: NSRect,
    dismissalDelay: Duration = .seconds(2),
    onAnnotate: (@MainActor () -> Void)? = nil,
    onPin: @escaping @MainActor () -> Void
  ) {
    self.dismissalDelay = dismissalDelay
    self.pinHandler = onPin
    annotationHandler = onAnnotate
    imageView = NSImageView(image: image)
    super.init(
      contentRect: Self.initialFrame(imageSize: image.size, visibleFrame: visibleFrame),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    delegate = self
    isReleasedWhenClosed = false
    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    title = localized("ScreenshotSuccess")
    setAccessibilityLabel(title)
    configureContent()
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  func present() {
    orderFrontRegardless()
    scheduleDismissal()
  }

  func scheduleDismissal() {
    dismissalTask?.cancel()
    dismissalTask = Task { [weak self, dismissalDelay] in
      do {
        try await Task.sleep(for: dismissalDelay)
        self?.close()
      } catch {
        return
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    dismissalTask?.cancel()
    dismissalTask = nil
    pinHandler = nil
    annotationHandler = nil
    let handler = onClose
    onClose = nil
    handler?()
  }

  static func initialFrame(imageSize: NSSize, visibleFrame: NSRect) -> NSRect {
    guard imageSize.width > 0, imageSize.height > 0,
          visibleFrame.width > 0, visibleFrame.height > 0 else { return .zero }
    let inset = min(16, visibleFrame.width / 10, visibleFrame.height / 10)
    let maxWidth = min(220, visibleFrame.width - inset * 2)
    let maxHeight = min(150, visibleFrame.height - inset * 2)
    let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
    let size = NSSize(
      width: min(maxWidth, max(96, imageSize.width * scale)),
      height: min(maxHeight, max(64, imageSize.height * scale))
    )
    return NSRect(
      x: visibleFrame.maxX - inset - size.width,
      y: visibleFrame.minY + inset,
      width: size.width,
      height: size.height
    )
  }

  private func configureContent() {
    let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
    container.wantsLayer = true
    container.layer?.cornerRadius = 8
    container.layer?.masksToBounds = true
    container.layer?.borderWidth = 2
    container.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
    container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

    imageView.frame = container.bounds.insetBy(dx: 2, dy: 2)
    imageView.autoresizingMask = [.width, .height]
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.setAccessibilityLabel(localized("ScreenshotTitle"))
    container.addSubview(imageView)

    let closeButton = overlayButton(symbol: "xmark", label: "ScreenshotDismissPreview", action: #selector(dismiss))
    closeButton.frame.origin = NSPoint(x: 6, y: container.bounds.maxY - 30)
    container.addSubview(closeButton)
    let pinButton = overlayButton(symbol: "pin.fill", label: "ScreenshotPinImage", action: #selector(pinImage))
    pinButton.frame.origin = NSPoint(x: container.bounds.maxX - 30, y: container.bounds.maxY - 30)
    container.addSubview(pinButton)
    if annotationHandler != nil {
      let editButton = overlayButton(symbol: "pencil.tip", label: "AnnotationEdit", action: #selector(annotateImage))
      editButton.frame.origin = NSPoint(x: 36, y: container.bounds.maxY - 30)
      container.addSubview(editButton)
    }
    contentView = container
  }

  private func overlayButton(symbol: String, label: String, action: Selector) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: localized(label)) ?? NSImage(),
      target: self, action: action
    )
    button.bezelStyle = .circular
    button.isBordered = true
    button.appearance = NSAppearance(named: .darkAqua)
    button.bezelColor = NSColor.black.withAlphaComponent(0.65)
    button.contentTintColor = .white
    button.toolTip = localized(label)
    button.setAccessibilityLabel(localized(label))
    button.frame.size = NSSize(width: 24, height: 24)
    return button
  }

  @objc private func dismiss() {
    close()
  }

  @objc func pinImage() {
    let handler = pinHandler
    close()
    handler?()
  }

  @objc func annotateImage() {
    let handler = annotationHandler
    close()
    handler?()
  }

  private func localized(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}
