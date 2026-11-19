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
      color: NSColor.red.withAlphaComponent(0)
    ))
    document.append(.init(
      tool: .text, points: [NSPoint(x: 40, y: 40)], color: .white, text: "Sample", fontSize: 32
    ))
    let bitmap = try bitmap(document)
    for column in stride(from: 21, through: 179, by: 4) {
      for row in stride(from: 21, through: 99, by: 4) {
        let pixel = try color(bitmap, x: column, y: 159 - row)
        #expect(pixel.redComponent < 0.001)
        #expect(pixel.greenComponent < 0.001)
        #expect(pixel.blueComponent < 0.001)
        #expect(pixel.alphaComponent > 0.999)
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
    let canvas = window.canvas
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

  @Test("The annotation toolbar, canvas, and undo actions have usable layouts without displaying a window")
  func editorControls() throws {
    let window = try editor()
    defer { window.close() }
    let content = try #require(window.contentView)
    content.layoutSubtreeIfNeeded()
    #expect(window.canvas.frame.width > 500 && window.canvas.frame.height > 200)
    #expect(window.toolPicker.segmentCount == 6)
    #expect(window.toolPicker.frame.width > 300 && window.toolPicker.frame.height > 15)
    #expect(window.undoButton.frame.width > 20 && window.undoButton.frame.height > 15)
    #expect(content.convert(window.toolPicker.bounds, from: window.toolPicker).minY >= window.canvas.frame.maxY)
    #expect(content.convert(window.redoButton.bounds, from: window.redoButton).minY >= window.canvas.frame.maxY)
    #expect(!window.undoButton.isEnabled)
    window.canvas.tool = .rectangle
    window.canvas.beginMark(at: NSPoint(x: window.canvas.bounds.midX, y: window.canvas.bounds.midY))
    window.canvas.endMark(at: NSPoint(x: window.canvas.bounds.midX + 80, y: window.canvas.bounds.midY + 40))
    #expect(window.undoButton.isEnabled)
    window.undoButton.performClick(nil)
    #expect(window.redoButton.isEnabled)
    window.redoButton.performClick(nil)
    #expect(window.canvas.document.marks.count == 1)
    let preview = try #require(NSImage(data: content.dataWithPDF(inside: content.bounds)))
    let image = try #require(preview.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let representation = NSBitmapImageRep(cgImage: image)
    try representation.representation(using: .png, properties: [:])?.write(
      to: URL(fileURLWithPath: "/private/tmp/maccy-annotation-editor-synthetic.png")
    )
    #expect(!window.isVisible)
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
