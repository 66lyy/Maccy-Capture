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
    let container = GlassSurfaceView(frame: NSRect(origin: .zero, size: frame.size))
    imageView.frame = container.bounds.insetBy(dx: 4, dy: 4)
    imageView.autoresizingMask = [.width, .height]
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.wantsLayer = true
    imageView.layer?.cornerRadius = 10
    imageView.layer?.cornerCurve = .continuous
    imageView.layer?.masksToBounds = true
    imageView.setAccessibilityLabel(localized("ScreenshotTitle"))
    container.controlsView.addSubview(imageView)

    var buttons = [overlayButton(symbol: "pin", label: "ScreenshotPinImage", action: #selector(pinImage))]
    if annotationHandler != nil {
      buttons.insert(overlayButton(symbol: "pencil.tip", label: "AnnotationEdit", action: #selector(annotateImage)), at: 0)
    }
    buttons.append(overlayButton(symbol: "xmark", label: "ScreenshotDismissPreview", action: #selector(dismiss)))
    let controls = GlassControlStrip(buttons: buttons)
    controls.frame.origin = NSPoint(x: max(0, container.bounds.maxX - controls.frame.width - 6),
                                    y: max(0, container.bounds.maxY - controls.frame.height - 6))
    controls.autoresizingMask = [.minXMargin, .minYMargin]
    container.controlsView.addSubview(controls)
    contentView = container
  }

  private func overlayButton(symbol: String, label: String, action: Selector) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: localized(label)) ?? NSImage(),
      target: self, action: action
    )
    button.toolTip = localized(label)
    button.setAccessibilityLabel(localized(label))
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
