import AppKit
import UniformTypeIdentifiers
import Vision

@MainActor
final class ScreenshotAnnotationWindow: NSPanel, NSWindowDelegate {
  enum OutputAction {
    case copy, pin, apply
  }

  var onClose: (() -> Void)?
  var onOutput: ((Data, NSImage, OutputAction) throws -> Void)?
  let canvas: ScreenshotAnnotationCanvas
  private(set) var toolButtons: [ScreenshotToolbarButton] = []
  private(set) var swatches: [ScreenshotToolbarButton] = []
  private(set) var undoButton: NSButton!
  private(set) var redoButton: NSButton!
  private(set) var copyButton: NSButton!
  private(set) var pinButton: NSButton!
  private(set) var annotationToolbar = ScreenshotAnnotationToolbar()
  let styleSlider = NSSlider()
  private let styleLabel = NSTextField(labelWithString: "")
  private let styleValue = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let editingPin: Bool
  private var isFinished = false
  private var screenObserver: NSObjectProtocol?
  private var savePanel: NSSavePanel?
  private var recognitionTask: Task<Void, Never>?
  private var recognitionPopover: NSPopover?
  private var recognitionButton: NSButton!
  private var recognizedText = ""
  private let palette: [(NSColor, String)] = [
    (.red, "AnnotationRed"), (.systemOrange, "AnnotationOrange"), (.systemYellow, "AnnotationYellow"),
    (.systemGreen, "AnnotationGreen"), (.systemCyan, "AnnotationCyan"), (.white, "AnnotationWhite"),
    (.black, "AnnotationBlack")
  ]

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
    let compact = visibleFrame.width < 476
    let narrow = visibleFrame.width < 410
    configureToolbar(originalWasCopied: originalWasCopied, compact: compact, narrow: narrow)
    annotationToolbar.frame = Self.toolbarFrame(
      beside: canvas.frame, bounds: visibleFrame.offsetBy(dx: -display.minX, dy: -display.minY),
      size: NSSize(width: 460, height: narrow ? 149 : compact ? 120 : 88)
    )
    annotationToolbar.movementBounds = visibleFrame.offsetBy(dx: -display.minX, dy: -display.minY)
    overlay.addSubview(annotationToolbar)
    canvas.onChange = { [weak self] in self?.refreshHistoryButtons() }
    canvas.onCancel = { [weak self] in self?.cancelOperation(nil) }
    canvas.onBeginMark = { [weak self] in self?.clearRecognition() }
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
    clearRecognition()
    canvas.onChange = nil
    canvas.onCancel = nil
    canvas.onBeginMark = nil
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
    clearRecognition()
    canvas.commitText()
    canvas.document.undo()
    refreshHistoryButtons()
  }

  @objc func redoMark() {
    clearRecognition()
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

  private func configureToolbar(originalWasCopied: Bool, compact: Bool, narrow: Bool) {
    annotationToolbar.material = .hudWindow
    annotationToolbar.blendingMode = .withinWindow
    annotationToolbar.state = .active
    annotationToolbar.wantsLayer = true
    annotationToolbar.layer?.cornerRadius = 10
    annotationToolbar.layer?.masksToBounds = true
    annotationToolbar.appearance = NSAppearance(named: .darkAqua)
    annotationToolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    annotationToolbar.layer?.borderWidth = 1
    annotationToolbar.setAccessibilityLabel(text("AnnotationTools"))
    let tools = ScreenshotAnnotationDocument.Tool.allCases
    let symbols = ["arrow.up.right", "rectangle", "oval", "pencil.tip", "textformat", "rectangle.fill"]
    toolButtons = zip(tools, symbols).map { tool, symbol in
      let control = button(tool.titleKey, symbol: symbol, action: #selector(selectTool(_:)))
      control.tag = tool.rawValue
      control.isChosen = tool == canvas.tool
      return control
    }
    undoButton = button("AnnotationUndo", symbol: "arrow.uturn.backward", action: #selector(undoMark))
    redoButton = button("AnnotationRedo", symbol: "arrow.uturn.forward", action: #selector(redoMark))
    copyButton = button("AnnotationCopy", symbol: "doc.on.doc", action: #selector(copyImage))
    pinButton = button(
      editingPin ? "AnnotationApply" : "ScreenshotPinImage",
      symbol: editingPin ? "checkmark" : "pin.fill",
      action: editingPin ? #selector(applyImage) : #selector(pinImage)
    )
    recognitionButton = button("AnnotationRecognizeText", symbol: "text.viewfinder", action: #selector(recognizeText))
    let outputRow = row([
      recognitionButton, pinButton, button("AnnotationSave", symbol: "square.and.arrow.down", action: #selector(saveImage)),
      copyButton, button("ScreenshotCancel", symbol: "xmark", action: #selector(cancelEditor))
    ])
    let toolRow = row(toolButtons.map { $0 as NSView } + [undoButton, redoButton])
    swatches = palette.enumerated().map { index, entry in
      let swatch = button(entry.1, symbol: "", action: #selector(selectColor(_:)), width: 23)
      swatch.tag = index
      swatch.swatchColor = entry.0
      swatch.isChosen = index == 0
      return swatch
    }
    styleSlider.target = self
    styleSlider.action = #selector(changeSize)
    styleSlider.isContinuous = true
    styleSlider.controlSize = .small
    styleSlider.widthAnchor.constraint(equalToConstant: 95).isActive = true
    styleLabel.font = .systemFont(ofSize: 11, weight: .medium)
    styleValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    styleValue.alignment = .right
    styleValue.widthAnchor.constraint(equalToConstant: 34).isActive = true
    refreshStyle()
    let info = NSImageView(image: NSImage(
      systemSymbolName: "info.circle", accessibilityDescription: text("AnnotationInlineHelp")
    ) ?? NSImage())
    info.toolTip = text("AnnotationInlineHelp") + "\n" + text(
      originalWasCopied ? "AnnotationExistingOriginalNotice" : "AnnotationPrivateNotice"
    )
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .secondaryLabelColor
    let grip = ScreenshotToolbarGrip(image: NSImage(
      systemSymbolName: "line.3.horizontal", accessibilityDescription: text("AnnotationMoveToolbar")
    ) ?? NSImage())
    grip.toolTip = text("AnnotationMoveToolbar")
    let colors = row(swatches.map { $0 as NSView })
    let adjustment = row([styleLabel, styleSlider, styleValue])
    var rows: [NSView] = compact ? [row([grip, toolRow]), outputRow] : [row([grip, toolRow, outputRow])]
    if narrow {
      rows += [row([colors, info]), adjustment]
    } else {
      rows.append(row([colors, adjustment, info]))
    }
    rows.append(statusLabel)
    statusLabel.stringValue = text("AnnotationToolbarShortcuts")
    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 3
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
    stack.spacing = 3
    stack.alignment = .centerY
    return stack
  }

  private func button(_ key: String, symbol: String, action: Selector, width: CGFloat = 28) -> ScreenshotToolbarButton {
    let button = ScreenshotToolbarButton(frame: .zero)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text(key))?
      .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
    button.target = self
    button.action = action
    button.isBordered = false
    button.imagePosition = .imageOnly
    button.contentTintColor = .white
    button.toolTip = text(key)
    button.setAccessibilityLabel(text(key))
    button.translatesAutoresizingMaskIntoConstraints = false
    button.widthAnchor.constraint(equalToConstant: width).isActive = true
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

  @objc private func selectTool(_ sender: NSButton) {
    canvas.commitText()
    guard let tool = ScreenshotAnnotationDocument.Tool(rawValue: sender.tag) else { return }
    canvas.tool = tool
    for button in toolButtons { button.isChosen = button.tag == sender.tag }
    refreshStyle()
    invalidateCursorRects(for: canvas)
    makeFirstResponder(canvas)
  }

  @objc private func selectColor(_ sender: NSButton) {
    guard palette.indices.contains(sender.tag) else { return }
    canvas.commitText()
    canvas.color = palette[sender.tag].0
    for swatch in swatches { swatch.isChosen = swatch.tag == sender.tag }
    makeFirstResponder(canvas)
  }

  private func refreshStyle() {
    let isText = canvas.tool == .text
    let label = text(isText ? "AnnotationFontSize" : "AnnotationWidth")
    styleLabel.stringValue = label
    styleSlider.setAccessibilityLabel(label)
    styleSlider.minValue = isText ? 10 : 1
    styleSlider.maxValue = isText ? 120 : 40
    styleSlider.doubleValue = isText ? canvas.fontSize : canvas.lineWidth
    styleSlider.isEnabled = canvas.tool != .redact
    styleValue.stringValue = canvas.tool == .redact ? "—" : "\(styleSlider.integerValue)"
  }

  @objc private func changeSize() {
    let size = CGFloat(styleSlider.doubleValue.rounded())
    if canvas.tool == .text {
      canvas.fontSize = size
    } else if canvas.tool != .redact {
      canvas.lineWidth = size
    }
    styleValue.stringValue = "\(Int(size))"
  }

  @objc private func recognizeText() {
    guard recognitionTask == nil, !isFinished else { return }
    clearRecognition()
    canvas.commitText()
    guard let image = canvas.document.renderedImage() else { showOutputError(); return }
    recognitionButton.isEnabled = false
    statusLabel.stringValue = text("AnnotationRecognizingText")
    recognitionTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) { try ScreenshotTextRecognition.recognize(image) }
      let result = await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
      guard !Task.isCancelled, let self, !isFinished else { return }
      recognitionTask = nil
      recognitionButton.isEnabled = true
      switch result {
      case .success(let value) where !value.isEmpty:
        statusLabel.stringValue = text("AnnotationToolbarShortcuts")
        showRecognizedText(value)
      case .success:
        statusLabel.stringValue = text("AnnotationNoText")
      case .failure:
        statusLabel.stringValue = text("AnnotationRecognitionFailed")
      }
    }
  }

  private func clearRecognition() {
    if recognitionTask != nil {
      statusLabel.stringValue = text("AnnotationToolbarShortcuts")
    }
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionPopover?.close()
    recognitionPopover = nil
    recognitionButton.isEnabled = true
    recognizedText = ""
  }

  private func showRecognizedText(_ value: String) {
    recognizedText = value
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 210))
    let scroll = NSTextView.scrollableTextView()
    scroll.frame = NSRect(x: 12, y: 43, width: 276, height: 155)
    let resultView = scroll.documentView as? NSTextView
    resultView?.isEditable = false
    resultView?.string = value
    resultView?.font = .systemFont(ofSize: 13)
    resultView?.setAccessibilityLabel(text("AnnotationRecognizeText"))
    content.addSubview(scroll)
    let copy = NSButton(title: text("AnnotationCopyText"), target: self, action: #selector(copyRecognizedText))
    copy.sizeToFit()
    copy.setFrameOrigin(NSPoint(x: 10, y: 8))
    content.addSubview(copy)
    let controller = NSViewController()
    controller.view = content
    let popover = NSPopover()
    popover.contentViewController = controller
    popover.contentSize = content.frame.size
    popover.behavior = .transient
    recognitionPopover = popover
    popover.show(relativeTo: recognitionButton.bounds, of: recognitionButton, preferredEdge: .maxY)
  }

  @objc private func copyRecognizedText() {
    guard !recognizedText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(recognizedText, forType: .string)
    clearRecognition()
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

enum ScreenshotTextRecognition {
  nonisolated static func recognize(_ image: CGImage) throws -> String {
    try Task.checkCancellation()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    let supported = try request.supportedRecognitionLanguages()
    let languages = ["en-US", "zh-Hans", "zh-Hant"].filter(supported.contains)
    if !languages.isEmpty { request.recognitionLanguages = languages }
    try VNImageRequestHandler(cgImage: image).perform([request])
    try Task.checkCancellation()
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
  }
}

@MainActor
final class ScreenshotToolbarButton: NSButton {
  var isChosen = false { didSet { needsDisplay = true; setAccessibilityValue(isChosen) } }
  var swatchColor: NSColor? { didSet { needsDisplay = true } }

  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

  override func draw(_ dirtyRect: NSRect) {
    let tile = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
    if isChosen || cell?.isHighlighted == true {
      NSColor.white.withAlphaComponent(0.22).setFill()
      tile.fill()
    }
    if let swatchColor {
      let dot = NSBezierPath(ovalIn: NSRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14))
      swatchColor.setFill()
      dot.fill()
      NSColor.white.withAlphaComponent(isChosen ? 1 : 0.4).setStroke()
      dot.lineWidth = isChosen ? 2 : 1
      dot.stroke()
    } else {
      super.draw(dirtyRect)
    }
  }
}

@MainActor
private final class ScreenshotToolbarGrip: NSImageView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
    window?.makeFirstResponder(nil)
  }

  override func rightMouseDown(with event: NSEvent) {
    onCancel?()
  }
}
