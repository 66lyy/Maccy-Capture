import AppKit
import UniformTypeIdentifiers
import Vision

@MainActor
class ScreenshotAnnotationWindow: NSPanel, NSWindowDelegate {
  enum OutputAction {
    case copy, pin, apply
  }

  var onClose: (() -> Void)?
  var onOutput: ((Data, NSImage, OutputAction) throws -> Void)?
  var loadSelectionImage: (() async throws -> (NSImage, NSRect))?
  var onCanvasReady: (() -> Void)?
  private(set) var canvas: ScreenshotAnnotationCanvas!
  private(set) var toolButtons: [ScreenshotToolbarButton] = []
  private(set) var swatches: [ScreenshotToolbarButton] = []
  private(set) var undoButton: NSButton!
  private(set) var redoButton: NSButton!
  private(set) var copyButton: NSButton!
  private(set) var pinButton: NSButton!
  private(set) var annotationToolbar = ScreenshotAnnotationToolbar()
  let styleSlider = NSSlider()
  let colorWell = NSColorWell()
  private var selectedTool: ScreenshotAnnotationDocument.Tool?
  private var lineWidth: CGFloat = 3
  private var fontSize: CGFloat = 24
  private let styleLabel = NSTextField(labelWithString: "")
  private let styleValue = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let editingPin: Bool
  private let toolbarBounds: NSRect
  private let toolbarSize: NSSize
  private var isFinished = false
  private var imageTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?
  private var savePanel: NSSavePanel?
  private var recognitionTask: Task<Void, Never>?
  private(set) var recognitionResults: ScreenshotRecognitionResults?
  private(set) var recognitionButton: NSButton!
  private var recognizedText = ""
  private let palette: [(NSColor, String)] = [
    (.red, "AnnotationRed"), (.systemOrange, "AnnotationOrange"), (.systemYellow, "AnnotationYellow"),
    (.systemGreen, "AnnotationGreen"), (.systemCyan, "AnnotationCyan"), (.white, "AnnotationWhite"),
    (.black, "AnnotationBlack")
  ]

