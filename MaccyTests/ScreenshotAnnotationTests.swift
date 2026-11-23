import AppKit
import Defaults
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct ScreenshotAnnotationTests {
  @Test("Snapshot text rendering matches the original AppKit drawing", arguments: ["Sample 42", "First line\n第二行"])
  func textRenderingParity(text: String) async throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let mark = ScreenshotAnnotationDocument.Mark(
      tool: .text, points: [CGPoint(x: 20, y: 30)], color: .red, text: text
    )
    document.append(mark)
    let snapshot = document.renderSnapshot()
    let actual = try #require(await Task.detached { snapshot.render() }.value)
    let space = try #require(document.sourceImage.colorSpace)
    let context = try #require(CGContext(
      data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.clip(to: CGRect(x: 0, y: 0, width: 240, height: 160))
    context.interpolationQuality = .high
    context.draw(document.sourceImage, in: CGRect(x: 0, y: 0, width: 240, height: 160))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    (mark.text as NSString).draw(at: mark.points[0], withAttributes: [
      .font: mark.textFont, .foregroundColor: mark.color
    ])
    NSGraphicsContext.restoreGraphicsState()
    let expected = try #require(context.makeImage())
    #expect(actual.dataProvider?.data == expected.dataProvider?.data)
  }

  @Test("Cancelling or closing OCR cancels the running operation and discards late results", arguments: [false, true])
  func recognitionCancellation(close: Bool) async throws {
    let window = try editor()
    defer { window.close() }
    let probe = SlowRecognition()
    window.recognitionOperation = { try probe.recognize($0, cancellation: $1) }
    var events = probe.events.makeAsyncIterator()
    window.startRecognition(in: window.canvas)
    let task = try #require(window.recognitionTask)
    #expect(await events.next() == 1)
    if close { window.close() } else { window.clearRecognition() }
    #expect(probe.isCancelled)
    probe.release.signal()
    await task.value
    #expect(window.recognitionResults == nil)
  }

  @Test("Restarted OCR waits for the cancelled operation to finish")
  func recognitionRestart() async throws {
    let window = try editor()
    defer { window.close() }
    let probe = SlowRecognition()
    window.recognitionOperation = { try probe.recognize($0, cancellation: $1) }
    var events = probe.events.makeAsyncIterator()
    window.startRecognition(in: window.canvas)
    let first = try #require(window.recognitionTask)
    #expect(await events.next() == 1)
    window.clearRecognition()
    #expect(probe.isCancelled)
    window.startRecognition(in: window.canvas)
    let second = try #require(window.recognitionTask)
    probe.release.signal()
    #expect(await events.next() == 2)
    await first.value
    await second.value
    #expect(probe.maximumActive == 1)
    #expect(window.recognitionResults?.textView.string == "Result 2")
  }

  @Test("Sendable render snapshots reuse unchanged pixels and encode annotated images off-main")
  func renderSnapshot() async throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let unchanged = document.renderSnapshot()
    document.append(.init(tool: .rectangle, points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 100)]))
    let annotated = document.renderSnapshot()
    let result = await Task.detached { () -> (CGImage?, CGImage?, Data?) in
      let original = unchanged.render()
      let rendered = annotated.render()
      return (original, rendered, rendered.flatMap(ScreenshotAnnotationDocument.RenderSnapshot.pngData))
    }.value
    let original = try #require(result.0)
    let rendered = try #require(result.1)
    #expect(original === document.sourceImage)
    #expect(original.width == 240 && original.height == 160)
    #expect(rendered.dataProvider?.data != original.dataProvider?.data)
    let data = try #require(result.2)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    #expect(bitmap.pixelsWide == rendered.width && bitmap.pixelsHigh == rendered.height)
    #expect(try color(bitmap, x: 20, y: 100).redComponent > 0.9)
  }

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

  @Test("Annotation, mosaic, magnification and PNG export retain the Display P3 source profile and pixels")
  func wideGamutAnnotationExport() throws {
    let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
    let context = try #require(CGContext(
      data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let green = try #require(CGColor(colorSpace: space, components: [0.2, 0.8, 0.4, 1]))
    context.setFillColor(green)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
    let source = try #require(context.makeImage())
    let document = try #require(ScreenshotAnnotationDocument(image: NSImage(cgImage: source, size: .zero)))
    #expect(document.append(.init(tool: .mosaic, points: [CGPoint(x: 4, y: 4), CGPoint(x: 20, y: 20)])))
    #expect(document.append(.init(tool: .magnifier, points: [CGPoint(x: 6, y: 6), CGPoint(x: 18, y: 18)])))
    let snapshot = document.renderSnapshot()
    let mosaic = try #require(snapshot.marks.first?.mosaic)
    let lens = try #require(ScreenshotAnnotationDocument.lensSource(snapshot.source, marks: snapshot.marks))
    let rendered = try #require(snapshot.render())
    let data = try #require(document.pngData())
    let decoded = try ScreenshotCaptureSession.ValidatedImage.validate(data).image
    let padded = try #require(TextRecognition.paddedNarrowImage(source))
    let point = CGPoint(x: 50, y: 25)
    for image in [mosaic, lens, rendered, decoded, padded] {
      let profile = try #require(image.colorSpace)
      #expect(profile.isWideGamutRGB)
      #expect(profile.copyICCData() != nil)
    }
    let original = try #require(ScreenshotPixelLoupe.sample(source, at: point))
    #expect(original.hex == "#33CC66")
    #expect(ScreenshotPixelLoupe.sample(decoded, at: point) == original)
    #expect(ScreenshotPixelLoupe.sample(mosaic, at: .zero) == original)
    #expect(ScreenshotPixelLoupe.sample(padded, at: CGPoint(x: 10, y: 10)) == original)
  }

  @Test("Every annotation tool is rasterized into PNG", arguments: ScreenshotAnnotationDocument.Tool.allCases.filter(\.drawsMark))
  func renderTools(tool: ScreenshotAnnotationDocument.Tool) throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let original = try #require(document.pngData())
    #expect(document.append(.init(
      tool: tool, points: [NSPoint(x: 30, y: 30), NSPoint(x: 160, y: 150)],
      color: .red, lineWidth: 6, text: tool == .number ? "42" : "Value 42", fontSize: 24
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

  @Test("Dragging rendered text preserves the grab offset and records one undoable move", arguments: [1.0, 2.0])
  func moveCanvasText(scale: CGFloat) throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 240 * scale, height: 160 * scale)
    canvas.imageInset = 0
    canvas.tool = .text
    canvas.color = .black
    canvas.beginMark(at: NSPoint(x: 20 * scale, y: 20 * scale))
    canvas.textField?.stringValue = "Sample"
    canvas.commitText()
    let origin = try #require(document.marks.first?.points.first)
    let before = try bitmap(document)
    var paintedPoint: NSPoint?
    for row in 75..<155 {
      for column in 0..<120 where try color(before, x: column, y: row).redComponent < 0.1 {
        paintedPoint = NSPoint(x: CGFloat(column) + 0.5, y: 160 - CGFloat(row) - 0.5)
        break
      }
      if paintedPoint != nil { break }
    }
    let pixel = try #require(paintedPoint)
    let start = NSPoint(x: pixel.x * scale, y: pixel.y * scale)
    canvas.beginMark(at: start)
    #expect(canvas.isMovingText && canvas.textField == nil)
    canvas.updateMark(to: NSPoint(x: start.x + 12 * scale, y: start.y + 8 * scale))
    #expect(document.marks.first?.points.first == origin)
    canvas.endMark(at: NSPoint(x: start.x + 40 * scale, y: start.y + 40 * scale))
    let destination = NSPoint(x: origin.x + 40, y: origin.y + 40)
    #expect(document.marks.count == 1 && document.marks.first?.points.first == destination)
    let after = try bitmap(document)
    #expect(try color(after, x: Int(pixel.x), y: 159 - Int(pixel.y)).redComponent > 0.9)
    #expect(try color(after, x: Int(pixel.x) + 40, y: 119 - Int(pixel.y)).redComponent < 0.1)
    document.undo()
    #expect(document.marks.first?.points.first == origin)
    document.undo()
    #expect(document.marks.isEmpty)
    document.redo()
    document.redo()
    #expect(document.marks.first?.points.first == destination)
  }

  @Test("Text marks resize from their corner handles and the size slider, one undo step per change")
  func resizeText() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
    canvas.imageInset = 0
    canvas.tool = .text
    canvas.fontSize = 24
    canvas.beginMark(at: NSPoint(x: 40, y: 40))
    canvas.fontSize = 120
    let large = try #require(canvas.textField?.font)
    #expect((canvas.textField?.frame.height ?? 0) >= ceil(large.ascender - large.descender + large.leading))
    #expect(canvas.textField?.frame.minY == 40)
    canvas.fontSize = 36
    #expect(canvas.textField?.font?.pointSize == 36)
    canvas.textField?.stringValue = "Size"
    canvas.commitText()
    let original = try #require(document.marks.first)
    #expect(original.fontSize == 18 && canvas.selectedMarkSize(for: .text) == 36)
    #expect(original.handlePoints.count == 4)

    let box = original.bounds
    let corner = NSPoint(x: box.maxX * 2, y: box.maxY * 2)
    canvas.beginMark(at: corner)
    #expect(canvas.isMovingMark)
    let revision = document.revision
    for step in 1..<32 {
      let fraction = CGFloat(step) / 32
      canvas.updateMark(to: NSPoint(x: corner.x + box.width * fraction * 2, y: corner.y + box.height * fraction * 2))
    }
    #expect(document.revision == revision)
    canvas.endMark(at: NSPoint(x: corner.x + box.width * 2, y: corner.y + box.height * 2))
    #expect(document.revision == revision + 1)
    let grown = try #require(document.marks.first)
    #expect(abs(grown.fontSize - 36) < 0.01)
    #expect(grown.bounds.origin == box.origin)
    #expect(grown.bounds.width > box.width * 1.9)
    #expect(canvas.selectedMarkIndex == 0)

    #expect(canvas.resizeSelectedMark(to: 40, as: .text))
    #expect(canvas.resizeSelectedMark(to: 50, as: .text))
    canvas.endStyleResize()
    #expect(canvas.resizeSelectedMark(to: 30, as: .text))
    #expect(document.marks.first?.fontSize == 15 && canvas.selectedMarkSize(for: .text) == 30)
    document.undo()
    #expect(document.marks.first?.fontSize == 25)
    document.undo()
    #expect(abs((document.marks.first?.fontSize ?? 0) - 36) < 0.01)
    document.undo()
    #expect(document.marks.first?.fontSize == 18 && document.marks.first?.points == original.points)
    document.redo()
    document.redo()
    #expect(document.marks.first?.fontSize == 25)

    #expect(!document.restyleMark(at: 0, size: .nan))
    #expect(document.restyleMark(at: 0, size: 0.5) && document.marks.first?.fontSize == 4)
    canvas.tool = .arrow
    canvas.beginMark(at: NSPoint(x: 400, y: 300))
    canvas.endMark(at: NSPoint(x: 420, y: 310))
    #expect(!canvas.resizeSelectedMark(to: 60, as: .text))
    #expect(canvas.selectedMarkSize(for: .text) == nil && canvas.selectedMarkSize(for: .rectangle) != nil)
  }

  @Test("Committed text keeps the position the field editor drew it at")
  func committedTextKeepsTypedPosition() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = canvas
    canvas.imageInset = 0
    canvas.tool = .text
    canvas.fontSize = 24
    canvas.beginMark(at: NSPoint(x: 40, y: 40))
    let field = try #require(canvas.textField)
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("gyp", replacementRange: NSRange(location: NSNotFound, length: 0))
    let layout = try #require(editor.layoutManager)
    let line = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
    let glyph = canvas.convert(NSRect(
      x: line.minX + layout.location(forGlyphAt: 0).x + editor.textContainerOrigin.x,
      y: line.minY + editor.textContainerOrigin.y, width: 0, height: line.height
    ), from: editor)
    canvas.commitText()
    let mark = try #require(document.marks.first)
    #expect(mark.text == "gyp")
    #expect(abs(mark.points[0].x - glyph.minX) < 0.5 && abs(mark.points[0].y - glyph.minY) < 0.5)
    #expect(mark.points[0].x > field.frame.minX)
  }

  @Test("Numbered markers and pen strokes resize from their corner handles")
  func resizeMarkerAndPen() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let number = ScreenshotAnnotationDocument.Mark(tool: .number, points: [NSPoint(x: 50, y: 50)], text: "1", fontSize: 20)
    let box = number.bounds
    #expect(number.handlePoints.count == 4)
    let grown = number.resized(handle: 2, to: NSPoint(x: box.minX + box.width * 2, y: box.minY + box.height * 2))
    #expect(abs(grown.fontSize - 40) < 0.01)
    #expect(abs(grown.bounds.minX - box.minX) < 0.01 && abs(grown.bounds.minY - box.minY) < 0.01)
    let shrunk = number.resized(handle: 0, to: NSPoint(x: box.midX, y: box.midY))
    #expect(abs(shrunk.fontSize - 10) < 0.01)
    #expect(abs(shrunk.bounds.maxX - box.maxX) < 0.01 && abs(shrunk.bounds.maxY - box.maxY) < 0.01)

    let pen = ScreenshotAnnotationDocument.Mark(
      tool: .pen, points: [NSPoint(x: 10, y: 10), NSPoint(x: 20, y: 30), NSPoint(x: 30, y: 20)]
    )
    #expect(pen.handlePoints.count == 4)
    let stretched = pen.resized(handle: 2, to: NSPoint(x: 50, y: 50))
    #expect(stretched.points == [NSPoint(x: 10, y: 10), NSPoint(x: 30, y: 50), NSPoint(x: 50, y: 30)])
    #expect(stretched.lineWidth == pen.lineWidth)

    #expect(document.append(pen))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    canvas.imageInset = 0
    canvas.tool = .arrow
    canvas.beginMark(at: NSPoint(x: 20, y: 30))
    canvas.endMark(at: NSPoint(x: 20, y: 30))
    #expect(canvas.selectedMarkIndex == 0)
    canvas.beginMark(at: NSPoint(x: 30, y: 30))
    #expect(canvas.isMovingMark)
    canvas.endMark(at: NSPoint(x: 50, y: 50))
    #expect(document.marks.first?.points == stretched.points)
    document.undo()
    #expect(document.marks.first?.points == pen.points)
  }

  @Test("The size slider resizes the selected mark of its kind in one undo step per drag")
  func sliderResizesSelectedMark() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let rectangle = ScreenshotAnnotationDocument.Mark(
      tool: .rectangle, points: [NSPoint(x: 20, y: 20), NSPoint(x: 80, y: 60)], lineWidth: 3
    )
    let mosaic = ScreenshotAnnotationDocument.Mark(
      tool: .mosaic, points: [NSPoint(x: 100, y: 20), NSPoint(x: 160, y: 60)], lineWidth: 8
    )
    let lens = ScreenshotAnnotationDocument.Mark(
      tool: .magnifier, points: [NSPoint(x: 100, y: 80), NSPoint(x: 160, y: 140)], lineWidth: 3, zoom: 2
    )
    #expect(document.append(rectangle) && document.append(mosaic) && document.append(lens))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    canvas.imageInset = 0
    canvas.tool = .arrow

    canvas.beginMark(at: NSPoint(x: 20, y: 40))
    canvas.endMark(at: NSPoint(x: 20, y: 40))
    #expect(canvas.selectedMarkIndex == 0 && canvas.selectedMarkSize(for: .ellipse) == 3)
    #expect(!canvas.resizeSelectedMark(to: 20, as: .mosaic))
    #expect(canvas.resizeSelectedMark(to: 8, as: .arrow) && canvas.resizeSelectedMark(to: 10, as: .arrow))
    #expect(document.marks[0].lineWidth == 10 && document.marks[0].points == rectangle.points)
    document.undo()
    #expect(document.marks[0].lineWidth == 3)
    document.redo()

    canvas.endStyleResize()
    canvas.beginMark(at: NSPoint(x: 130, y: 40))
    canvas.endMark(at: NSPoint(x: 130, y: 40))
    #expect(canvas.selectedMarkIndex == 1 && canvas.selectedMarkSize(for: .mosaic) == 8)
    let before = try #require(document.marks[1].mosaic)
    #expect(canvas.resizeSelectedMark(to: 20, as: .mosaic))
    #expect(document.marks[1].lineWidth == 20)
    #expect(document.marks[1].mosaic.map { $0 !== before } == true)

    canvas.endStyleResize()
    canvas.beginMark(at: NSPoint(x: 101, y: 110))
    canvas.endMark(at: NSPoint(x: 101, y: 110))
    #expect(canvas.selectedMarkIndex == 2 && canvas.selectedMarkSize(for: .magnifier) == 2)
    #expect(canvas.resizeSelectedMark(to: 5, as: .magnifier))
    #expect(document.marks[2].zoom == 5 && document.marks[2].lineWidth == 3)
    #expect(!document.restyleMark(at: 2, size: 5))
  }

  @Test("Text moving respects covers and can be cancelled without closing the editor")
  func cancelTextMove() throws {
    let window = try editor()
    defer { window.close() }
    let canvas = try #require(window.canvas)
    canvas.tool = .text
    let origin = NSPoint(x: 40, y: 40)
    let document = canvas.document
    document.append(.init(tool: .text, points: [origin], text: "Bottom"))
    document.append(.init(tool: .text, points: [origin], text: "Top"))
    document.append(.init(tool: .redact, points: [origin, NSPoint(x: 95, y: 65)]))
    let covered = NSPoint(x: 45, y: 45)
    #expect(document.textMarkIndex(at: covered, padding: 0) == nil)
    document.undo()
    #expect(document.textMarkIndex(at: covered, padding: 0) == 1)

    let start = NSPoint(x: 135, y: 135)
    canvas.beginMark(at: start)
    #expect(canvas.isMovingText)
    canvas.updateMark(to: NSPoint(x: 200, y: 200))
    window.cancelOperation(nil)
    #expect(!canvas.isMovingText && document.marks.last?.points.first == origin && document.canRedo)
    canvas.beginMark(at: start)
    canvas.endMark(at: start)
    #expect(document.canRedo)
    canvas.beginMark(at: start)
    canvas.endMark(at: NSPoint(x: -10, y: -10))
    #expect(document.marks.first?.points.first == origin)
    #expect(document.marks.last?.points.first == .zero && !document.canRedo)
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
    canvas.beginMark(at: NSPoint(x: point.x, y: point.y + 60))
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
  func editorCompletion(action: ScreenshotAnnotationWindow.OutputAction) async throws {
    let window = try editor()
    var outputs = 0
    var closes = 0
    window.onClose = { closes += 1 }
    window.onOutput = { data, image, receivedAction in
      #expect(receivedAction == action)
      if action == .apply {
        #expect(data == nil)
      } else {
        let data = try #require(data)
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 240)
      }
      #expect(image.isValid)
      outputs += 1
    }
    window.complete(action)
    window.complete(action)
    await window.exportTask?.value
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
  func failedDestination() async throws {
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
    await window.exportTask?.value
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
    #expect(window.toolButtons.count == ScreenshotAnnotationDocument.Tool.allCases.count)
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
    window.toolButtons[7].performClick(nil)
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
    window.styleSlider.doubleValue = 67
    window.styleSlider.sendAction(window.styleSlider.action, to: window.styleSlider.target)
    canvas.beginMark(at: NSPoint(x: 300, y: 200))
    canvas.textField?.stringValue = "Size"
    canvas.commitText()
    #expect(canvas.resizeSelectedMark(to: 45, as: .text))
    canvas.endStyleResize()
    #expect(window.styleSlider.doubleValue == 45 && canvas.fontSize == 67)
    let markCount = canvas.document.marks.count
    canvas.needsDisplay = false
    canvas.beginMark(at: NSPoint(x: 600, y: 400))
    #expect(canvas.selectedMarkIndex == nil)
    #expect(canvas.needsDisplay)
    #expect(window.styleSlider.doubleValue == 67 && window.styleValue.stringValue == "67")
    #expect(canvas.textField?.font?.pointSize == 67)
    canvas.commitText()
    #expect(canvas.document.marks.count == markCount)
    window.toolButtons[0].performClick(nil)
    #expect(window.styleSlider.doubleValue == 15)
    window.colorWell.color = NSColor(srgbRed: 0.1, green: 0.4, blue: 0.7, alpha: 0.5)
    window.colorWell.sendAction(window.colorWell.action, to: window.colorWell.target)
    #expect(canvas.color == window.colorWell.color && canvas.color.alphaComponent == 1)
    #expect(window.swatches.allSatisfy { !$0.isChosen })
    window.toolButtons[7].performClick(nil)
    #expect(canvas.color == window.colorWell.color)
  }

  @Test("Numbered markers count up, keep their numbers after removal and render as filled circles")
  func numberMarkers() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    canvas.imageInset = 0
    canvas.tool = .number
    canvas.color = .red
    canvas.fontSize = 24
    for x in [40.0, 100.0, 160.0] {
      canvas.beginMark(at: NSPoint(x: x, y: 80))
      canvas.endMark(at: NSPoint(x: x, y: 80))
    }
    #expect(document.marks.map(\.text) == ["1", "2", "3"])
    #expect(document.removeMarks(at: [0]))
    #expect(document.marks.map(\.text) == ["2", "3"] && document.nextNumber == 4)
    document.undo()
    document.undo()
    #expect(document.marks.map(\.text) == ["1", "2"] && document.nextNumber == 3)
    let image = try bitmap(document)
    let fill = try color(image, x: 40 + 15, y: 79)
    #expect(fill.redComponent > 0.9 && fill.greenComponent < 0.2 && fill.blueComponent < 0.2)
    #expect(document.markIndex(at: NSPoint(x: 100, y: 95), tolerance: 0) == 1)
  }

  @Test("The magnifier enlarges the original screenshot inside its lens")
  func magnifier() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let before = try bitmap(document)
    document.append(.init(tool: .text, points: [NSPoint(x: 100, y: 70)], color: .black, text: "Mark"))
    let lens = NSRect(x: 60, y: 30, width: 100, height: 100)
    #expect(document.append(.init(
      tool: .magnifier, points: [lens.origin, NSPoint(x: lens.maxX, y: lens.maxY)], lineWidth: 2, zoom: 3
    )))
    let after = try bitmap(document)
    var compared = 0
    for y in stride(from: 50, through: 110, by: 6) {
      for x in stride(from: 80, through: 140, by: 6) {
        let sourceX = Int((lens.midX + (CGFloat(x) + 0.5 - lens.midX) / 3).rounded(.down))
        let sourceY = Int((lens.midY + (CGFloat(y) + 0.5 - lens.midY) / 3).rounded(.down))
        let expected = try color(before, x: sourceX, y: 159 - sourceY)
        let neighbors = try [(-1, 0), (1, 0), (0, -1), (0, 1)].map { try color(before, x: sourceX + $0.0, y: 159 - sourceY + $0.1) }
        guard neighbors.allSatisfy({ abs($0.blueComponent - expected.blueComponent) < 0.01 && abs($0.redComponent - expected.redComponent) < 0.01 }) else { continue }
        let actual = try color(after, x: x, y: 159 - y)
        #expect(abs(actual.redComponent - expected.redComponent) < 0.1 && abs(actual.blueComponent - expected.blueComponent) < 0.1)
        compared += 1
      }
    }
    #expect(compared > 20)
    #expect(document.markIndex(at: NSPoint(x: lens.midX, y: lens.midY), tolerance: 0) == 1)
    document.undo()
    #expect(document.marks.count == 1)
  }

  @Test("The magnifier enlarges the mosaic, not the content it hides", arguments: [false, true])
  func magnifierRespectsMosaic(mosaicAfterLens: Bool) throws {
    let image = NSImage(size: NSSize(width: 240, height: 160), flipped: false) { rect in
      NSColor.white.setFill()
      rect.fill()
      NSColor.black.setFill()
      NSRect(x: 111, y: 87, width: 7, height: 7).fill()
      return true
    }
    let magnifier = ScreenshotAnnotationDocument.Mark(
      tool: .magnifier, points: [NSPoint(x: 60, y: 30), NSPoint(x: 160, y: 130)], lineWidth: 2, zoom: 3
    )
    let mosaic = ScreenshotAnnotationDocument.Mark(
      tool: .mosaic, points: [NSPoint(x: 104, y: 80), NSPoint(x: 144, y: 100)], lineWidth: 20
    )
    func document(covered: Bool) throws -> ScreenshotAnnotationDocument {
      let document = try #require(ScreenshotAnnotationDocument(image: image))
      if covered && !mosaicAfterLens { #expect(document.append(mosaic)) }
      #expect(document.append(magnifier))
      if covered && mosaicAfterLens { #expect(document.append(mosaic)) }
      return document
    }
    func magnifiedSample(_ bitmap: NSBitmapImageRep) throws -> CGFloat {
      // The lens maps (114, 90) to (122, 110), outside the mosaic's unzoomed bounds.
      try color(bitmap, x: 122, y: 159 - 110).redComponent
    }
    func canvasBitmap(_ document: ScreenshotAnnotationDocument) throws -> NSBitmapImageRep {
      let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      ))
      let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
      document.draw(in: context)
      return bitmap
    }
    let uncovered = try document(covered: false)
    #expect(try magnifiedSample(bitmap(uncovered)) < 0.1)
    #expect(try magnifiedSample(canvasBitmap(uncovered)) < 0.1)
    let covered = try document(covered: true)
    #expect(try magnifiedSample(bitmap(covered)) > 0.6)
    #expect(try magnifiedSample(canvasBitmap(covered)) > 0.6)
  }

  @Test("Redraws reuse the magnifier's covered image and the preview mosaic until they change")
  func lensAndMosaicCaches() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    #expect(document.append(.init(tool: .mosaic, points: [NSPoint(x: 90, y: 60), NSPoint(x: 170, y: 105)], lineWidth: 20)))
    #expect(document.append(.init(tool: .magnifier, points: [NSPoint(x: 60, y: 30), NSPoint(x: 160, y: 130)], zoom: 3)))
    let context = try #require(CGContext(
      data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    document.draw(in: context)
    document.draw(in: context)
    #expect(document.lensSourceRenders == 1)
    let preview = ScreenshotAnnotationDocument.Mark(
      tool: .mosaic, points: [NSPoint(x: 10, y: 10), NSPoint(x: 50, y: 50)], lineWidth: 10
    )
    document.draw(in: context, preview: preview)
    document.draw(in: context, preview: preview)
    #expect(document.previewMosaicRenders == 1)
    #expect(document.lensSourceRenders == 2)
    var grown = preview
    grown.points[1] = NSPoint(x: 60, y: 60)
    document.draw(in: context, preview: grown)
    #expect(document.previewMosaicRenders == 2)
    #expect(document.lensSourceRenders == 3)
    #expect(document.append(.init(tool: .redact, points: [NSPoint(x: 100, y: 70), NSPoint(x: 120, y: 90)])))
    document.draw(in: context)
    document.draw(in: context)
    #expect(document.lensSourceRenders == 4)
  }

  @Test("A finished mark is selected and can be moved, resized and deleted with one undo step each")
  func moveAndResizeMarks() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    canvas.imageInset = 0
    canvas.tool = .rectangle
    canvas.beginMark(at: NSPoint(x: 40, y: 40))
    canvas.updateMark(to: NSPoint(x: 100, y: 100))
    canvas.endMark(at: NSPoint(x: 100, y: 100))
    #expect(canvas.selectedMarkIndex == 0)
    let original = NSRect(x: 40, y: 40, width: 60, height: 60)
    #expect(document.marks.first?.shapeBounds == original)

    canvas.beginMark(at: NSPoint(x: 40, y: 70))
    #expect(canvas.isMovingMark)
    canvas.updateMark(to: NSPoint(x: 50, y: 75))
    #expect(document.marks.first?.shapeBounds == original)
    canvas.endMark(at: NSPoint(x: 60, y: 90))
    let moved = NSRect(x: 60, y: 60, width: 60, height: 60)
    #expect(document.marks.count == 1 && document.marks.first?.shapeBounds == moved)

    canvas.beginMark(at: NSPoint(x: 120, y: 120))
    canvas.updateMark(to: NSPoint(x: 150, y: 140))
    canvas.endMark(at: NSPoint(x: 150, y: 140))
    let resized = NSRect(x: 60, y: 60, width: 90, height: 80)
    #expect(document.marks.first?.shapeBounds == resized)

    canvas.beginMark(at: NSPoint(x: 150, y: 100))
    canvas.endMark(at: NSPoint(x: 400, y: 100))
    #expect(document.marks.first?.shapeBounds.maxX == 240)
    document.undo()
    #expect(document.marks.first?.shapeBounds == resized)
    document.undo()
    #expect(document.marks.first?.shapeBounds == moved)
    document.undo()
    #expect(document.marks.first?.shapeBounds == original)
    document.redo()
    #expect(document.marks.first?.shapeBounds == moved)

    canvas.beginMark(at: NSPoint(x: 60, y: 90))
    canvas.endMark(at: NSPoint(x: 60, y: 90))
    #expect(canvas.selectedMarkIndex == 0 && canvas.deleteSelectedMark())
    #expect(document.marks.isEmpty && canvas.selectedMarkIndex == nil)
    document.undo()
    #expect(document.marks.first?.shapeBounds == moved)

    canvas.tool = .arrow
    canvas.beginMark(at: NSPoint(x: 10, y: 10))
    canvas.endMark(at: NSPoint(x: 30, y: 20))
    canvas.beginMark(at: NSPoint(x: 30, y: 20))
    canvas.endMark(at: NSPoint(x: 35, y: 50))
    #expect(document.marks.last?.points == [NSPoint(x: 10, y: 10), NSPoint(x: 35, y: 50)])
  }

  @Test("A handle drag records one edit, and returning to the start records none",
        arguments: [ScreenshotAnnotationDocument.Tool.arrow, .rectangle])
  func resizeGestureHistory(tool: ScreenshotAnnotationDocument.Tool) throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.frame = NSRect(x: 0, y: 0, width: 240, height: 160)
    canvas.imageInset = 0
    let start = NSPoint(x: 100.25, y: 100.25)
    let original = [NSPoint(x: 40.25, y: 40.25), start]
    #expect(document.append(.init(tool: tool, points: original)))
    canvas.beginMark(at: start)
    canvas.endMark(at: start)
    #expect(canvas.selectedMarkIndex == 0)

    let revision = document.revision
    canvas.beginMark(at: start)
    for step in 1...20 {
      canvas.updateMark(to: NSPoint(x: start.x + CGFloat(step), y: start.y + CGFloat(step) / 2))
    }
    #expect(document.revision == revision && document.marks.first?.points == original)
    canvas.endMark(at: NSPoint(x: 120.25, y: 110.25))
    let resized = [original[0], NSPoint(x: 120, y: 110)]
    #expect(document.revision == revision + 1 && document.marks.first?.points == resized)

    canvas.beginMark(at: resized[1])
    canvas.updateMark(to: NSPoint(x: 140, y: 120))
    canvas.endMark(at: resized[1])
    #expect(document.revision == revision + 1)
    #expect(document.marks.first?.points == resized)
    document.undo()
    #expect(document.marks.first?.points == original)
    document.undo()
    #expect(document.marks.isEmpty && !document.canUndo)
  }

  @Test("Fine moves and resizes stay on source pixels at Retina and fractional canvas scales")
  func markGesturePixelAlignment() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    let canvas = ScreenshotAnnotationCanvas(document: document)
    canvas.imageInset = 0
    let original = [NSPoint(x: 40, y: 40), NSPoint(x: 100, y: 100)]
    #expect(document.append(.init(tool: .rectangle, points: original)))
    var expected = original
    let scales: [CGFloat] = [0.5, 0.7, 2, 0.5]
    for scale in scales {
      canvas.frame = NSRect(x: 0, y: 0, width: 240 * scale, height: 160 * scale)
      func viewPoint(_ point: NSPoint) -> NSPoint {
        NSPoint(x: canvas.imageRect.minX + point.x * scale, y: canvas.imageRect.minY + point.y * scale)
      }

      let grab = NSPoint(x: expected[0].x, y: (expected[0].y + expected[1].y) / 2)
      canvas.beginMark(at: viewPoint(grab))
      for step in 1..<64 {
        let fraction = CGFloat(step) / 64
        canvas.updateMark(to: viewPoint(NSPoint(x: grab.x + 7.3 * fraction, y: grab.y - 4.2 * fraction)))
      }
      canvas.endMark(at: viewPoint(NSPoint(x: grab.x + 7.3, y: grab.y - 4.2)))
      expected = expected.map { NSPoint(x: $0.x + 7, y: $0.y - 4) }
      #expect(document.marks.first?.points == expected)

      let corner = expected[1]
      canvas.beginMark(at: viewPoint(corner))
      for step in 1..<64 {
        let fraction = CGFloat(step) / 64
        canvas.updateMark(to: viewPoint(NSPoint(x: corner.x + 13.2 * fraction, y: corner.y + 9.3 * fraction)))
      }
      canvas.endMark(at: viewPoint(NSPoint(x: corner.x + 13.2, y: corner.y + 9.3)))
      expected[1] = NSPoint(x: corner.x + 13, y: corner.y + 9)
      #expect(document.marks.first?.points == expected)

      let revision = document.revision
      canvas.beginMark(at: viewPoint(expected[1]))
      canvas.endMark(at: viewPoint(NSPoint(x: expected[1].x + 0.25, y: expected[1].y - 0.25)))
      #expect(document.revision == revision && document.marks.first?.points == expected)
    }
  }

  @Test("Moving a mosaic re-pixelates the screenshot at its new position")
  func moveMosaic() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    #expect(document.append(.init(tool: .mosaic, points: [NSPoint(x: 10, y: 10), NSPoint(x: 70, y: 70)], lineWidth: 10)))
    let mark = try #require(document.marks.first)
    #expect(document.replaceMark(at: 0, with: mark.moved(by: 100, 50, within: document.imageSize)))
    let moved = try #require(document.marks.first)
    #expect(moved.shapeBounds == NSRect(x: 110, y: 60, width: 60, height: 60) && moved.mosaic != nil)
    #expect(moved.mosaic.map { $0.width } == 6)
  }

  @Test("Toolbar tools follow the saved order, append new tools and keep at least one visible")
  func toolbarToolOrder() {
    typealias Tool = ScreenshotAnnotationDocument.Tool
    let tools = Tool.toolbarTools(order: [Tool.eraser.rawValue, Tool.arrow.rawValue, 99], disabled: [Tool.pen.rawValue])
    #expect(Array(tools.prefix(3)) == [.eraser, .arrow, .rectangle])
    #expect(!tools.contains(.pen) && tools.count == Tool.allCases.count - 1)
    #expect(Tool.toolbarTools(order: [], disabled: Tool.allCases.map(\.rawValue)) == [.arrow])
    #expect(Tool.toolbarTools(order: [], disabled: []) == Tool.allCases)
  }

  @Test("Annotation tool drops reorder rows and reject invalid payloads")
  func reorderToolbarTools() throws {
    typealias Tool = ScreenshotAnnotationDocument.Tool
    let order = Tool.allCases.map(\.rawValue)
    let payload = ["annotation-tool:\(Tool.magnifier.rawValue)"]
    let moved = try #require(AnnotationToolSettings.reorderedTools(payload, before: .arrow, order: order))
    #expect(moved.first == Tool.magnifier.rawValue && Set(moved) == Set(order))
    let last = try #require(AnnotationToolSettings.reorderedTools(payload, before: nil, order: moved))
    #expect(last.last == Tool.magnifier.rawValue && last.count == order.count)
    #expect(AnnotationToolSettings.reorderedTools([], before: .arrow, order: order) == nil)
    #expect(AnnotationToolSettings.reorderedTools(["annotation-tool:99"], before: .arrow, order: order) == nil)
    #expect(AnnotationToolSettings.reorderedTools(["unrelated"], before: .arrow, order: order) == nil)
    #expect(AnnotationToolSettings.reorderedTools(payload, before: .magnifier, order: order) == nil)
  }

  @Test("Annotation row gestures convert vertical travel into clamped insertion positions")
  func gestureToolbarOrder() throws {
    typealias Tool = ScreenshotAnnotationDocument.Tool
    let order = Tool.allCases.map(\.rawValue)
    let moved = try #require(AnnotationToolSettings.reorderedTools(.arrow, translation: 56, order: order))
    #expect(Array(moved.prefix(3)) == [Tool.rectangle.rawValue, Tool.ellipse.rawValue, Tool.arrow.rawValue])
    #expect(Set(moved) == Set(order) && moved.count == order.count)
    let first = try #require(AnnotationToolSettings.reorderedTools(.magnifier, translation: -10000, order: moved))
    #expect(first.first == Tool.magnifier.rawValue)
    let last = try #require(AnnotationToolSettings.reorderedTools(.magnifier, translation: 10000, order: first))
    #expect(last.last == Tool.magnifier.rawValue)
    #expect(AnnotationToolSettings.reorderedTools(.arrow, translation: 0, order: order) == nil)
    #expect(AnnotationToolSettings.reorderedTools(.arrow, translation: 10, order: order) == nil)
    #expect(AnnotationToolSettings.reorderedTools(.arrow, translation: .nan, order: order) == nil)
    #expect(AnnotationToolSettings.reorderedTools(.arrow, translation: .infinity, order: order) == nil)
    let defaultOrder = try #require(AnnotationToolSettings.reorderedTools(.arrow, translation: 28, order: []))
    #expect(Array(defaultOrder.prefix(2)) == [Tool.rectangle.rawValue, Tool.arrow.rawValue])
  }

  @Test("Programmatic tool selection falls back to the first enabled tool in saved order")
  func enabledToolSelection() throws {
    typealias Tool = ScreenshotAnnotationDocument.Tool
    let originalOrder = Defaults[.annotationToolOrder]
    let originalDisabled = Defaults[.disabledAnnotationTools]
    defer {
      Defaults[.annotationToolOrder] = originalOrder
      Defaults[.disabledAnnotationTools] = originalDisabled
    }
    Defaults[.annotationToolOrder] = [Tool.magnifier.rawValue, Tool.number.rawValue]
    Defaults[.disabledAnnotationTools] = [Tool.arrow.rawValue]
    let window = try editor()
    defer { window.close() }
    window.chooseTool(.arrow)
    #expect(window.selectedTool == .magnifier && window.canvas?.tool == .magnifier)
    window.chooseTool(.number)
    #expect(window.selectedTool == .number && window.canvas?.tool == .number)
    Defaults[.disabledAnnotationTools] = Tool.allCases.map(\.rawValue)
    window.chooseTool(.arrow)
    #expect(window.selectedTool == .magnifier)
    Defaults[.annotationToolOrder] = []
    Defaults[.disabledAnnotationTools] = []
    window.chooseTool(.arrow)
    #expect(window.selectedTool == .arrow)
  }

  @Test("Toolbar items keep their saved order within each row and skip switched-off items")
  func toolbarItemOrder() throws {
    typealias Item = ScreenshotToolbarItem
    #expect(Item.items(in: .output, order: [], disabled: []) == [.longScreenshot, .recognizeText, .pin, .save, .copy, .cancel])
    #expect(Array(Item.items(in: .output, order: ["copy", "undo", "bogus"], disabled: ["save"]).prefix(2)) == [.copy, .longScreenshot])
    #expect(!Item.items(in: .output, order: [], disabled: ["save"]).contains(.save))
    #expect(Item.items(in: .history, order: [], disabled: ["undo", "redo"]).isEmpty)
    let moved = try #require(AnnotationToolSettings.reorderedItems(.copy, translation: -10000, order: []))
    #expect(Item.items(in: .output, order: moved, disabled: []).first == .copy)
    #expect(Item.items(in: .history, order: moved, disabled: []) == [.undo, .redo])
    #expect(AnnotationToolSettings.reorderedItems(.copy, translation: 5, order: []) == nil)

    let originalOrder = Defaults[.toolbarItemOrder], originalDisabled = Defaults[.disabledToolbarItems]
    defer {
      Defaults[.toolbarItemOrder] = originalOrder
      Defaults[.disabledToolbarItems] = originalDisabled
    }
    Defaults[.disabledToolbarItems] = ["copy", "undo", "size"]
    let window = try editor()
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.copyButton.window == nil && window.undoButton.window == nil && window.styleSlider.window == nil)
    #expect(window.pinButton.window === window && window.redoButton.window === window && window.colorWell.window === window)
  }

  @Test("Style rows preserve saved order even when split and omit disabled controls")
  func toolbarStyleRows() {
    typealias Item = ScreenshotToolbarItem
    let order = ["palette", "size", "customColor"]
    #expect(Item.styleRows(order: order, disabled: [], narrow: false) == [[.palette, .size, .customColor]])
    #expect(Item.styleRows(order: order, disabled: [], narrow: true).flatMap { $0 } == [.palette, .size, .customColor])
    #expect(Item.styleRows(order: order, disabled: ["size"], narrow: true) == [[.palette, .customColor]])
    #expect(Item.styleRows(order: [], disabled: ["palette", "size", "customColor"], narrow: true).isEmpty)
    #expect(Item.styleRows(order: ["bogus", "size", "size"], disabled: [], narrow: false) == [[.size, .palette, .customColor]])
  }

  @Test("Row-center drag distances select the destination row")
  func toolbarReorderDistances() throws {
    let pitch = AnnotationToolSettings.rowHeight
    let moved = try #require(AnnotationToolSettings.reorderedItems(.save, translation: -2 * pitch, order: []))
    #expect(ScreenshotToolbarItem.items(in: .output, order: moved, disabled: []) == [.longScreenshot, .save, .recognizeText, .pin, .copy, .cancel])
    let style = try #require(AnnotationToolSettings.reorderedItems(.size, translation: -2 * pitch, order: []))
    #expect(ScreenshotToolbarItem.items(in: .style, order: style, disabled: []).first == .size)
    #expect(AnnotationToolSettings.reorderedItems(.size, translation: .nan, order: []) == nil)
    #expect(AnnotationToolSettings.reorderedItems(.size, translation: pitch / 3, order: []) == nil)
  }

  @Test("Hidden action groups shrink both editor and selection toolbars", arguments: [420.0, 450.0, 800.0])
  func hiddenToolbarGroups(displayWidth: CGFloat) throws {
    let original = Defaults[.disabledToolbarItems]
    defer { Defaults[.disabledToolbarItems] = original }
    let display = NSRect(x: 0, y: 0, width: displayWidth, height: 800)
    func toolbar(selection: Bool) throws -> ScreenshotAnnotationWindow {
      if selection {
        let window = ScreenshotSelectionWindow(frame: display, visibleFrame: display, scale: 1, pinImmediately: false)
        window.showToolbar(beside: display.insetBy(dx: 50, dy: 50))
        return window
      }
      return try #require(ScreenshotAnnotationWindow(image: fixture(), visibleFrame: display))
    }
    for selection in [false, true] {
      Defaults[.disabledToolbarItems] = []
      let full = try toolbar(selection: selection)
      defer { full.close() }
      Defaults[.disabledToolbarItems] = ScreenshotToolbarItem.allCases.filter { $0.group != .style }.map(\.rawValue)
      let reduced = try toolbar(selection: selection)
      defer { reduced.close() }
      reduced.contentView?.layoutSubtreeIfNeeded()
      if displayWidth < 626 {
        #expect(reduced.annotationToolbar.frame.height < full.annotationToolbar.frame.height)
      }
      #expect(reduced.copyButton.window == nil && reduced.undoButton.window == nil)
      #expect(reduced.annotationToolbar.bounds.contains(reduced.annotationToolbar.convert(reduced.colorWell.bounds, from: reduced.colorWell)))
    }
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
    let result = try TextRecognition.recognizeScreenshot(source)
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
    let padded = try #require(TextRecognition.paddedNarrowImage(source))
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
    let result = try TextRecognition.recognizeScreenshot(image)
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
    #expect(try TextRecognition.recognizeScreenshot(source).contains("SAMPLE 42"))
    document.append(.init(
      tool: .redact, points: [.zero, NSPoint(x: document.imageSize.width, y: document.imageSize.height)], color: .white
    ))
    let covered = try #require(document.renderedImage())
    #expect(try TextRecognition.recognizeScreenshot(covered).isEmpty)
  }

  @Test("Toolbar copy and pin export only a flattened result", arguments: [false, true])
  func inlineOutputButtons(pin: Bool) async throws {
    let window = try editor()
    defer { window.close() }
    var outputs = 0
    window.canvas.document.append(.init(
      tool: .redact, points: [NSPoint(x: 20, y: 20), NSPoint(x: 100, y: 100)]
    ))
    window.onOutput = { data, _, action in
      #expect(action == (pin ? .pin : .copy))
      let data = try #require(data)
      #expect(NSBitmapImageRep(data: data)?.pixelsWide == 240)
      outputs += 1
    }
    (pin ? window.pinButton : window.copyButton)?.performClick(nil)
    await window.exportTask?.value
    #expect(outputs == 1)
  }

  @Test("Pinned editing applies in place without creating a second pinned image")
  func inlinePinnedOutput() async throws {
    let window = try #require(ScreenshotAnnotationWindow(
      image: fixture(), visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 800),
      imageFrame: NSRect(x: 100, y: 200, width: 240, height: 160), editingPin: true
    ))
    defer { window.close() }
    var actions: [ScreenshotAnnotationWindow.OutputAction] = []
    window.onOutput = { _, _, action in actions.append(action) }
    window.pinButton.performClick(nil)
    await window.exportTask?.value
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

  @Test("Toolbar grouping keeps all controls inside the panel", arguments: [420.0, 450.0, 800.0])
  func inlineToolbarLayout(displayWidth: CGFloat) throws {
    let display = NSRect(x: 0, y: 0, width: displayWidth, height: 800)
    let window = try #require(ScreenshotAnnotationWindow(image: fixture(), visibleFrame: display))
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    let actions: [NSView] = [window.copyButton, window.pinButton, window.undoButton, window.redoButton,
                             window.recognitionButton, window.colorWell, window.styleSlider]
    let controls: [NSView] = window.toolButtons + window.swatches
    for control in controls + actions {
      #expect(window.annotationToolbar.bounds.contains(window.annotationToolbar.convert(control.bounds, from: control)))
      #expect(control.frame.width > 20)
    }
    #expect(window.annotationToolbar.frame.height == window.toolbarSize.height)
  }

  @Test("The glass panel leaves screenshot buttons and the toolbar drag area interactive")
  func glassToolbarHitTesting() throws {
    let window = try editor()
    defer { window.close() }
    let toolbar = window.annotationToolbar
    let contents = try #require(window.contentView)
    contents.layoutSubtreeIfNeeded()
    if #available(macOS 26.0, *) {
      let glass = try #require(toolbar.subviews.first as? NSGlassEffectView)
      #expect(glass.contentView === toolbar.controlsView)
      #expect(glass.style == (NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        ? .regular
        : LiquidGlass.effectStyle(LiquidGlass.style)))
    } else {
      #expect(toolbar.controlsView is NSVisualEffectView)
    }

    let copyButton = try #require(window.copyButton)
    let copyCenter = NSPoint(x: copyButton.bounds.midX, y: copyButton.bounds.midY)
    #expect(toolbar.hitTest(contents.convert(copyCenter, from: copyButton)) === copyButton)
    let dragArea = NSPoint(x: 4, y: toolbar.bounds.midY)
    #expect(toolbar.hitTest(contents.convert(dragArea, from: toolbar)) === toolbar)
  }

  @Test("Glass symbols retain opaque foregrounds when appearance and selection change", arguments: [false, true])
  func glassSymbolForeground(chosen: Bool) throws {
    guard #available(macOS 26.0, *) else { return }
    let button = ScreenshotToolbarButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    button.image = NSImage(systemSymbolName: "rectangle.fill", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    button.usesGlass = true
    for dark in [false, true, false] {
      button.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      button.isChosen = chosen
      let image = try #require(button.image)
      #expect(!image.isTemplate)
      let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let bitmap = NSBitmapImageRep(cgImage: cgImage)
      let foreground = try color(bitmap, x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
      #expect(foreground.alphaComponent > 0.99)
      #expect(abs(foreground.redComponent - (dark ? 1 : 0)) < 0.01)
      #expect(abs(foreground.greenComponent - (dark ? 1 : 0)) < 0.01)
      #expect(abs(foreground.blueComponent - (dark ? 1 : 0)) < 0.01)
      #expect(button.bezelStyle == .glass)
    }
    button.image = nil
    button.isChosen.toggle()
    #expect(button.image == nil)
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

  @Test("Display changes cancel inline editing and discard it without invoking output; other screen notices keep it")
  func inlineScreenChange() throws {
    let window = try editor()
    var closes = 0
    var outputs = 0
    window.onClose = { closes += 1 }
    window.onOutput = { _, _, _ in outputs += 1 }
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(closes == 0 && !window.isFinished)
    window.displays = { [] }
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
  func inlineKeyboardOutput(key: String) async throws {
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
    await window.exportTask?.value
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
    let controls = try #require(window.contentView?.subviews.compactMap { $0 as? GlassControlStrip }.first)
    #expect(controls.controlsView.subviews.compactMap { $0 as? NSButton }.count == 1)
    #expect(window.contentView?.subviews.contains { $0 is NSButton } == false)
  }

  @Test("Mosaic pixelates the covered region and keeps text under it from being dragged out")
  func mosaicPixelates() throws {
    let document = try #require(ScreenshotAnnotationDocument(image: fixture()))
    document.append(.init(tool: .text, points: [NSPoint(x: 30, y: 125)], color: .black, text: "Value", fontSize: 20))
    #expect(document.textMarkIndex(at: NSPoint(x: 35, y: 130), padding: 0) == 0)
    #expect(document.append(.init(
      tool: .mosaic, points: [NSPoint(x: 0, y: 120), NSPoint(x: 120, y: 160)], lineWidth: 16
    )))
    #expect(document.marks.last?.mosaic != nil)
    #expect(document.textMarkIndex(at: NSPoint(x: 35, y: 130), padding: 0) == nil)
    let bitmap = try bitmap(document)
    // The 40 px region becomes three blocks; the middle block blends the blue/white edge at y = 140.
    let block = try color(bitmap, x: 34, y: 159 - 138)
    #expect(try color(bitmap, x: 33, y: 159 - 144) == block)
    #expect(block.blueComponent > 0.9 && block.redComponent > 0.05 && block.redComponent < 0.95)
    #expect(try color(bitmap, x: 200, y: 159 - 150).redComponent < 0.1)
    document.undo()
    #expect(document.marks.count == 1)
  }

  @Test("Eraser drag removes the marks it crosses in one undoable step")
  func eraserRemovesMarks() throws {
    let window = try editor()
    defer { window.close() }
    let canvas = try #require(window.canvas)
    let document = canvas.document
    document.append(.init(tool: .rectangle, points: [NSPoint(x: 20, y: 20), NSPoint(x: 100, y: 80)], lineWidth: 2))
    document.append(.init(tool: .arrow, points: [NSPoint(x: 150, y: 20), NSPoint(x: 220, y: 140)], lineWidth: 2))
    document.append(.init(tool: .text, points: [NSPoint(x: 120, y: 120)], text: "Keep", fontSize: 12))
    #expect(document.markIndex(at: NSPoint(x: 60, y: 50), tolerance: 1) == nil)
    #expect(document.markIndex(at: NSPoint(x: 60, y: 20.5), tolerance: 1) == 0)
    window.chooseTool(.eraser)
    #expect(canvas.tool == .eraser)
    #expect(!window.styleSlider.isEnabled)
    let scale = canvas.imageRect.width / document.imageSize.width
    func viewPoint(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
      NSPoint(x: canvas.imageRect.minX + x * scale, y: canvas.imageRect.minY + y * scale)
    }
    canvas.beginMark(at: viewPoint(60, 21))
    canvas.updateMark(to: viewPoint(60, 60))
    canvas.updateMark(to: viewPoint(230, 60))
    #expect(document.marks.count == 3)
    canvas.endMark(at: viewPoint(230, 60))
    #expect(document.marks.map(\.tool) == [.text])
    document.undo()
    #expect(document.marks.map(\.tool) == [.rectangle, .arrow, .text])
    document.redo()
    #expect(document.marks.map(\.text) == ["Keep"])
    canvas.beginMark(at: viewPoint(5, 150))
    canvas.endMark(at: viewPoint(5, 150))
    #expect(document.marks.count == 1)
    #expect(!document.append(.init(tool: .eraser, points: [.zero, NSPoint(x: 10, y: 10)])))
  }

  @Test("The toolbar shows no shortcut hint row and only grows while a status message is shown")
  func statusRow() throws {
    let window = try editor()
    defer { window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    let original = window.annotationToolbar.frame
    #expect(window.statusLabel.isHidden)
    window.setStatus("Export failed")
    #expect(!window.statusLabel.isHidden)
    #expect(window.annotationToolbar.frame.height == original.height + 17)
    #expect(window.annotationToolbar.frame.maxY == original.maxY)
    window.setStatus(nil)
    #expect(window.statusLabel.isHidden)
    #expect(window.annotationToolbar.frame == original)
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

nonisolated private final class SlowRecognition: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  let events: AsyncStream<Int>
  private let continuation: AsyncStream<Int>.Continuation
  private let lock = NSLock()
  private var cancellation: TextRecognition.Cancellation?
  private var runs = 0
  private var active = 0
  private var peak = 0

  init() {
    (events, continuation) = AsyncStream.makeStream(of: Int.self)
  }

  var maximumActive: Int { lock.withLock { peak } }
  var isCancelled: Bool {
    lock.withLock {
      guard let cancellation else { return false }
      do { try cancellation.checkCancellation(); return false } catch { return true }
    }
  }

  func recognize(_ image: CGImage, cancellation: TextRecognition.Cancellation) throws -> String {
    let run = lock.withLock {
      self.cancellation = cancellation
      runs += 1
      active += 1
      peak = max(peak, active)
      return runs
    }
    defer { lock.withLock { active -= 1 } }
    continuation.yield(run)
    if run == 1 { release.wait() }
    return "Result \(run)"
  }
}
