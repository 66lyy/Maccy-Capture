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
    selectionView.frozen = frozen.map { NSImage(cgImage: $0, size: frame.size) }
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
  private(set) var image: CGImage?
  var stitcher: ScrollingScreenshotStitcher?
  private let thumbnail = NSImageView()
  private let dimensions = NSTextField(labelWithString: "")
  private let hint = NSTextField(wrappingLabelWithString: "")
  private var outputButtons: [NSButton] = []

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  init(beside rectangle: NSRect, bounds: NSRect, level: Int) {
    let frame = ScreenshotAnnotationWindow.toolbarFrame(
      beside: rectangle, bounds: bounds, size: NSSize(width: 300, height: 240)
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
    for button in [copy, pin, cancel] {
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
  }

  func update(_ image: CGImage, capped: Bool) {
    self.image = image
    thumbnail.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    dimensions.stringValue = "\(image.width) × \(image.height) px"
    hint.stringValue = text(capped ? "ScreenshotLongLimit" : "ScreenshotLongHint")
    outputButtons.forEach { $0.isEnabled = true }
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
