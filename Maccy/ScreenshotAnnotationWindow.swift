import AppKit
import Defaults
import KeyboardShortcuts
import UniformTypeIdentifiers

@MainActor
class ScreenshotAnnotationWindow: NSPanel, NSWindowDelegate {
  nonisolated enum OutputAction: Sendable {
    case copy, pin, apply
  }

  var onClose: (() -> Void)?
  var onOutput: ((Data?, NSImage, OutputAction) throws -> Void)?
  private(set) var exportTask: Task<Void, Never>?
  var loadSelectionImage: (() async throws -> (NSImage, NSRect))?
  var onCanvasReady: (() -> Void)?
  private(set) var canvas: ScreenshotAnnotationCanvas!
  var toolButtons: [ScreenshotToolbarButton] = []
  var swatches: [ScreenshotToolbarButton] = []
  var undoButton: NSButton!
  var redoButton: NSButton!
  var copyButton: NSButton!
  var pinButton: NSButton!
  let annotationToolbar = ScreenshotAnnotationToolbar()
  let styleSlider = NSSlider()
  let colorWell = NSColorWell()
  var selectedTool: ScreenshotAnnotationDocument.Tool?
  var lineWidth: CGFloat = 3
  var fontSize: CGFloat = 24
  var mosaicSize: CGFloat = 12
  var magnifierZoom: CGFloat = 2
  let styleLabel = NSTextField(labelWithString: "")
  let styleValue = NSTextField(labelWithString: "")
  let statusLabel = NSTextField(labelWithString: "")
  let editingPin: Bool
  let toolbarBounds: NSRect
  private let toolbarSize: NSSize
  private let originalWasCopied: Bool
  private(set) var isToolbarPrepared = false
  private static let statusRowHeight: CGFloat = 17
  private(set) var isFinished = false
  private var imageTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?
  var displays: @MainActor () -> [ScreenshotSelectionController.Display] = {
    ScreenshotSelectionController.Display.current()
  }
  private var savePanel: NSSavePanel?
  var recognitionTask: Task<Void, Never>?
  var recognitionOperation: TextRecognition.Operation = { image, cancellation in
    try TextRecognition.recognizeScreenshot(image, cancellation: cancellation)
  }
  var recognitionResults: ScreenshotRecognitionResults?
  var recognitionButton: NSButton!
  var recognizedText = ""
  let palette: [(NSColor, String)] = [
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
    selectedTool = ScreenshotAnnotationDocument.Tool.toolbarTools(
      order: Defaults[.annotationToolOrder], disabled: Defaults[.disabledAnnotationTools]
    ).first
    showToolbar(beside: rectangle)
    attachCanvas(document, frame: rectangle)
    let layout = displays()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, !ScreenshotSelectionController.Display.sameLayout(layout, self.displays()) else { return }
        self.close()
      }
    }
  }

  init(
    display: NSRect, visibleFrame: NSRect, editingPin: Bool = false, originalWasCopied: Bool = false,
    deferToolbar: Bool = false
  ) {
    self.editingPin = editingPin
    self.originalWasCopied = originalWasCopied
    toolbarBounds = visibleFrame.offsetBy(dx: -display.minX, dy: -display.minY)
    let compact = visibleFrame.width < 626
    let narrow = visibleFrame.width < 440
    toolbarSize = NSSize(width: 610, height: narrow ? 132 : compact ? 103 : 72)
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
    annotationToolbar.isHidden = true
    if !deferToolbar { prepareToolbar() }
  }

  private func prepareToolbar() {
    guard !isToolbarPrepared else { return }
    isToolbarPrepared = true
    configureToolbar(
      originalWasCopied: originalWasCopied, compact: toolbarBounds.width < 626, narrow: toolbarBounds.width < 440
    )
    annotationToolbar.movementBounds = toolbarBounds
    annotationToolbar.onMove = { [weak self] in self?.positionRecognitionResults() }
    refreshHistoryButtons()
  }

  var isPreparingImage: Bool { imageTask != nil }

  func showToolbar(beside rectangle: NSRect?) {
    guard let rectangle, let contentView else {
      annotationToolbar.isHidden = true
      return
    }
    prepareToolbar()
    annotationToolbar.isHidden = false
    if annotationToolbar.superview == nil { contentView.addSubview(annotationToolbar) }
    var frame = Self.toolbarFrame(beside: rectangle, bounds: toolbarBounds, size: currentToolbarSize)
    frame.origin = annotationToolbar.alignedOrigin(frame.origin)
    annotationToolbar.frame = frame
  }

  private var currentToolbarSize: NSSize {
    NSSize(width: toolbarSize.width, height: toolbarSize.height + (statusLabel.isHidden ? 0 : Self.statusRowHeight))
  }

  func setStatus(_ message: String?, detail: String? = nil) {
    statusLabel.stringValue = message ?? ""
    statusLabel.toolTip = detail
    statusLabel.setAccessibilityLabel(detail ?? message)
    guard statusLabel.isHidden != (message == nil) else { return }
    statusLabel.isHidden = message == nil
    guard annotationToolbar.superview != nil else { return }
    let old = annotationToolbar.frame
    let bounds = toolbarBounds.insetBy(dx: 8, dy: 8)
    let height = min(currentToolbarSize.height, toolbarBounds.height)
    let y = max(bounds.minY, min(old.maxY - height, bounds.maxY - height))
    annotationToolbar.frame = NSRect(
      origin: annotationToolbar.alignedOrigin(NSPoint(x: old.minX, y: y)),
      size: NSSize(width: old.width, height: height)
    )
    positionRecognitionResults()
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
    canvas.mosaicSize = mosaicSize
    canvas.magnifierZoom = magnifierZoom
    contentView?.addSubview(canvas, positioned: .below, relativeTo: annotationToolbar)
    canvas.onChange = { [weak self] in self?.refreshHistoryButtons() }
    canvas.onCancel = { [weak self] in self?.cancelOperation(nil) }
    canvas.onBeginMark = { [weak self] in self?.clearRecognition() }
    initialFirstResponder = canvas
    updateTool()
  }

  func withCanvas(_ action: @escaping (ScreenshotAnnotationCanvas) -> Void) {
    guard !isFinished else { return }
    if let canvas {
      action(canvas)
      return
    }
    guard imageTask == nil, let loadSelectionImage else { return }
    setStatus(text("AnnotationPreparingSelection"))
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
        setStatus(nil)
        attachCanvas(document, frame: rectangle)
        onCanvasReady?()
        if let canvas { action(canvas) }
      } catch {
        guard let self, !isFinished, !Task.isCancelled else { return }
        imageTask = nil
        setStatus(text("ScreenshotCaptureFailed"))
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
    } else if let canvas, canvas.textField != nil || canvas.isMovingText {
      canvas.discardPendingMark()
      makeFirstResponder(canvas)
    } else {
      if !isFinished { close() }
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      cancelOperation(nil)
    } else if !handleShortcut(event) {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if let shortcut = KeyboardShortcuts.Shortcut(event: event),
       !shortcut.modifiers.isDisjoint(with: [.command, .control, .option]),
       handleShortcut(event) {
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  private func handleShortcut(_ event: NSEvent) -> Bool {
    if ScopedShortcut.closeCapture.matches(event) {
      cancelOperation(nil)
    } else if ScopedShortcut.closeCaptureWindow.matches(event) {
      close()
    } else if recognitionHasFocus, KeyboardShortcuts.Shortcut(event: event) == .init(.c, modifiers: .command) {
      recognitionResults?.textView.copy(nil)
    } else {
      guard canvas?.textField == nil, !recognitionHasFocus else { return false }
      if canvas != nil, ScopedShortcut.undoAnnotation.matches(event) {
        undoMark()
      } else if canvas != nil, ScopedShortcut.redoAnnotation.matches(event) {
        redoMark()
      } else if ScopedShortcut.saveCapture.matches(event), !annotationToolbar.isHidden {
        saveImage()
      } else if ScopedShortcut.copyCapture.matches(event) || ScopedShortcut.copyCaptureWithCommand.matches(event) {
        complete(.copy)
      } else if ScopedShortcut.pinCapture.matches(event) {
        complete(editingPin ? .apply : .pin)
      } else {
        return false
      }
    }
    return true
  }

  func windowWillClose(_ notification: Notification) {
    guard !isFinished else { return }
    isFinished = true
    exportTask?.cancel()
    exportTask = nil
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
    guard !isFinished, exportTask == nil, savePanel == nil, let onOutput, let canvas else { return }
    canvas.commitText()
    let snapshot = canvas.document.renderSnapshot()
    exportTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        guard let image = snapshot.render() else { return nil as (CGImage, Data?)? }
        if action == .apply { return (image, nil) }
        guard let data = ScreenshotAnnotationDocument.RenderSnapshot.pngData(image) else { return nil }
        return (image, data)
      }.value
      guard let self, !isFinished, !Task.isCancelled else { return }
      defer { exportTask = nil }
      guard let (rendered, data) = result else { showOutputError(); return }
      do {
        try onOutput(data, NSImage(cgImage: rendered, size: .zero), action)
        if !isFinished { close() }
      } catch {
        showOutputError()
      }
    }
  }

  @objc func undoMark() {
    guard let canvas else { return }
    clearRecognition()
    canvas.cancelTextDrag()
    canvas.commitText()
    canvas.document.undo()
    refreshHistoryButtons()
  }

  @objc func redoMark() {
    guard let canvas else { return }
    clearRecognition()
    canvas.cancelTextDrag()
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

  private func showOutputError() {
    setStatus(text("AnnotationOutputFailedShort"), detail: text("AnnotationOutputFailed"))
  }

  @objc func saveImage() {
    withCanvas { [weak self] canvas in self?.presentSavePanel(for: canvas) }
  }

  private func presentSavePanel(for canvas: ScreenshotAnnotationCanvas) {
    guard !isFinished, savePanel == nil, exportTask == nil else { return }
    canvas.commitText()
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Screenshot.png"
    panel.level = max(panel.level, level)
    savePanel = panel
    panel.beginSheetModal(for: self) { [weak self] response in
      guard let self else { return }
      self.savePanel = nil
      guard !self.isFinished, response == .OK, let url = panel.url else { return }
      let snapshot = canvas.document.renderSnapshot()
      self.exportTask = Task { [weak self] in
        let result = await Task.detached(priority: .userInitiated) {
          Result {
            guard let image = snapshot.render(),
                  let data = ScreenshotAnnotationDocument.RenderSnapshot.pngData(image)
            else { throw ScreenshotExportFailure.render }
            try data.write(to: url, options: .atomic)
          }
        }.value
        guard let self, !isFinished, !Task.isCancelled else { return }
        exportTask = nil
        if case .failure = result { showOutputError() }
      }
    }
  }

  @objc func cancelEditor() { close() }
  @objc func copyImage() { complete(.copy) }
  @objc func pinImage() { complete(.pin) }
  @objc func applyImage() { complete(.apply) }

  func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}

private enum ScreenshotExportFailure: Error {
  case render
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
    NSColor.systemRed.setStroke()
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