  convenience init?(
    image: NSImage, visibleFrame: NSRect, screenFrame: NSRect? = nil, imageFrame: NSRect? = nil,
    editingPin: Bool = false, originalWasCopied: Bool = true
  ) {
    guard let document = ScreenshotAnnotationDocument(image: image),
          visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }
    let display = screenFrame ?? visibleFrame
    guard display.width > 0, display.height > 0 else { return nil }
    self.init(display: display, visibleFrame: visibleFrame, editingPin: editingPin, originalWasCopied: originalWasCopied)
    let overlay = ScreenshotAnnotationOverlay(frame: NSRect(origin: .zero, size: display.size))
    overlay.onCancel = { [weak self] in self?.cancelOperation(nil) }
    contentView = overlay
    let rectangle = Self.imageFrame(imageSize: image.size, display: display, preferred: imageFrame)
      .offsetBy(dx: -display.minX, dy: -display.minY)
    overlay.imageFrame = rectangle
    showToolbar(beside: rectangle)
    selectedTool = .arrow
    attachCanvas(document, frame: rectangle)
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.close() }
    }
  }

  init(display: NSRect, visibleFrame: NSRect, editingPin: Bool = false, originalWasCopied: Bool = false) {
    self.editingPin = editingPin
    toolbarBounds = visibleFrame.offsetBy(dx: -display.minX, dy: -display.minY)
    let compact = visibleFrame.width < 476
    let narrow = visibleFrame.width < 430
    toolbarSize = NSSize(width: 460, height: narrow ? 149 : compact ? 120 : 88)
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
    configureToolbar(originalWasCopied: originalWasCopied, compact: compact, narrow: narrow)
    annotationToolbar.movementBounds = toolbarBounds
    annotationToolbar.onMove = { [weak self] in self?.positionRecognitionResults() }
    annotationToolbar.isHidden = true
    refreshHistoryButtons()
  }

  var isPreparingImage: Bool { imageTask != nil }

  func showToolbar(beside rectangle: NSRect?) {
    annotationToolbar.isHidden = rectangle == nil
    guard let rectangle, let contentView else { return }
    if annotationToolbar.superview == nil { contentView.addSubview(annotationToolbar) }
    annotationToolbar.frame = Self.toolbarFrame(beside: rectangle, bounds: toolbarBounds, size: toolbarSize)
  }

  private func attachCanvas(_ document: ScreenshotAnnotationDocument, frame: NSRect) {
    let canvas = ScreenshotAnnotationCanvas(document: document)
    self.canvas = canvas
    canvas.imageInset = 0
    canvas.canvasBackgroundColor = .clear
    canvas.frame = frame
    canvas.tool = selectedTool ?? .arrow
    canvas.color = colorWell.color
    canvas.lineWidth = lineWidth
    canvas.fontSize = fontSize
    contentView?.addSubview(canvas, positioned: .below, relativeTo: annotationToolbar)
    canvas.onChange = { [weak self] in self?.refreshHistoryButtons() }
    canvas.onCancel = { [weak self] in self?.cancelOperation(nil) }
    canvas.onBeginMark = { [weak self] in self?.clearRecognition() }
    initialFirstResponder = canvas
    updateTool()
  }

  private func withCanvas(_ action: @escaping (ScreenshotAnnotationCanvas) -> Void) {
    guard !isFinished else { return }
    if let canvas {
      action(canvas)
      return
    }
    guard imageTask == nil, let loadSelectionImage else { return }
    statusLabel.stringValue = text("AnnotationPreparingSelection")
    imageTask = Task { [weak self] in
      do {
        let (image, rectangle) = try await loadSelectionImage()
        try Task.checkCancellation()
        guard let self, !isFinished else { return }
        imageTask = nil
        guard let document = ScreenshotAnnotationDocument(image: image) else {
          showOutputError()
          return
        }
        statusLabel.stringValue = text("AnnotationToolbarShortcuts")
        attachCanvas(document, frame: rectangle)
        onCanvasReady?()
        if let canvas { action(canvas) }
      } catch {
        guard let self, !isFinished, !Task.isCancelled else { return }
        imageTask = nil
        statusLabel.stringValue = text("ScreenshotCaptureFailed")
      }
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
    if recognitionResults != nil {
      dismissRecognition()
    } else if canvas?.textField != nil {
      canvas.discardPendingMark()
      makeFirstResponder(canvas)
    } else {
      if !isFinished { close() }
    }
  }

  override func keyDown(with event: NSEvent) {
    guard canvas?.textField == nil else { super.keyDown(with: event); return }
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
       canvas?.textField == nil, !recognitionHasFocus {
      if modifiers.contains(.shift) { redoMark() } else { undoMark() }
      return true
    }
    if modifiers == .command {
      switch event.charactersIgnoringModifiers?.lowercased() {
      case "w": close(); return true
      case "s" where !annotationToolbar.isHidden: saveImage(); return true
      case "c" where recognitionHasFocus: recognitionResults?.textView.copy(nil); return true
      case "c" where canvas?.textField == nil: complete(.copy); return true
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  func windowWillClose(_ notification: Notification) {
    guard !isFinished else { return }
    isFinished = true
    imageTask?.cancel()
    imageTask = nil
    loadSelectionImage = nil
    onCanvasReady = nil
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
    savePanel?.cancel(nil)
    savePanel = nil
    colorWell.deactivate()
    clearRecognition()
    canvas?.onChange = nil
    canvas?.onCancel = nil
    canvas?.onBeginMark = nil
    canvas?.discardPendingMark()
    onOutput = nil
    (contentView as? ScreenshotAnnotationOverlay)?.onCancel = nil
    let handler = onClose
    onClose = nil
    handler?()
  }

  func complete(_ action: OutputAction) {
    guard !isFinished, let onOutput, let canvas else { return }
    canvas.commitText()
    guard let data = canvas.document.pngData(), let image = NSImage(data: data) else {
      showOutputError()
      return
    }
    do {
      try onOutput(data, image, action)
      if !isFinished { close() }
    } catch {
      showOutputError()
    }
  }

  @objc func undoMark() {
    guard let canvas else { return }
    clearRecognition()
    canvas.commitText()
    canvas.document.undo()
    refreshHistoryButtons()
  }

  @objc func redoMark() {
    guard let canvas else { return }
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
      control.isChosen = tool == selectedTool
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
    colorWell.colorWellStyle = .minimal
    colorWell.supportsAlpha = false
    colorWell.color = palette[0].0
    colorWell.target = self
    colorWell.action = #selector(selectCustomColor)
    colorWell.setAccessibilityLabel(text("AnnotationColor"))
    colorWell.toolTip = text("AnnotationColor")
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      colorWell.widthAnchor.constraint(equalToConstant: 28),
      colorWell.heightAnchor.constraint(equalToConstant: 25)
    ])
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
    let colors = row(swatches.map { $0 as NSView } + [colorWell])
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
    undoButton.isEnabled = canvas?.document.canUndo == true
    redoButton.isEnabled = canvas?.document.canRedo == true
    canvas?.needsDisplay = true
  }

  private func showOutputError() {
    statusLabel.stringValue = text("AnnotationOutputFailedShort")
    statusLabel.toolTip = text("AnnotationOutputFailed")
    statusLabel.setAccessibilityLabel(text("AnnotationOutputFailed"))
  }

  @objc private func selectTool(_ sender: NSButton) {
    guard let tool = ScreenshotAnnotationDocument.Tool(rawValue: sender.tag) else { return }
    chooseTool(tool)
  }

  func chooseTool(_ tool: ScreenshotAnnotationDocument.Tool) {
    canvas?.commitText()
    selectedTool = tool
    updateTool()
    withCanvas { [weak self] canvas in self?.makeFirstResponder(canvas) }
  }

  private func updateTool() {
    if let selectedTool { canvas?.tool = selectedTool }
    for button in toolButtons { button.isChosen = button.tag == selectedTool?.rawValue }
    refreshStyle()
    if let canvas { invalidateCursorRects(for: canvas) }
    refreshHistoryButtons()
  }

  @objc private func selectColor(_ sender: NSButton) {
    guard palette.indices.contains(sender.tag) else { return }
    applyColor(palette[sender.tag].0, selectedSwatch: sender.tag)
    if let canvas { makeFirstResponder(canvas) }
  }

  @objc private func selectCustomColor() {
    let color = colorWell.color.withAlphaComponent(1)
    applyColor(color, selectedSwatch: palette.firstIndex { $0.0.withAlphaComponent(1) == color })
  }

  private func applyColor(_ color: NSColor, selectedSwatch: Int?) {
    canvas?.commitText()
    colorWell.color = color
    canvas?.color = color
    for swatch in swatches { swatch.isChosen = swatch.tag == selectedSwatch }
  }

  private func refreshStyle() {
    let isText = selectedTool == .text
    let label = text(isText ? "AnnotationFontSize" : "AnnotationWidth")
    styleLabel.stringValue = label
    styleSlider.setAccessibilityLabel(label)
    styleSlider.minValue = isText ? 10 : 1
    styleSlider.maxValue = isText ? 120 : 40
    styleSlider.doubleValue = isText ? fontSize : lineWidth
    styleSlider.isEnabled = selectedTool != .redact
    styleValue.stringValue = selectedTool == .redact ? "—" : "\(styleSlider.integerValue)"
  }

  @objc private func changeSize() {
    let size = CGFloat(styleSlider.doubleValue.rounded())
    if selectedTool == .text {
      fontSize = size
      canvas?.fontSize = size
    } else if selectedTool != .redact {
      lineWidth = size
      canvas?.lineWidth = size
    }
    styleValue.stringValue = "\(Int(size))"
  }

  @objc private func recognizeText() {
    withCanvas { [weak self] canvas in self?.startRecognition(in: canvas) }
  }

  private func startRecognition(in canvas: ScreenshotAnnotationCanvas) {
    guard recognitionTask == nil, !isFinished else { return }
    clearRecognition()
    canvas.commitText()
    let document = canvas.document
    guard let image = document.marks.isEmpty ? document.sourceImage : document.renderedImage() else {
      showOutputError()
      return
    }
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
        showRecognizedText(value, message: nil)
      case .success:
        showRecognizedText("", message: text("AnnotationNoText"))
      case .failure:
        showRecognizedText("", message: text("AnnotationRecognitionFailed"))
      }
    }
  }

  private func clearRecognition() {
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionButton.isEnabled = true
    dismissRecognition()
  }

  private var recognitionHasFocus: Bool {
    firstResponder === recognitionResults?.textView && recognitionResults != nil
  }

  @objc private func dismissRecognition() {
    let hadFocus = recognitionHasFocus
    recognitionResults?.removeFromSuperview()
    recognitionResults = nil
    recognizedText = ""
    if hadFocus, !isFinished { makeFirstResponder((canvas as NSView?) ?? contentView) }
    if !isFinished { statusLabel.stringValue = text("AnnotationToolbarShortcuts") }
  }

  func showRecognizedText(_ value: String, message: String?) {
    dismissRecognition()
    recognizedText = value
    let results = ScreenshotRecognitionResults(
      title: text("AnnotationRecognitionResults"), value: message ?? value, copyEnabled: !value.isEmpty,
      copyTitle: text("AnnotationCopyAllText"), closeTitle: text("AnnotationCloseResults"), target: self,
      copyAction: #selector(copyRecognizedText), closeAction: #selector(dismissRecognition)
    )
    recognitionResults = results
    positionRecognitionResults()
    contentView?.addSubview(results, positioned: .above, relativeTo: annotationToolbar)
    makeFirstResponder(results.textView)
  }

  private func positionRecognitionResults() {
    let toolbar = annotationToolbar.frame
    let spaceBelow = toolbar.minY - toolbarBounds.minY - 18
    let spaceAbove = toolbarBounds.maxY - toolbar.maxY - 18
    let height = max(80, min(250, toolbarBounds.height * 0.42, max(spaceBelow, spaceAbove)))
    recognitionResults?.frame = Self.toolbarFrame(
      beside: toolbar, bounds: toolbarBounds, size: NSSize(width: 400, height: height)
    )
  }

  @objc private func copyRecognizedText() {
    guard !recognizedText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    if NSPasteboard.general.setString(recognizedText, forType: .string) {
      recognitionResults?.copyButton.title = text("AnnotationTextCopied")
    }
  }

  @objc private func saveImage() {
    withCanvas { [weak self] canvas in self?.presentSavePanel(for: canvas) }
  }

  private func presentSavePanel(for canvas: ScreenshotAnnotationCanvas) {
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
    let languages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
    if !languages.isEmpty { request.recognitionLanguages = languages }
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0
    let text = try recognize(image, request: request)
    guard text.isEmpty else { return text }

    let retry = VNRecognizeTextRequest()
    retry.recognitionLevel = .accurate
    retry.minimumTextHeight = 0
    retry.usesLanguageCorrection = false
    if !languages.isEmpty { retry.recognitionLanguages = languages }
    return try recognize(enlargedImage(image) ?? image, request: retry)
  }

  nonisolated private static func recognize(_ image: CGImage, request: VNRecognizeTextRequest) throws -> String {
    try Task.checkCancellation()
    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
    try Task.checkCancellation()
    return (request.results ?? []).compactMap { observation in
      observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }.joined(separator: "\n")
  }

  nonisolated private static func enlargedImage(_ image: CGImage) -> CGImage? {
    let scale = min(3, 3840.0 / Double(max(image.width, image.height)))
    guard scale > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: Int(Double(image.width) * scale), height: Int(Double(image.height) * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(bounds)
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
    return context.makeImage()
  }
}

