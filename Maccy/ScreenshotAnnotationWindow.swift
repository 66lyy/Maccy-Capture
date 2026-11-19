import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotAnnotationWindow: NSWindow, NSWindowDelegate {
  enum OutputAction {
    case copy, pin, apply
  }

  var onClose: (() -> Void)?
  var onOutput: ((Data, NSImage, OutputAction) throws -> Void)?
  let canvas: ScreenshotAnnotationCanvas
  private(set) var toolPicker: NSSegmentedControl!
  private(set) var undoButton: NSButton!
  private(set) var redoButton: NSButton!
  private let colorWell = NSColorWell()
  private let widthPicker = NSPopUpButton()
  private let fontPicker = NSPopUpButton()
  private let statusLabel = NSTextField(wrappingLabelWithString: "")

  init?(image: NSImage, visibleFrame: NSRect, editingPin: Bool = false, originalWasCopied: Bool = true) {
    guard let document = ScreenshotAnnotationDocument(image: image) else { return nil }
    canvas = ScreenshotAnnotationCanvas(document: document)
    let size = NSSize(width: min(1060, visibleFrame.width * 0.9), height: min(780, visibleFrame.height * 0.9))
    super.init(
      contentRect: NSRect(
        x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
        width: size.width, height: size.height
      ),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    delegate = self
    isReleasedWhenClosed = false
    level = .floating
    collectionBehavior = [.fullScreenAuxiliary]
    title = text("AnnotationTitle")
    contentMinSize = NSSize(width: min(740, size.width), height: min(460, size.height))
    configureContent(editingPin: editingPin, originalWasCopied: originalWasCopied)
    canvas.onChange = { [weak self] in self?.refreshHistoryButtons() }
    initialFirstResponder = canvas
    refreshHistoryButtons()
  }

  func present() {
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  override func cancelOperation(_ sender: Any?) {
    if canvas.textField != nil {
      canvas.discardPendingMark()
    } else {
      close()
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
      default: break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  func windowWillClose(_ notification: Notification) {
    canvas.onChange = nil
    canvas.discardPendingMark()
    onOutput = nil
    let handler = onClose
    onClose = nil
    handler?()
  }

  func complete(_ action: OutputAction) {
    canvas.commitText()
    guard let data = canvas.document.pngData(), let image = NSImage(data: data) else {
      showOutputError()
      return
    }
    do {
      try onOutput?(data, image, action)
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

  private func configureContent(editingPin: Bool, originalWasCopied: Bool) {
    let container = NSView()
    toolPicker = NSSegmentedControl(
      labels: ScreenshotAnnotationDocument.Tool.allCases.map { text($0.titleKey) },
      trackingMode: .selectOne, target: self, action: #selector(selectTool)
    )
    toolPicker.selectedSegment = 0
    toolPicker.setAccessibilityLabel(text("AnnotationTools"))
    let toolRow = NSStackView(views: [toolPicker])
    toolRow.orientation = .horizontal
    colorWell.color = canvas.color
    colorWell.target = self
    colorWell.action = #selector(changeStyle)
    colorWell.setAccessibilityLabel(text("AnnotationColor"))
    colorWell.translatesAutoresizingMaskIntoConstraints = false
    colorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
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
    undoButton = button("AnnotationUndo", action: #selector(undoMark))
    redoButton = button("AnnotationRedo", action: #selector(redoMark))
    let styleRow = NSStackView(views: [
      NSTextField(labelWithString: text("AnnotationColor")), colorWell,
      NSTextField(labelWithString: text("AnnotationWidth")), widthPicker,
      NSTextField(labelWithString: text("AnnotationFontSize")), fontPicker, undoButton, redoButton
    ])
    styleRow.spacing = 8
    let help = NSTextField(wrappingLabelWithString: text("AnnotationCanvasHelp"))
    help.font = .systemFont(ofSize: 11)
    help.textColor = .secondaryLabelColor
    let notice = NSTextField(wrappingLabelWithString: text(
      originalWasCopied ? "AnnotationExistingOriginalNotice" : "AnnotationPrivateNotice"
    ))
    notice.font = .systemFont(ofSize: 11)
    notice.textColor = .secondaryLabelColor
    var outputButtons = [
      button("ScreenshotCancel", action: #selector(cancelEditor)),
      button("AnnotationSave", action: #selector(saveImage)),
      button("AnnotationCopy", action: #selector(copyImage))
    ]
    outputButtons.append(button(
      editingPin ? "AnnotationApply" : "ScreenshotPinImage",
      action: editingPin ? #selector(applyImage) : #selector(pinImage)
    ))
    let outputRow = NSStackView(views: outputButtons)
    outputRow.spacing = 10
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.textColor = .systemRed
    let views = [toolRow, styleRow, help, canvas, statusLabel, notice, outputRow]
    for view in views {
      view.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(view)
    }
    NSLayoutConstraint.activate([
      toolRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
      toolRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
      toolRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
      styleRow.topAnchor.constraint(equalTo: toolRow.bottomAnchor, constant: 8),
      styleRow.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
      styleRow.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
      help.topAnchor.constraint(equalTo: styleRow.bottomAnchor, constant: 8),
      help.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
      help.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      canvas.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 8),
      canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      canvas.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),
      statusLabel.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
      statusLabel.trailingAnchor.constraint(equalTo: help.trailingAnchor),
      statusLabel.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -6),
      notice.leadingAnchor.constraint(equalTo: toolRow.leadingAnchor),
      notice.trailingAnchor.constraint(equalTo: help.trailingAnchor),
      notice.bottomAnchor.constraint(equalTo: outputRow.topAnchor, constant: -10),
      outputRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
      outputRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
    ])
    contentView = container
  }

  private func button(_ key: String, action: Selector) -> NSButton {
    let button = NSButton(title: text(key), target: self, action: action)
    button.bezelStyle = .rounded
    button.setAccessibilityLabel(text(key))
    return button
  }

  private func refreshHistoryButtons() {
    undoButton.isEnabled = canvas.document.canUndo
    redoButton.isEnabled = canvas.document.canRedo
    canvas.needsDisplay = true
  }

  private func showOutputError() {
    statusLabel.stringValue = text("AnnotationOutputFailed")
  }

  @objc private func selectTool() {
    canvas.commitText()
    guard let tool = ScreenshotAnnotationDocument.Tool(rawValue: toolPicker.selectedSegment) else { return }
    canvas.tool = tool
    invalidateCursorRects(for: canvas)
  }

  @objc private func changeStyle() {
    canvas.commitText()
    canvas.color = colorWell.color.withAlphaComponent(1)
    canvas.lineWidth = CGFloat(widthPicker.selectedItem?.tag ?? 3)
    canvas.fontSize = CGFloat(fontPicker.selectedItem?.tag ?? 24)
  }

  @objc private func saveImage() {
    canvas.commitText()
    guard let data = canvas.document.pngData() else { showOutputError(); return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Screenshot.png"
    panel.beginSheetModal(for: self) { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      do {
        try data.write(to: url, options: .atomic)
      } catch {
        self?.showOutputError()
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
