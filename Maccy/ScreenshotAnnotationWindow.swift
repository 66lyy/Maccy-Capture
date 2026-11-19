import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotAnnotationWindow: NSPanel, NSWindowDelegate {
  enum OutputAction {
    case copy, pin, apply
  }

  var onClose: (() -> Void)?
  var onOutput: ((Data, NSImage, OutputAction) throws -> Void)?
  let canvas: ScreenshotAnnotationCanvas
  private(set) var toolPicker: NSSegmentedControl!
  private(set) var undoButton: NSButton!
  private(set) var redoButton: NSButton!
  private(set) var copyButton: NSButton!
  private(set) var pinButton: NSButton!
  private(set) var annotationToolbar = ScreenshotAnnotationToolbar()
  private let colorWell = NSColorWell()
  private let widthPicker = NSPopUpButton()
  private let fontPicker = NSPopUpButton()
  private let statusLabel = NSTextField(labelWithString: "")
  private let editingPin: Bool
  private var isFinished = false
  private var screenObserver: NSObjectProtocol?
  private var savePanel: NSSavePanel?

  init?(
    image: NSImage, visibleFrame: NSRect, screenFrame: NSRect? = nil, imageFrame: NSRect? = nil,
    editingPin: Bool = false, originalWasCopied: Bool = true
  ) {
    guard let document = ScreenshotAnnotationDocument(image: image),
          visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
    let display = screenFrame ?? visibleFrame
    guard display.width > 0, display.height > 0 else { return nil }
    self.editingPin = editingPin
    canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.imageInset = 0
    canvas.canvasBackgroundColor = .clear
    let imageRectangle = Self.imageFrame(imageSize: image.size, display: display, preferred: imageFrame)
    super.init(
      contentRect: display, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
    )
    delegate = self
    isReleasedWhenClosed = false
    level = .floating
    backgroundColor = .clear
    isOpaque = false
    hasShadow = false
    hidesOnDeactivate = false
    becomesKeyOnlyIfNeeded = false
    acceptsMouseMovedEvents = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    title = text("AnnotationTitle")
    let overlay = ScreenshotAnnotationOverlay(frame: NSRect(origin: .zero, size: display.size))
    canvas.frame = imageRectangle.offsetBy(dx: -display.minX, dy: -display.minY)
    overlay.imageFrame = canvas.frame
    overlay.onCancel = { [weak self] in self?.cancelOperation(nil) }
    overlay.addSubview(canvas)
    contentView = overlay
    configureToolbar(originalWasCopied: originalWasCopied, compact: visibleFrame.width < 520)
    annotationToolbar.frame = Self.toolbarFrame(
      beside: canvas.frame, bounds: visibleFrame.offsetBy(dx: -display.minX, dy: -display.minY),
      size: NSSize(width: 508, height: visibleFrame.width < 520 ? 120 : 82)
    )
    annotationToolbar.movementBounds = visibleFrame.offsetBy(dx: -display.minX, dy: -display.minY)
    overlay.addSubview(annotationToolbar)
    canvas.onChange = { [weak self] in self?.refreshHistoryButtons() }
    canvas.onCancel = { [weak self] in self?.cancelOperation(nil) }
    initialFirstResponder = canvas
    refreshHistoryButtons()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  func present() {
    guard !isFinished else { return }
    makeKeyAndOrderFront(nil)
    makeFirstResponder(canvas)
  }

  override func cancelOperation(_ sender: Any?) {
    if canvas.textField != nil {
      canvas.discardPendingMark()
      makeFirstResponder(canvas)
    } else {
      close()
    }
  }

  override func keyDown(with event: NSEvent) {
    guard canvas.textField == nil else { super.keyDown(with: event); return }
    switch event.keyCode {
    case 53: cancelOperation(nil)
    case 36, 76: complete(.copy)
    default:
      if event.charactersIgnoringModifiers?.lowercased() == "p" {
        complete(editingPin ? .apply : .pin)
      } else {
        super.keyDown(with: event)
      }
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.charactersIgnoringModifiers?.lowercased() == "z", modifiers.contains(.command),
       canvas.textField == nil {
      if modifiers.contains(.shift) { redoMark() } else { undoMark() }
      return true
    }
    if modifiers == .command {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "w": close(); return true
      case "s": saveImage(); return true
      case "c" where canvas.textField == nil: complete(.copy); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  func windowWillClose(_ notification: Notification) {
    guard !isFinished else { return }
    isFinished = true
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
    savePanel?.cancel(nil)
    savePanel = nil
    canvas.onChange = nil
    canvas.onCancel = nil
    canvas.discardPendingMark()
    onOutput = nil
    (contentView as? ScreenshotAnnotationOverlay)?.onCancel = nil
    let handler = onClose
    onClose = nil
    handler?()
  }

  func complete(_ action: OutputAction) {
    guard !isFinished, let onOutput else { return }
    canvas.commitText()
    guard let data = canvas.document.pngData(), let image = NSImage(data: data) else {
      showOutputError()
      return
    }
    do {
      try onOutput(data, image, action)
      close()
    } catch {
      showOutputError()
    }
  }

  @objc func undoMark() {
    canvas.commitText()
    canvas.document.undo()
    refreshHistoryButtons()
  }

  @objc func redoMark() {
    canvas.commitText()
    canvas.document.redo()
    refreshHistoryButtons()
  }

  static func imageFrame(imageSize: NSSize, display: NSRect, preferred: NSRect?) -> NSRect {
    let requested = preferred ?? NSRect(
      x: display.midX - imageSize.width / 2, y: display.midY - imageSize.height / 2,
      width: imageSize.width, height: imageSize.height
    )
    guard requested.width > 0, requested.height > 0 else { return .zero }
    let scale = min(1, display.width / requested.width, display.height / requested.height)
    let size = NSSize(width: requested.width * scale, height: requested.height * scale)
    return NSRect(
      x: max(display.minX, min(requested.minX, display.maxX - size.width)),
      y: max(display.minY, min(requested.minY, display.maxY - size.height)),
      width: size.width, height: size.height
    )
  }

  static func toolbarFrame(beside imageFrame: NSRect, bounds: NSRect, size: NSSize) -> NSRect {
    let margin: CGFloat = min(8, bounds.width / 4, bounds.height / 4)
    let available = bounds.insetBy(dx: margin, dy: margin)
    let width = min(size.width, available.width)
    let height = min(size.height, available.height)
    let below = imageFrame.minY - height - 10
    let above = imageFrame.maxY + 10
    let preferredY = below >= available.minY ? below
      : above + height <= available.maxY ? above : available.minY
    return NSRect(
      x: max(available.minX, min(imageFrame.maxX - width, available.maxX - width)),
      y: max(available.minY, min(preferredY, available.maxY - height)),
      width: width, height: height
    )
  }

  private func configureToolbar(originalWasCopied: Bool, compact: Bool) {
    annotationToolbar.material = .popover
    annotationToolbar.blendingMode = .withinWindow
    annotationToolbar.state = .active
    annotationToolbar.wantsLayer = true
    annotationToolbar.layer?.cornerRadius = 10
    annotationToolbar.layer?.masksToBounds = true
    annotationToolbar.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
    annotationToolbar.setAccessibilityLabel(text("AnnotationTools"))
    let tools = ScreenshotAnnotationDocument.Tool.allCases
    let symbols = ["arrow.up.right", "rectangle", "oval", "pencil.tip", "textformat", "rectangle.fill"]
    toolPicker = NSSegmentedControl(
      images: zip(tools, symbols).map { tool, symbol in
        NSImage(systemSymbolName: symbol, accessibilityDescription: text(tool.titleKey)) ?? NSImage()
      }, trackingMode: .selectOne, target: self, action: #selector(selectTool)
    )
    for (index, tool) in tools.enumerated() {
      toolPicker.setWidth(28, forSegment: index)
      toolPicker.setToolTip(text(tool.titleKey), forSegment: index)
    }
    toolPicker.selectedSegment = 0
    toolPicker.setAccessibilityLabel(text("AnnotationTools"))
    undoButton = button("AnnotationUndo", symbol: "arrow.uturn.backward", action: #selector(undoMark))
    redoButton = button("AnnotationRedo", symbol: "arrow.uturn.forward", action: #selector(redoMark))
    copyButton = button("AnnotationCopy", symbol: "doc.on.doc", action: #selector(copyImage))
    pinButton = button(
      editingPin ? "AnnotationApply" : "ScreenshotPinImage",
      symbol: editingPin ? "checkmark" : "pin.fill",
      action: editingPin ? #selector(applyImage) : #selector(pinImage)
    )
    let outputRow = row([
      button("ScreenshotCancel", symbol: "xmark", action: #selector(cancelEditor)), pinButton,
      button("AnnotationSave", symbol: "square.and.arrow.down", action: #selector(saveImage)), copyButton
    ])
    let toolRow = row([toolPicker, undoButton, redoButton])
    colorWell.color = canvas.color
    colorWell.target = self
    colorWell.action = #selector(changeStyle)
    colorWell.setAccessibilityLabel(text("AnnotationColor"))
    colorWell.toolTip = text("AnnotationColor")
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      colorWell.widthAnchor.constraint(equalToConstant: 36),
      colorWell.heightAnchor.constraint(equalToConstant: 24)
    ])
    for width in [2, 3, 5, 8] {
      widthPicker.addItem(withTitle: "\(width)")
      widthPicker.lastItem?.tag = width
    }
    widthPicker.selectItem(at: 1)
    for size in [16, 24, 32, 48, 72] {
      fontPicker.addItem(withTitle: "\(size)")
      fontPicker.lastItem?.tag = size
    }
    fontPicker.selectItem(at: 1)
    for picker in [widthPicker, fontPicker] {
      picker.target = self
      picker.action = #selector(changeStyle)
    }
    widthPicker.setAccessibilityLabel(text("AnnotationWidth"))
    fontPicker.setAccessibilityLabel(text("AnnotationFontSize"))
    let info = NSImageView(image: NSImage(
      systemSymbolName: "info.circle", accessibilityDescription: text("AnnotationInlineHelp")
    ) ?? NSImage())
    info.toolTip = text("AnnotationInlineHelp") + "\n" + text(
      originalWasCopied ? "AnnotationExistingOriginalNotice" : "AnnotationPrivateNotice"
    )
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .systemRed
    statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let grip = NSImageView(image: NSImage(
      systemSymbolName: "line.3.horizontal", accessibilityDescription: text("AnnotationMoveToolbar")
    ) ?? NSImage())
    grip.toolTip = text("AnnotationMoveToolbar")
    let styleRow = row([
      grip, colorWell, NSTextField(labelWithString: text("AnnotationWidth")), widthPicker,
      NSTextField(labelWithString: text("AnnotationFontSize")), fontPicker, info, statusLabel
    ])
    let rows = compact ? [toolRow, outputRow, styleRow] : [row([toolRow, outputRow]), styleRow]
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    stack.translatesAutoresizingMaskIntoConstraints = false
    annotationToolbar.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: annotationToolbar.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: annotationToolbar.trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: annotationToolbar.centerYAnchor)
    ])
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.alignment = .centerY
    return stack
  }

  private func button(_ key: String, symbol: String, action: Selector) -> NSButton {
    let button = NSButton(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: text(key)) ?? NSImage(),
      target: self, action: action
    )
    button.bezelStyle = .texturedRounded
    button.imagePosition = .imageOnly
    button.toolTip = text(key)
    button.setAccessibilityLabel(text(key))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: 30).isActive = true
    button.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return button
  }

  private func refreshHistoryButtons() {
    undoButton.isEnabled = canvas.document.canUndo
    redoButton.isEnabled = canvas.document.canRedo
    canvas.needsDisplay = true
  }

  private func showOutputError() {
    statusLabel.stringValue = text("AnnotationOutputFailedShort")
    statusLabel.toolTip = text("AnnotationOutputFailed")
    statusLabel.setAccessibilityLabel(text("AnnotationOutputFailed"))
  }

  @objc private func selectTool() {
    canvas.commitText()
    guard let tool = ScreenshotAnnotationDocument.Tool(rawValue: toolPicker.selectedSegment) else { return }
    canvas.tool = tool
    invalidateCursorRects(for: canvas)
    makeFirstResponder(canvas)
  }

  @objc private func changeStyle() {
    canvas.commitText()
    canvas.color = colorWell.color.withAlphaComponent(1)
    canvas.lineWidth = CGFloat(widthPicker.selectedItem?.tag ?? 3)
    canvas.fontSize = CGFloat(fontPicker.selectedItem?.tag ?? 24)
    makeFirstResponder(canvas)
  }

  @objc private func saveImage() {
    guard !isFinished, savePanel == nil else { return }
    canvas.commitText()
    guard let data = canvas.document.pngData() else { showOutputError(); return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Screenshot.png"
    savePanel = panel
    panel.beginSheetModal(for: self) { [weak self] response in
      guard let self else { return }
      self.savePanel = nil
      guard !self.isFinished, response == .OK, let url = panel.url else { return }
      do {
        try data.write(to: url, options: .atomic)
      } catch {
        self.showOutputError()
      }
    }
  }

  @objc private func cancelEditor() { close() }
  @objc private func copyImage() { complete(.copy) }
  @objc private func pinImage() { complete(.pin) }
  @objc private func applyImage() { complete(.apply) }

  private func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}

@MainActor
final class ScreenshotAnnotationToolbar: NSVisualEffectView {
  var movementBounds = NSRect.zero
  private var dragOrigin: NSPoint?
  private var originalFrame = NSRect.zero

  override var mouseDownCanMoveWindow: Bool { false }

  override func mouseDown(with event: NSEvent) {
    beginMove(at: superview?.convert(event.locationInWindow, from: nil) ?? .zero)
  }

  override func mouseDragged(with event: NSEvent) {
    move(to: superview?.convert(event.locationInWindow, from: nil) ?? .zero)
  }

  override func mouseUp(with event: NSEvent) {
    dragOrigin = nil
  }

  func beginMove(at point: NSPoint) {
    dragOrigin = point
    originalFrame = frame
  }

  func move(to point: NSPoint) {
    guard let dragOrigin, point.x.isFinite, point.y.isFinite else { return }
    let bounds = movementBounds.insetBy(dx: 8, dy: 8)
    setFrameOrigin(NSPoint(
      x: max(bounds.minX, min(originalFrame.minX + point.x - dragOrigin.x, bounds.maxX - frame.width)),
      y: max(bounds.minY, min(originalFrame.minY + point.y - dragOrigin.y, bounds.maxY - frame.height))
    ))
  }
}

@MainActor
private final class ScreenshotAnnotationOverlay: NSView {
  var imageFrame = NSRect.zero
  var onCancel: (() -> Void)?

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    let shade = NSBezierPath(rect: bounds)
    shade.appendRect(imageFrame)
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.12).setFill()
    shade.fill()
    NSColor.controlAccentColor.setStroke()
    let border = NSBezierPath(rect: imageFrame.insetBy(dx: -1, dy: -1))
    border.lineWidth = 2
    border.stroke()
  }

  override func mouseDown(with event: NSEvent) {
    onCancel?()
  }

  override func rightMouseDown(with event: NSEvent) {
    onCancel?()
  }
}