@MainActor
final class ScreenshotRecognitionResults: NSVisualEffectView {
  let textView: NSTextView
  let copyButton: NSButton

  init(title: String, value: String, copyEnabled: Bool, copyTitle: String, closeTitle: String,
       target: AnyObject, copyAction: Selector, closeAction: Selector) {
    let scroll = NSTextView.scrollableTextView()
    textView = scroll.documentView as! NSTextView
    copyButton = NSButton(title: copyTitle, target: target, action: copyAction)
    super.init(frame: .zero)
    appearance = NSAppearance(named: .darkAqua)
    material = .hudWindow
    blendingMode = .withinWindow
    state = .active
    wantsLayer = true
    layer?.cornerRadius = 10
    layer?.masksToBounds = true
    layer?.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
    layer?.borderWidth = 1
    setAccessibilityLabel(title)
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    let close = ScreenshotToolbarButton(frame: .zero)
    close.isBordered = false
    close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: closeTitle)
    close.toolTip = closeTitle
    close.setAccessibilityLabel(closeTitle)
    close.target = target
    close.action = closeAction
    let header = NSStackView(views: [heading, NSView(), close])
    header.alignment = .centerY
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = false
    textView.string = value
    textView.font = .systemFont(ofSize: 14)
    textView.textContainerInset = NSSize(width: 8, height: 6)
    textView.setAccessibilityLabel(title)
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = true
    copyButton.isEnabled = copyEnabled
    for subview in [header as NSView, scroll, copyButton] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      addSubview(subview)
    }
    NSLayoutConstraint.activate([
      close.widthAnchor.constraint(equalToConstant: 24),
      close.heightAnchor.constraint(equalToConstant: 22),
      header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
      scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      copyButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 7),
      copyButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      copyButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
    ])
  }

  required init?(coder: NSCoder) { nil }
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
  var onMove: (() -> Void)?
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
    onMove?()
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
