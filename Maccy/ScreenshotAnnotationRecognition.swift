import AppKit

extension ScreenshotAnnotationWindow {
  @objc func recognizeText() {
    withCanvas { [weak self] canvas in self?.startRecognition(in: canvas) }
  }

  func startRecognition(in canvas: ScreenshotAnnotationCanvas) {
    guard recognitionTask == nil, !isFinished else { return }
    clearRecognition()
    canvas.commitText()
    let snapshot = canvas.document.renderSnapshot()
    recognitionButton.isEnabled = false
    statusLabel.stringValue = text("AnnotationRecognizingText")
    let operation = recognitionOperation
    recognitionTask = Task { [weak self] in
      let result: Result<String, Error>
      do {
        result = .success(try await TextRecognition.recognizeScreenshot(
          render: { snapshot.render() }, operation: operation
        ))
      } catch {
        result = .failure(error)
      }
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

  func clearRecognition() {
    recognitionTask?.cancel()
    recognitionTask = nil
    recognitionButton.isEnabled = true
    dismissRecognition()
  }

  var recognitionHasFocus: Bool {
    firstResponder === recognitionResults?.textView && recognitionResults != nil
  }

  @objc func dismissRecognition() {
    let hadFocus = recognitionHasFocus
    recognitionResults?.removeFromSuperview()
    recognitionResults = nil
    recognizedText = ""
    if hadFocus, !isFinished { makeFirstResponder((canvas as NSView?) ?? contentView) }
    if !isFinished { statusLabel.stringValue = shortcutSummary }
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

  func positionRecognitionResults() {
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
}

@MainActor
final class ScreenshotRecognitionResults: GlassSurfaceView {
  let textView: NSTextView
  let copyButton: NSButton

  init(title: String, value: String, copyEnabled: Bool, copyTitle: String, closeTitle: String,
       target: AnyObject, copyAction: Selector, closeAction: Selector) {
    let scroll = NSTextView.scrollableTextView()
    textView = scroll.documentView as! NSTextView
    copyButton = NSButton(title: copyTitle, target: target, action: copyAction)
    super.init(frame: .zero, cornerRadius: 14)
    setAccessibilityLabel(title)
    let heading = NSTextField(labelWithString: title)
    heading.font = .systemFont(ofSize: 13, weight: .semibold)
    let close = ScreenshotToolbarButton(frame: .zero)
    close.isBordered = false
    close.usesGlass = close.applyGlassBezel()
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
    if #available(macOS 26.0, *) {
      textView.drawsBackground = false
      scroll.drawsBackground = false
      scroll.contentView.drawsBackground = false
      copyButton.applyGlassBezel()
    }
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = true
    copyButton.isEnabled = copyEnabled
    for subview in [header as NSView, scroll, copyButton] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      controlsView.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      close.widthAnchor.constraint(equalToConstant: 24),
      close.heightAnchor.constraint(equalToConstant: 22),
      header.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor, constant: 12),
      header.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor, constant: -12),
      header.topAnchor.constraint(equalTo: controlsView.topAnchor, constant: 8),
      scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 5),
      scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      copyButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 7),
      copyButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      copyButton.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor, constant: -8)
    ])
  }

  required init?(coder: NSCoder) { nil }
}
