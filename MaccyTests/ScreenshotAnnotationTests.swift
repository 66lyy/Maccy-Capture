import AppKit
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct ScreenshotAnnotationTests {
  @Test("Export preserves source pixels, resolution and orientation, including Retina image sizes")
  func sourcePreservation() throws {
    let image = try fixture()
    image.size = NSSize(width: 120, height: 80)
    let document = try #require(ScreenshotAnnotationDocument(image: image))
    #expect(document.imageSize == NSSize(width: 240, height: 160))
    let bitmap = try bitmap(document)
    #expect(bitmap.pixelsWide == 240 && bitmap.pixelsHigh == 160)
    #expect(try color(bitmap, x: 10, y: 10).blueComponent > 0.9)
    #expect(try color(bitmap, x: 10, y: 150).redComponent > 0.9)
    #expect(image.size == NSSize(width: 120, height: 80))
  }

  @Test("Every annotation tool is rasterized into PNG", arguments: ScreenshotAnnotationDocument.Tool.allCases)
  func renderTools(tool: ScreenshotAnnotationDocument.Tool) throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let original = try #require(document.pngData())
    #expect(document.append(.init(
      tool: tool, points: [NSPoint(x: 30, y: 30), NSPoint(x: 160, y: 110)],
      color: .red, lineWidth: 6, text: "Value 42", fontSize: 24
    )))
    let output = try #require(document.pngData())
    #expect(output != original)
    let bitmap = try bitmap(document)
    #expect(bitmap.pixelsWide == 240 && bitmap.pixelsHigh == 160)
  }

  @Test("Solid cover is flattened, opaque, and drawn above later text regardless of color alpha")
  func opaqueRedaction() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    document.append(.init(
      tool: .redact, points: [NSPoint(x: 20.2, y: 20.2), NSPoint(x: 180.8, y: 100.8)],
      color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0)
    ))
    document.append(.init(
      tool: .text, points: [NSPoint(x: 40, y: 40)], color: .white, text: "Sample", fontSize: 32
    ))
    let bitmap = try bitmap(document)
    let fill = try color(bitmap, x: 21, y: 138)
    #expect(fill.redComponent > 0.9 && fill.greenComponent < 0.2 && fill.blueComponent < 0.2)
    #expect(fill.alphaComponent > 0.999)
    for column in stride(from: 21, through: 179, by: 4) {
      for row in stride(from: 21, through: 99, by: 4) {
        let pixel = try color(bitmap, x: column, y: 159 - row)
        #expect(pixel == fill)
      }
    }
    #expect(try color(bitmap, x: 10, y: 10).blueComponent > 0.9)
  }

  @Test("Undo, redo, and drawing after undo keep a consistent operation history")
  func operationHistory() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let mark = ScreenshotAnnotationDocument.Mark(
      tool: .rectangle, points: [NSPoint(x: 20, y: 20), NSPoint(x: 80, y: 80)]
    )
    document.append(mark)
    #expect(document.canUndo && !document.canRedo)
    document.undo()
    #expect(!document.canUndo && document.canRedo)
    document.redo()
    #expect(document.marks.count == 1)
    document.undo()
    document.append(mark)
    #expect(!document.canRedo)
    document.undo()
    document.undo()
    document.redo()
    document.redo()
    #expect(document.marks.count == 1)
  }

  @Test("Invalid input, empty text, and empty drags do not enter undo history")
  func invalidMarks() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let point = NSPoint(x: 20, y: 20)
    #expect(!document.append(.init(tool: .arrow, points: [point, point])))
    #expect(!document.append(.init(tool: .text, points: [point], text: "  \n")))
    #expect(!document.append(.init(tool: .pen, points: [])))
    #expect(!document.append(.init(tool: .redact, points: [point, NSPoint(x: CGFloat.nan, y: 10)])))
    #expect(!document.append(.init(tool: .text, points: [point], text: "Value", fontSize: .infinity)))
    #expect(!document.canUndo)
  }

  @Test("Fitted canvas maps pointer coordinates back to original pixels and ignores letterboxing")
  func canvasCoordinates() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    #expect(canvas.imagePoint(at: NSPoint(x: 400, y: 300)) == NSPoint(x: 120, y: 80))
    #expect(canvas.imagePoint(at: .zero) == nil)
    #expect(canvas.imagePoint(at: NSPoint(x: CGFloat.nan, y: 30)) == nil)
    canvas.beginMark(at: .zero)
    canvas.endMark(at: NSPoint(x: 400, y: 300))
    #expect(document.marks.isEmpty)
    canvas.beginMark(at: NSPoint(x: 400, y: 300))
    #expect(document.marks.isEmpty)
    canvas.endMark(at: NSPoint(x: 900, y: 900))
    #expect(document.marks.count == 1)
    #expect(document.marks[0].points.last == NSPoint(x: 240, y: 160))
  }

  @Test("Text input can be committed or cancelled without modifying the source image")
  func canvasText() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    canvas.tool = .text
    canvas.beginMark(at: NSPoint(x: 400, y: 300))
    let field = try #require(canvas.textField)
    field.stringValue = "Value 42"
    canvas.commitText()
    #expect(canvas.textField == nil)
    #expect(document.marks.last?.text == "Value 42")
    canvas.beginMark(at: NSPoint(x: 300, y: 250))
    canvas.textField?.stringValue = "Discard this"
    canvas.discardPendingMark()
    #expect(document.marks.count == 1)
  }

  @Test("Active native text editing is exported on completion and discarded on cancellation")
  func activeTextEditing() throws {
    let window = try editor()
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    let canvas = try #require(window.canvas)
    canvas.tool = .text
    let point = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
    canvas.beginMark(at: point)
    let field = try #require(canvas.textField)
    let textEditor = try #require(field.currentEditor() as? NSTextView)
    textEditor.string = "示例数值 42"
    canvas.commitText()
    #expect(canvas.document.marks.last?.text == "示例数值 42")
    canvas.beginMark(at: point)
    let cancelledField = try #require(canvas.textField)
    let cancelledEditor = try #require(cancelledField.currentEditor() as? NSTextView)
    cancelledEditor.string = "Discard this"
    window.cancelOperation(nil)
    #expect(canvas.textField == nil)
    #expect(canvas.document.marks.count == 1)
  }

  @Test("Editor exports through an injected destination and closes exactly once",
        arguments: [
          ScreenshotAnnotationWindow.OutputAction.copy, .pin, .apply
        ])
  func editorCompletion(action: ScreenshotAnnotationWindow.OutputAction) throws {
    let window = try editor()
    var outputs = 0
    var closes = 0
    window.onClose = { closes += 1 }
    window.onOutput = { data, image, receivedAction in
      #expect(receivedAction == action)
      #expect(NSBitmapImageRep(data: data)?.pixelsWide == 240)
      #expect(image.isValid)
      outputs += 1
    }
    window.complete(action)
    window.complete(action)
    window.close()
    #expect(outputs == 1 && closes == 1)
  }

  @Test("Cancelling an editor never invokes an output destination")
  func editorCancellation() throws {
    let window = try editor()
    var outputs = 0
    window.onOutput = { _, _, _ in outputs += 1 }
    window.canvas.document.append(.init(
      tool: .text, points: [NSPoint(x: 20, y: 20)], text: "Value"
    ))
    window.close()
    #expect(outputs == 0)
  }

  @Test("A failed export destination keeps the editor and undo history available")
  func failedDestination() throws {
    enum Failure: Error { case simulated }
    let window = try editor()
    defer { window.close() }
    var closed = false
    window.onClose = { closed = true }
    window.onOutput = { _, _, _ in throw Failure.simulated }
    window.canvas.document.append(.init(
      tool: .text, points: [NSPoint(x: 20, y: 20)], text: "Value"
    ))
    window.complete(.copy)
    #expect(!closed)
    #expect(window.canvas.document.canUndo)
  }

  @Test("Annotation stays at the captured rectangle with an attached toolbar and no editor chrome")
  func editorControls() throws {
    let window = try editor()
    defer { window.close() }
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    #expect(window.canvas.frame.width > 500 && window.canvas.frame.height > 200)
    #expect(window.toolButtons.count == 6)
    for button in window.toolButtons {
      #expect(abs(button.frame.width - window.copyButton.frame.width) <= 1)
      #expect(abs(button.frame.height - window.copyButton.frame.height) <= 1)
      #expect(button.frame.width >= 26 && button.frame.height >= 26)
    }
    #expect(window.undoButton.frame.width > 20 && window.undoButton.frame.height > 15)
    #expect(!window.styleMask.contains(.titled))
    #expect(!window.styleMask.contains(.resizable))
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(!window.isOpaque && !window.hasShadow)
    #expect(window.level == .floating)
    #expect(window.canvas.frame == NSRect(x: 160, y: 260, width: 720, height: 480))
    #expect(window.canvas.imageRect == window.canvas.bounds)
    #expect(window.annotationToolbar.frame.maxY < window.canvas.frame.minY)
    #expect(content.bounds.contains(window.annotationToolbar.frame))
    #expect(window.annotationToolbar.bounds.contains(
      window.annotationToolbar.convert(window.copyButton.bounds, from: window.copyButton)
    ))
    #expect(window.annotationToolbar.bounds.contains(
      window.annotationToolbar.convert(window.pinButton.bounds, from: window.pinButton)
    ))
    #expect(!window.undoButton.isEnabled)
    window.canvas.tool = .rectangle
    window.canvas.beginMark(at: NSPoint(x: window.canvas.bounds.midX, y: window.canvas.bounds.midY))
    window.canvas.endMark(at: NSPoint(x: window.canvas.bounds.midX + 80, y: window.canvas.bounds.midY + 40))
    #expect(window.undoButton.isEnabled)
    window.undoButton.performClick(nil)
    #expect(window.redoButton.isEnabled)
    window.redoButton.performClick(nil)
    #expect(window.canvas.document.marks.count == 1)
    let representation = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: representation)
    try representation.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/maccy-annotation-editor-synthetic.png")
    )
    #expect(!window.isVisible)
  }

  @Test("Palette changes the cover color and the contextual slider preserves both sizes")
  func paletteAndSize() throws {
    let window = try editor()
    defer { window.close() }
    let canvas = try #require(window.canvas)
    window.swatches[3].performClick(nil)
    window.toolButtons[5].performClick(nil)
    #expect(canvas.tool == .redact)
    #expect(window.swatches[3].isChosen)
    #expect(!window.styleSlider.isEnabled)
    canvas.beginMark(at: NSPoint(x: 40, y: 40))
    canvas.endMark(at: NSPoint(x: 100, y: 100))
    #expect(canvas.document.marks.last?.color == .systemGreen)

    window.toolButtons[0].performClick(nil)
    window.styleSlider.doubleValue = 15
    window.styleSlider.sendAction(window.styleSlider.action, to: window.styleSlider.target)
    #expect(canvas.lineWidth == 15)
    window.toolButtons[4].performClick(nil)
    window.styleSlider.doubleValue = 55
    window.styleSlider.sendAction(window.styleSlider.action, to: window.styleSlider.target)
    #expect(canvas.fontSize == 55)
    #expect(canvas.lineWidth == 15)
    window.toolButtons[0].performClick(nil)
    #expect(window.styleSlider.doubleValue == 15)
    window.colorWell.color = NSColor(srgbRed: 0.1, green: 0.4, blue: 0.7, alpha: 0.5)
    window.colorWell.sendAction(window.colorWell.action, to: window.colorWell.target)
    #expect(canvas.color == window.colorWell.color && canvas.color.alphaComponent == 1)
    #expect(window.swatches.allSatisfy { !$0.isChosen })
    window.toolButtons[5].performClick(nil)
    #expect(canvas.color == window.colorWell.color)
  }

  @Test("OCR results remain attached to the selection and are selectable without changing the image")
  func recognitionResults() throws {
    let window = try editor()
    defer { window.close() }
    let contents = try #require(window.contentView)
    let sample = Array(repeating: "示例文字 Sample 42", count: 40).joined(separator: "\n")
    window.showRecognizedText(sample, message: nil)
    contents.layoutSubtreeIfNeeded()
    let result = try #require(window.recognitionResults)
    #expect(result.superview === contents)
    #expect(contents.bounds.contains(result.frame))
    #expect(!result.frame.intersects(window.annotationToolbar.frame))
    #expect(result.textView.string == sample)
    #expect(result.textView.isSelectable && !result.textView.isEditable)
    #expect(result.textView.enclosingScrollView?.hasVerticalScroller == true)
    #expect(result.copyButton.isEnabled)
    window.cancelOperation(nil)
    #expect(window.recognitionResults == nil)
    #expect(window.canvas.superview === contents)
  }

  @Test("Vision recognizes small Simplified Chinese and English text in a synthetic selection")
  func recognitionOfSmallText() throws {
    let image = NSImage(size: NSSize(width: 350, height: 75), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      let style: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.black
      ]
      ("截图测试" as NSString).draw(at: NSPoint(x: 12, y: 44), withAttributes: style)
      ("SAMPLE 42" as NSString).draw(at: NSPoint(x: 12, y: 14), withAttributes: style)
      return true
    }
    let document = try #require(ScreenshotAnnotationDocument(image: image))
    let source = try #require(document.renderedImage())
    let result = try ScreenshotTextRecognition.recognize(source)
    #expect(result.contains("截图测试"))
    #expect(result.contains("SAMPLE 42"))
  }

  @Test("Extremely thin dark crops get background-colored margins and scaled content for OCR")
  func narrowCropPreprocessing() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: 52, height: 13, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 20, y: 4, width: 12, height: 5))
    let source = try #require(context.makeImage())
    let padded = try #require(ScreenshotTextRecognition.paddedNarrowImage(source))
    #expect(source.width == 52 && source.height == 13)
    #expect(padded.width == 228 && padded.height == 111)
    let bitmap = NSBitmapImageRep(cgImage: padded)
    #expect(try color(bitmap, x: 10, y: 10).redComponent < 0.02)
    #expect(try color(bitmap, x: 114, y: 55).redComponent > 0.98)
  }

  @Test("Vision reads visible Chinese and English text in a tight dark crop with clipped strokes")
  func recognitionOfTightDarkCrop() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
      data: nil, width: 128, height: 12, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    ("截图测试 SAMPLE 42" as NSString).draw(at: NSPoint(x: 0, y: -3), withAttributes: [
      .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white
    ])
    NSGraphicsContext.restoreGraphicsState()
    let image = try #require(context.makeImage())
    let result = try ScreenshotTextRecognition.recognize(image)
    #expect(result.contains("截图测试"))
    #expect(result.contains("SAMPLE"))
  }

  @Test("Vision reads synthetic text locally and does not see text behind a solid cover")
  func localRecognition() throws {
    let image = NSImage(size: NSSize(width: 640, height: 160), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      ("SAMPLE 42" as NSString).draw(at: NSPoint(x: 55, y: 45), withAttributes: [
        .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
        .foregroundColor: NSColor.black
      ])
      return true
    }
    let document = try #require(ScreenshotAnnotationDocument(image: image))
    let source = try #require(document.renderedImage())
    #expect(try ScreenshotTextRecognition.recognize(source).contains("SAMPLE 42"))
    document.append(.init(
      tool: .redact, points: [.zero, NSPoint(x: document.imageSize.width, y: document.imageSize.height)], color: .white
    ))
    let covered = try #require(document.renderedImage())
    #expect(try ScreenshotTextRecognition.recognize(covered).isEmpty)
  }

  @Test("Toolbar copy and pin export only a flattened result", arguments: [false, true])
  func inlineOutputButtons(pin: Bool) throws {
    let window = try editor()
    defer { window.close() }
    var outputs = 0
    window.canvas.document.append(.init(
      tool: .redact, points: [NSPoint(x: 20, y: 20), NSPoint(x: 100, y: 100)]
    ))
    window.onOutput = { data, _, action in
      #expect(action == (pin ? .pin : .copy))
      #expect(NSBitmapImageRep(data: data)?.pixelsWide == 240)
      outputs += 1
    }
    (pin ? window.pinButton : window.copyButton)?.performClick(nil)
    #expect(outputs == 1)
  }

  @Test("Pinned editing applies in place without creating a second pinned image")
  func inlinePinnedOutput() throws {
    let window = try #require(ScreenshotAnnotationWindow(
      image: fixture(), visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
      imageFrame: NSRect(x: 100, y: 200, width: 240, height: 160), editingPin: true
    ))
    defer { window.close() }
    var actions: [ScreenshotAnnotationWindow.OutputAction] = []
    window.onOutput = { _, _, action in actions.append(action) }
    window.pinButton.performClick(nil)
    #expect(actions == [.apply])
  }

  @Test("Toolbar stays on screen for edge, full-screen and negative-coordinate captures",
        arguments: [
          NSRect(x: 0, y: 0, width: 800, height: 600),
          NSRect(x: -1200, y: -300, width: 1200, height: 800),
          NSRect(x: 0, y: 900, width: 480, height: 800)
        ])
  func inlineToolbarPlacement(display: NSRect) {
    let size = NSSize(width: 508, height: 82)
    let rectangles = [
      display,
      NSRect(x: display.minX, y: display.minY, width: 20, height: 20),
      NSRect(x: display.maxX - 30, y: display.maxY - 30, width: 30, height: 30),
      NSRect(x: display.midX, y: display.midY, width: 100, height: 80)
    ]
    for rectangle in rectangles {
      let toolbar = ScreenshotAnnotationWindow.toolbarFrame(beside: rectangle, bounds: display, size: size)
      #expect(display.contains(toolbar))
      #expect(toolbar.width > 0 && toolbar.height > 0)
    }
  }

  @Test("Inline canvas preserves screen geometry and maps Retina pixels on an upper or left display")
  func inlineDisplayCoordinates() throws {
    let display = NSRect(x: -1200, y: 900, width: 1200, height: 800)
    let frame = NSRect(x: -1000, y: 1100, width: 360, height: 240)
    let window = try #require(ScreenshotAnnotationWindow(
      image: fixture(), visibleFrame: display.insetBy(dx: 20, dy: 20),
      screenFrame: display, imageFrame: frame, originalWasCopied: false
    ))
    defer { window.close() }
    #expect(window.frame == display)
    #expect(window.canvas.frame == NSRect(x: 200, y: 200, width: 360, height: 240))
    #expect(window.canvas.imagePoint(at: NSPoint(x: 180, y: 120)) == NSPoint(x: 120, y: 80))
  }

  @Test("Fullscreen annotation keeps its capture size instead of shrinking into an editor")
  func inlineFullScreen() throws {
    let display = NSRect(x: 0, y: 0, width: 1200, height: 800)
    let window = try #require(ScreenshotAnnotationWindow(
      image: fixture(), visibleFrame: display, imageFrame: display
    ))
    defer { window.close() }
    #expect(window.frame == display)
    #expect(window.canvas.frame == display)
    #expect(display.contains(window.annotationToolbar.frame))
  }

  @Test("Narrow displays wrap toolbar controls without hiding the copy or pin actions")
  func compactInlineToolbar() throws {
    let display = NSRect(x: 0, y: 0, width: 450, height: 800)
    let window = try #require(ScreenshotAnnotationWindow(image: fixture(), visibleFrame: display))
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    for control in [window.toolButtons[0] as NSView, window.copyButton as NSView, window.pinButton as NSView] {
      #expect(window.annotationToolbar.bounds.contains(window.annotationToolbar.convert(control.bounds, from: control)))
      #expect(control.frame.width > 20)
    }
    #expect(window.annotationToolbar.frame.height == 120)
  }

  @Test("The floating toolbar can move without moving the image or leaving the display")
  func movingInlineToolbar() throws {
    let window = try editor()
    defer { window.close() }
    let toolbar = window.annotationToolbar
    let imageFrame = window.canvas.frame
    let originalFrame = toolbar.frame
    toolbar.beginMove(at: NSPoint(x: originalFrame.midX, y: originalFrame.midY))
    toolbar.move(to: NSPoint(x: 100_000, y: 100_000))
    #expect(toolbar.movementBounds.contains(toolbar.frame))
    #expect(toolbar.frame != originalFrame)
    toolbar.move(to: NSPoint(x: -100_000, y: -100_000))
    #expect(toolbar.movementBounds.contains(toolbar.frame))
    #expect(window.canvas.frame == imageFrame)
    let lastFrame = toolbar.frame
    toolbar.move(to: NSPoint(x: CGFloat.nan, y: 0))
    #expect(toolbar.frame == lastFrame)
  }

  @Test("Screen changes cancel inline editing and discard it without invoking output")
  func inlineScreenChange() throws {
    let window = try editor()
    var closes = 0
    var outputs = 0
    window.onClose = { closes += 1 }
    window.onOutput = { _, _, _ in outputs += 1 }
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    window.complete(.copy)
    #expect(closes == 1 && outputs == 0)
  }

  @Test("Right-clicking the inline image cancels without writing any output")
  func inlineRightClickCancellation() throws {
    let window = try editor()
    var closes = 0
    var outputs = 0
    window.onClose = { closes += 1 }
    window.onOutput = { _, _, _ in outputs += 1 }
    let event = try #require(NSEvent.mouseEvent(
      with: .rightMouseDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      eventNumber: 0, clickCount: 1, pressure: 1
    ))
    window.canvas.rightMouseDown(with: event)
    #expect(closes == 1 && outputs == 0)
    #expect(window.canvas.onCancel == nil)
  }

  @Test("Inline Enter, P, and Command-C route directly to completion",
        arguments: ["\r", "p", "c"])
  func inlineKeyboardOutput(key: String) throws {
    let window = try editor()
    defer { window.close() }
    var actions: [ScreenshotAnnotationWindow.OutputAction] = []
    window.onOutput = { _, _, action in actions.append(action) }
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: key == "c" ? .command : [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: key, charactersIgnoringModifiers: key, isARepeat: false,
      keyCode: key == "\r" ? 36 : key == "p" ? 35 : 8
    ))
    if key == "c" {
      #expect(window.performKeyEquivalent(with: event))
    } else {
      window.canvas.keyDown(with: event)
    }
    #expect(actions == [key == "p" ? .pin : .copy])
  }

  @Test("A thumbnail annotation action cancels dismissal and runs its callback only once")
  func thumbnailAnnotation() throws {
    var edits = 0
    var closes = 0
    let window = ScreenshotPreviewWindow(
      image: try fixture(), visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
      onAnnotate: { edits += 1 }, onPin: {}
    )
    window.onClose = { closes += 1 }
    window.annotateImage()
    window.annotateImage()
    #expect(edits == 1 && closes == 1)
  }

  @Test("Pinned images expose annotation and accept flattened results without adding zoom buttons")
  func pinnedAnnotation() throws {
    let image = try fixture()
    let window = PinnedScreenshotWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
      anchor: NSPoint(x: 500, y: 400)
    )
    defer { window.close() }
    var edits = 0
    window.onAnnotate = { received in
      #expect(received === image)
      edits += 1
    }
    window.annotateImage()
    #expect(edits == 1)
    let originalFrame = window.frame
    let replacement = try fixture()
    window.replaceImage(replacement)
    #expect(window.image === replacement)
    #expect(abs(window.frame.width - originalFrame.width) <= 1)
    #expect(window.contentView?.subviews.compactMap { $0 as? NSButton }.count == 1)
  }

  private func editor() throws -> ScreenshotAnnotationWindow {
    try #require(ScreenshotAnnotationWindow(
      image: fixture(), visibleFrame: NSRect(x: 0, y: 0, width: 1200, height: 900),
      imageFrame: NSRect(x: 160, y: 260, width: 720, height: 480),
      originalWasCopied: false
    ))
  }

  private func bitmap(_ document: ScreenshotAnnotationDocument) throws -> NSBitmapImageRep {
    let data = try #require(document.pngData())
    return try #require(NSBitmapImageRep(data: data))
  }

  private func color(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
    try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
  }

  private func fixture() throws -> NSImage {
    let representation = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    ))
    let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
    let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
    for column in 0..<240 {
      for row in 0..<160 {
        representation.setColor(row < 20 ? blue : white, atX: column, y: row)
      }
    }
    let data = try #require(representation.representation(using: .png, properties: [:]))
    return try #require(NSImage(data: data))
  }
}
