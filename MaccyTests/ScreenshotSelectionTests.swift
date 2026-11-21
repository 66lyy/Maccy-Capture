import AppKit
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct ScreenshotSelectionTests {
  @Test("Overlay damage includes old and new borders, clips to bounds, and handles empty highlights")
  func overlayDirtyRect() {
    let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
    let old = NSRect(x: 20, y: 30, width: 60, height: 40)
    let new = NSRect(x: 100, y: 120, width: 80, height: 50)
    #expect(ScreenshotSelectionView.dirtyRect(from: old, to: new, in: bounds) ==
      NSRect(x: 12, y: 22, width: 176, height: 156))
    #expect(ScreenshotSelectionView.dirtyRect(from: old, to: nil, in: bounds) == old.insetBy(dx: -8, dy: -8))
    #expect(ScreenshotSelectionView.dirtyRect(from: nil, to: new, in: bounds) == new.insetBy(dx: -8, dy: -8))
    #expect(ScreenshotSelectionView.dirtyRect(from: nil, to: nil, in: bounds) == nil)
    #expect(ScreenshotSelectionView.dirtyRect(from: .zero, to: nil, in: bounds) == nil)
    #expect(ScreenshotSelectionView.dirtyRect(from: bounds, to: new, in: bounds) == bounds)
  }

  @Test("Timed out hover probes release their slot and ignore late results")
  func timedOutHoverProbe() async throws {
    #expect(ScreenshotElementDetection.applicationMessagingTimeout > 0)
    #expect(ScreenshotElementDetection.applicationMessagingTimeout <= 0.25)
    #expect(ScreenshotElementDetection.elementMessagingTimeout > 0)
    #expect(ScreenshotElementDetection.elementMessagingTimeout <= 0.25)
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    defer { view.finishInteraction() }
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    view.findElements = { _ in
      Thread.sleep(forTimeInterval: 1.5)
      return [child]
    }
    let point = NSPoint(x: 50, y: 40)
    let hover = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: hover)
    try await Task.sleep(for: ScreenshotSelectionView.probeTimeout + .milliseconds(100))
    view.findElements = { _ in [] }
    view.mouseMoved(with: hover)
    try await Task.sleep(for: .milliseconds(600))
    #expect(view.snapRectangle(near: point) == nil)
    view.findElements = { _ in [child] }
    let next = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: NSPoint(x: 56, y: 40), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: next)
    for _ in 0..<100 {
      if view.snapRectangle(near: NSPoint(x: 56, y: 40)) != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: NSPoint(x: 56, y: 40)) == child)
  }

  @Test("Selection constructs toolbar controls only for a valid selection and can close without them")
  func deferredSelectionToolbar() {
    let frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = ScreenshotSelectionWindow(frame: frame, visibleFrame: frame, scale: 1, pinImmediately: false)
    #expect(!window.isToolbarPrepared)
    #expect(window.toolButtons.isEmpty)
    window.showToolbar(beside: nil)
    #expect(!window.isToolbarPrepared)
    window.showToolbar(beside: NSRect(x: 20, y: 30, width: 200, height: 150))
    #expect(window.isToolbarPrepared)
    #expect(!window.toolButtons.isEmpty)
    let buttons = window.toolButtons
    window.showToolbar(beside: NSRect(x: 30, y: 40, width: 210, height: 160))
    #expect(window.toolButtons == buttons)
    window.close()
    let cancelled = ScreenshotSelectionWindow(frame: frame, visibleFrame: frame, scale: 1, pinImmediately: false)
    cancelled.close()
    #expect(!cancelled.isToolbarPrepared)
  }

  @Test("Long capture makes overlays live and click-through and cancel cleans up the panel")
  func scrollingSelectionLifecycle() async throws {
    let controller = controller()
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 30))
    window.selectionView.endSelection(at: NSPoint(x: 220, y: 180))
    window.beginLongScreenshot()
    let panel = try #require(window.scrollingPanel)
    #expect(controller.windows.allSatisfy { $0.ignoresMouseEvents && $0.selectionView.isScrolling })
    #expect(controller.windows.allSatisfy { $0.selectionView.frozen == nil && $0.annotationToolbar.isHidden })
    #expect(panel.level.rawValue > window.level.rawValue)
    #expect(!panel.ignoresMouseEvents)
    controller.cancel()
    #expect(try await task.value == nil)
    #expect(window.scrollingPanel == nil)
    #expect(!panel.isVisible)
    #expect(controller.windows.isEmpty)
  }

  @Test("Long capture errors cancel every capture window")
  func scrollingCaptureFailure() async throws {
    let controller = ScreenshotSelectionController(
      displays: { Self.displays }, presentWindow: { _, _ in },
      captureRegion: { _, _, _ in throw ScreenshotCaptureSession.Failure.captureFailed },
      freezeDisplays: { _ in [] }
    )
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 30))
    window.selectionView.endSelection(at: NSPoint(x: 220, y: 180))
    window.beginLongScreenshot()
    #expect(try await task.value == nil)
    #expect(window.scrollingPanel == nil)
    #expect(controller.windows.isEmpty)
  }

  @Test("Long capture outputs the full PNG after a background preview", arguments: [false, true])
  func scrollingOutput(pin: Bool) async throws {
    let controller = controller()
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 30))
    window.selectionView.endSelection(at: NSPoint(x: 220, y: 180))
    window.beginLongScreenshot()
    let panel = try #require(window.scrollingPanel)
    for _ in 0..<100 {
      if panel.image != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let preview = try #require(panel.image)
    #expect(preview.width <= 264 && preview.height <= 120)
    panel.onFinish?(pin)
    let selection = try #require(try await task.value)
    let data = try #require(selection.renderedData)
    let image = try ScreenshotCaptureSession.ValidatedImage.validate(data).image
    #expect(image.width > preview.width && image.height > preview.height)
    #expect(selection.renderedScale == 2)
    #expect(selection.pinToScreen == pin)
    #expect(controller.windows.isEmpty && !panel.isVisible)
  }

  @Test("Cancelling during background output cannot complete a later selection")
  func scrollingOutputCancellation() async throws {
    let controller = controller()
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 30))
    window.selectionView.endSelection(at: NSPoint(x: 220, y: 180))
    window.beginLongScreenshot()
    let panel = try #require(window.scrollingPanel)
    panel.onFinish?(false)
    controller.cancel()
    #expect(try await task.value == nil)
    let next = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    try await Task.sleep(for: .milliseconds(50))
    #expect(controller.isSelecting)
    controller.cancel()
    #expect(try await next.value == nil)
  }

  @Test("The glass selection hint does not intercept selection gestures")
  func selectionGlassHitTesting() throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 600), scale: 2, pinImmediately: false
    )
    view.layoutSubtreeIfNeeded()
    let hint = try #require(view.subviews.first { $0 is GlassSurfaceView && !$0.isHidden })
    #expect(!hint.frame.isEmpty)
    #expect(view.bounds.contains(hint.frame))
    #expect(hint.hitTest(NSPoint(x: hint.frame.midX, y: hint.frame.midY)) == nil)
    view.beginSelection(at: NSPoint(x: 20, y: 20))
    view.endSelection(at: NSPoint(x: 140, y: 150))
    view.layoutSubtreeIfNeeded()
    #expect(view.selectedRect?.size == NSSize(width: 120, height: 130))
    #expect(hint.frame.minY >= 150)
  }

  @Test("Reverse drags remain inside the display")
  func dragGeometry() {
    let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
    let rectangle = ScreenshotSelectionView.rectangle(
      from: NSPoint(x: 700, y: 500), to: NSPoint(x: -50, y: 700), bounds: bounds
    )
    #expect(rectangle == NSRect(x: 0, y: 500, width: 700, height: 100))
    #expect(bounds.contains(rectangle))
  }

  @Test("AppKit coordinates map to capture coordinates on left and upper displays")
  func displayCoordinates() {
    let left = ScreenshotSelectionController.Display(
      frame: NSRect(x: -1200, y: -200, width: 1200, height: 800),
      captureFrame: NSRect(x: -1200, y: 300, width: 1200, height: 800), scale: 2
    )
    let above = ScreenshotSelectionController.Display(
      frame: NSRect(x: 0, y: 900, width: 1200, height: 800),
      captureFrame: NSRect(x: 0, y: -800, width: 1200, height: 800), scale: 1
    )
    let local = NSRect(x: 100, y: 200, width: 300, height: 250)
    #expect(ScreenshotSelectionController.captureRectangle(local, display: left) ==
      NSRect(x: -1100, y: 650, width: 300, height: 250))
    #expect(ScreenshotSelectionController.captureRectangle(local, display: above) ==
      NSRect(x: 100, y: -450, width: 300, height: 250))
    let capture = ScreenshotSelectionController.captureRectangle(
      NSRect(x: 10.2, y: 30.3, width: 100.4, height: 80.5), display: above
    )
    let screen = ScreenshotSelectionController.screenRectangle(capture, display: above)
    #expect(screen == NSRect(x: 10, y: 930, width: 101, height: 81))
    #expect(ScreenshotSelectionController.captureRectangle(
      screen.offsetBy(dx: -above.frame.minX, dy: -above.frame.minY), display: above
    ) == capture)
    #expect(ScreenshotCaptureSession.sourceRectangle(
      capture, displayFrame: above.captureFrame
    ) == NSRect(x: 10, y: 689, width: 101, height: 81))
  }

  @Test("Copy and dedicated pinning close every overlay without capturing for edit",
        arguments: [false, true])
  func releaseActions(pinToScreen: Bool) async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: pinToScreen) }
    try await waitForSelection(controller)
    let windows = controller.windows
    #expect(windows.count == 2)
    for window in windows {
      #expect(window.level.rawValue == Int(CGWindowLevelForKey(.overlayWindow)))
      #expect(window.level.rawValue > NSWindow.Level.popUpMenu.rawValue)
      #expect(window.level.rawValue < NSWindow.Level.screenSaver.rawValue)
      #expect(window.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]))
      #expect(window.styleMask.contains(.nonactivatingPanel))
      #expect(!window.isOpaque)
      #expect(window.canBecomeKey)
      #expect(!window.isReleasedWhenClosed)
    }
    let view = try #require(windows.first?.selectionView)
    view.beginSelection(at: NSPoint(x: 10, y: 20))
    view.endSelection(at: NSPoint(x: 110, y: 80))
    if !pinToScreen {
      #expect(controller.isSelecting)
      view.captureSelection(pinToScreen: false)
    }
    let result = try #require(try await task.value)
    #expect(result.pinToScreen == pinToScreen)
    #expect(result.renderedData == nil)
    #expect(result.captureRect == NSRect(x: 10, y: 520, width: 100, height: 60))
    #expect(result.anchor == NSPoint(x: 60, y: 50))
    #expect(result.screenRect == NSRect(x: 10, y: 20, width: 100, height: 60))
    #expect(!controller.isSelecting)
    #expect(controller.windows.isEmpty)
    #expect(windows.allSatisfy { !$0.isVisible && $0.onCancel == nil })
    controller.cancel()
    view.captureSelection(pinToScreen: true)
  }

  @Test("The pointer's display gets keyboard focus last, with a fallback outside any display",
        arguments: [false, true])
  func keyboardWindow(pointerOnSecondaryDisplay: Bool) async throws {
    var presentation: [(window: ScreenshotSelectionWindow, wantsKeyboard: Bool)] = []
    let pointer = pointerOnSecondaryDisplay ? NSPoint(x: -100, y: 100) : NSPoint(x: 800, y: 600)
    let controller = controller(pointer: pointer, presentWindow: { window, wantsKeyboard in
      presentation.append((window, wantsKeyboard))
    })
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let keyboardIndex = pointerOnSecondaryDisplay ? 1 : 0
    #expect(presentation.map(\.wantsKeyboard) == [false, true])
    #expect(presentation.first?.window === controller.windows[1 - keyboardIndex])
    #expect(presentation.last?.window === controller.windows[keyboardIndex])
    controller.cancel()
    #expect(try await task.value == nil)
  }

  @Test("The dedicated capture-and-pin action finishes as soon as the mouse is released")
  func pinOnRelease() async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: true) }
    try await waitForSelection(controller)
    let view = try #require(controller.windows.first?.selectionView)
    view.beginSelection(at: NSPoint(x: 20, y: 30))
    view.endSelection(at: NSPoint(x: 220, y: 180))
    let result = try #require(try await task.value)
    #expect(result.pinToScreen)
    #expect(result.captureRect == NSRect(x: 20, y: 420, width: 200, height: 150))
    #expect(controller.windows.isEmpty)
  }

  @Test("One click on a drawing tool starts editing in the same selection window")
  func editInSelection() async throws {
    let controller = controller()
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let windows = controller.windows
    let window = try #require(windows.first)
    let view = window.selectionView
    view.beginSelection(at: NSPoint(x: 20, y: 30))
    view.endSelection(at: NSPoint(x: 220, y: 180))
    #expect(controller.isSelecting)
    #expect(!window.annotationToolbar.isHidden && window.canvas == nil)
    let toolbarFrame = window.annotationToolbar.frame
    window.swatches[3].performClick(nil)
    #expect(window.canvas == nil)
    window.toolButtons[1].performClick(nil)
    for _ in 0..<100 {
      if window.canvas != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    let canvas = try #require(window.canvas)
    #expect(window.canvas.superview === view)
    #expect(controller.windows.first === window)
    #expect(window.annotationToolbar.frame == toolbarFrame)
    #expect(canvas.frame == view.selectedRect)
    #expect(canvas.tool == .rectangle && canvas.color == .systemGreen)
    canvas.beginMark(at: NSPoint(x: 20, y: 30))
    canvas.endMark(at: NSPoint(x: 100, y: 100))
    #expect(canvas.document.canUndo)
    window.copyButton.performClick(nil)
    let result = try #require(try await task.value)
    #expect(result.renderedData != nil)
    #expect(!result.pinToScreen)
    #expect(controller.windows.isEmpty)
    #expect(windows.allSatisfy { !$0.isVisible && $0.loadSelectionImage == nil })
  }

  @Test("OCR opens readable results on the same panel without confirming annotation first")
  func recognizeInSelection() async throws {
    let controller = controller()
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 30))
    window.selectionView.endSelection(at: NSPoint(x: 370, y: 160))
    #expect(window.canvas == nil)
    window.recognitionButton.performClick(nil)
    for _ in 0..<200 {
      if window.recognitionResults != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let results = try #require(window.recognitionResults)
    #expect(results.superview === window.selectionView)
    #expect(results.textView.string.contains("SAMPLE 42"))
    #expect(results.copyButton.isEnabled)
    #expect(controller.isSelecting)
    window.cancelOperation(nil)
    #expect(window.recognitionResults == nil)
    #expect(controller.isSelecting)
    controller.cancel()
    #expect(try await task.value == nil)
  }

  @Test("Dragging reports the pointer's pixel position from the display's top-left corner")
  func pointerPixelPosition() {
    let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
    #expect(ScreenshotSelectionView.pixelPositionText(of: NSPoint(x: 120.6, y: 450), in: bounds, scale: 2) == "X 241  Y 300")
    #expect(ScreenshotSelectionView.pixelPositionText(of: NSPoint(x: -40, y: 700), in: bounds, scale: 1) == "X 0  Y 0")
    #expect(ScreenshotSelectionView.pixelPositionText(of: NSPoint(x: 900, y: -5), in: bounds, scale: 1) == "X 800  Y 600")
  }

  @Test("An existing selection can move, resize and nudge without capturing")
  func adjustSelection() {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    var captures = 0
    view.onCapture = { _, _ in captures += 1 }
    view.beginSelection(at: NSPoint(x: 20, y: 30))
    view.endSelection(at: NSPoint(x: 120, y: 130))
    view.beginSelection(at: NSPoint(x: 50, y: 60))
    view.endSelection(at: NSPoint(x: 110, y: 100))
    #expect(view.selectedRect == NSRect(x: 80, y: 70, width: 100, height: 100))
    view.nudge(dx: -1, dy: 10)
    #expect(view.selectedRect == NSRect(x: 79, y: 80, width: 100, height: 100))
    view.beginSelection(at: NSPoint(x: 179, y: 180))
    view.endSelection(at: NSPoint(x: 200, y: 220))
    #expect(view.selectedRect == NSRect(x: 79, y: 80, width: 121, height: 140))
    view.nudge(dx: -500, dy: 500)
    #expect(view.selectedRect == NSRect(x: 0, y: 160, width: 121, height: 140))
    #expect(captures == 0)
  }

  @Test("Pointer nudges use whole screen points and stay on the display")
  func nudgePointer() throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    var steps: [NSPoint] = []
    view.movePointer = { steps.append($0) }
    let hover = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: NSPoint(x: 2.4, y: 298.6), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: hover)
    view.nudge(dx: -1, dy: 1)
    view.nudge(dx: -10, dy: 10)
    #expect(steps == [NSPoint(x: 1, y: 300), NSPoint(x: 0, y: 300)])
    #expect(view.selectedRect == nil)
  }

  @Test("The loupe samples frozen pixels in top-left order and formats their sRGB components")
  func loupeSample() throws {
    let image = try colorPickerImage()
    let bounds = NSRect(x: 10, y: 20, width: 1, height: 1)
    let topRight = ScreenshotPixelLoupe.pixel(at: NSPoint(x: 10.9, y: 20.9), in: bounds, image: image)
    let bottomLeft = ScreenshotPixelLoupe.pixel(at: NSPoint(x: 10.1, y: 20.1), in: bounds, image: image)
    #expect(topRight == CGPoint(x: 1, y: 0))
    #expect(bottomLeft == CGPoint(x: 0, y: 1))
    let color = try #require(ScreenshotPixelLoupe.sample(image, at: topRight))
    #expect(color.hex == "#04A0FF")
    #expect(color.rgb == "rgb(4, 160, 255)")
    #expect(ScreenshotPixelLoupe.sample(image, at: bottomLeft)?.hex == "#00FF00")
  }

  @Test("Arrow keys move the hovered sample one frozen pixel and stop at the display edge")
  func nudgeLoupe() throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 1, height: 1), scale: 2, pinImmediately: false
    )
    view.setFrozenImage(try colorPickerImage())
    view.moveHover(to: NSPoint(x: 0.1, y: 0.1))
    var steps: [NSPoint] = []
    view.movePointer = { steps.append($0) }
    for (code, character) in [(124, "\u{F703}"), (126, "\u{F700}"), (124, "\u{F703}"), (126, "\u{F700}")] {
      let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
        windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: UInt16(code)
      ))
      view.keyDown(with: event)
    }
    #expect(steps == [
      NSPoint(x: 0.75, y: 0.25), NSPoint(x: 0.75, y: 0.75),
      NSPoint(x: 0.75, y: 0.75), NSPoint(x: 0.75, y: 0.75)
    ])
  }

  @Test("C and Shift-C copy the hovered color as text but Command-C remains a capture shortcut",
        arguments: [false, true])
  func copyLoupeColor(rgb: Bool) throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 100, height: 100), scale: 1, pinImmediately: false
    )
    defer { view.finishInteraction() }
    view.setFrozenImage(try colorPickerImage())
    view.moveHover(to: NSPoint(x: 75, y: 75))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    func event(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
      try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: "c", charactersIgnoringModifiers: "c",
        isARepeat: false, keyCode: 8
      ))
    }
    #expect(try !view.handleColorShortcut(event(.command), to: pasteboard))
    #expect(try view.handleColorShortcut(event(rgb ? .shift : []), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == (rgb ? "rgb(4, 160, 255)" : "#04A0FF"))
  }

  private func colorPickerImage() throws -> CGImage {
    let rows: [UInt8] = [
      255, 0, 0, 255, 4, 160, 255, 255,
      0, 255, 0, 255, 255, 255, 255, 255
    ]
    let data = try #require(CGDataProvider(data: Data(rows) as CFData))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    return try #require(CGImage(
      width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: space,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: data,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent
    ))
  }

  @Test("Element bounds clip to the current display and keep the child-to-parent order")
  func snapCandidates() {
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    let parent = NSRect(x: -10, y: -15, width: 180, height: 160)
    let bounds = NSRect(x: 0, y: 0, width: 160, height: 120)
    let other = NSRect(x: 110, y: 70, width: 100, height: 80)
    #expect(ScreenshotSelectionView.snapCandidates(
      [child, child, other, parent, bounds], containing: NSPoint(x: 50, y: 40), bounds: bounds
    ) == [child, bounds])
  }

  @Test("Option-Tab and Option-Shift-Tab select parent and child without using the live desktop",
        arguments: [false, true])
  func elementNavigation(useParent: Bool) async throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    let parent = NSRect(x: 10, y: 15, width: 180, height: 160)
    let point = NSPoint(x: 50, y: 40)
    view.findElements = { _ in [child, parent] }
    defer { view.finishInteraction() }
    let hover = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: hover)
    for _ in 0..<100 {
      if view.snapRectangle(near: point) != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: point) == child)
    let tab = try #require(NSEvent.keyEvent(
      with: .keyDown, location: point, modifierFlags: .option, timestamp: 0, windowNumber: 0,
      context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
    ))
    view.keyDown(with: tab)
    #expect(view.snapRectangle(near: point) == parent)
    let movedPoint = NSPoint(x: 54, y: 40)
    let moved = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: movedPoint, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: moved)
    for _ in 0..<100 {
      if view.snapRectangle(near: movedPoint) != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: movedPoint) == child)
    view.keyDown(with: tab)
    if !useParent {
      let back = try #require(NSEvent.keyEvent(
        with: .keyDown, location: movedPoint, modifierFlags: [.option, .shift], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
      ))
      view.keyDown(with: back)
    }
    let click = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown, location: movedPoint, modifierFlags: .option,
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
    view.mouseDown(with: click)
    #expect(view.selectedRect == (useParent ? parent : child))
  }

  @Test("Unmodified hover detects elements; a click selects them and a drag stays free-form",
        arguments: [false, true], [false, true])
  func automaticElementSelection(drag: Bool, pinImmediately: Bool) async throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: pinImmediately
    )
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    let parent = NSRect(x: 10, y: 15, width: 180, height: 160)
    let point = NSPoint(x: 50, y: 40)
    view.findElements = { _ in [child, parent] }
    defer { view.finishInteraction() }
    var captures: [NSRect] = []
    var begins = 0
    view.onCapture = { rectangle, pin in
      #expect(pin)
      captures.append(rectangle)
    }
    view.onBegin = { begins += 1 }
    let hover = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: hover)
    for _ in 0..<100 {
      if view.snapRectangle(near: point) != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: point) == child)
    #expect(view.selectedRect == nil)
    let down = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
    view.mouseDown(with: down)
    #expect(view.selectedRect == nil)
    #expect(view.snapRectangle(near: point) == nil)
    let end = NSPoint(x: point.x + (drag ? 3 : 1), y: point.y + (drag ? 3 : 1))
    let dragged = try #require(NSEvent.mouseEvent(
      with: .leftMouseDragged, location: end, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
    view.mouseDragged(with: dragged)
    let up = try #require(NSEvent.mouseEvent(
      with: .leftMouseUp, location: end, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
    ))
    view.mouseUp(with: up)
    let expected = drag ? NSRect(x: 50, y: 40, width: 3, height: 3) : child
    #expect(view.selectedRect == expected)
    #expect(begins == 1)
    #expect(captures == (pinImmediately ? [expected] : []))
    #expect(view.snapRectangle(near: end) == nil)
  }

  @Test("Finishing during a hover probe leaves the view free to probe again")
  func probeAfterCancelledProbe() async throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    view.findElements = { _ in [child] }
    let first = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: NSPoint(x: 50, y: 40), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: first)
    view.finishInteraction()
    view.findElements = { _ in [child] }
    defer { view.finishInteraction() }
    let point = NSPoint(x: 56, y: 40)
    let second = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: second)
    for _ in 0..<100 {
      if view.snapRectangle(near: point) != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: point) == child)
  }

  @Test("Hovering without accessible elements leaves a plain click empty")
  func automaticElementSelectionWithoutCandidates() async throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: true
    )
    view.findElements = { _ in [] }
    defer { view.finishInteraction() }
    var captures = 0
    view.onCapture = { _, _ in captures += 1 }
    let point = NSPoint(x: 50, y: 40)
    let hover = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: point, modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: hover)
    try await Task.sleep(for: .milliseconds(100))
    #expect(view.snapRectangle(near: point) == nil)
    view.beginSelection(at: point)
    view.endSelection(at: point)
    #expect(view.selectedRect == nil)
    #expect(captures == 0)
  }

  @Test("Clicking without a usable selection does not capture an empty image")
  func emptySelection() async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: true) }
    try await waitForSelection(controller)
    let view = try #require(controller.windows.first?.selectionView)
    view.beginSelection(at: NSPoint(x: 20, y: 30))
    view.endSelection(at: NSPoint(x: 21, y: 31))
    #expect(view.selectedRect == nil)
    #expect(controller.isSelecting)
    controller.cancel()
    #expect(try await task.value == nil)
  }

  @Test("Starting a selection on another monitor clears the earlier rectangle")
  func switchMonitor() async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let first = controller.windows[0].selectionView
    let second = controller.windows[1].selectionView
    first.beginSelection(at: NSPoint(x: 10, y: 10))
    first.updateSelection(to: NSPoint(x: 200, y: 100))
    #expect(first.selectedRect != nil)
    second.beginSelection(at: NSPoint(x: 20, y: 20))
    #expect(first.selectedRect == nil)
    controller.cancel()
    #expect(try await task.value == nil)
  }

  @Test("Escape and Command-W close every selection window", arguments: [false, true])
  func keyboardCancellation(commandW: Bool) async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: commandW ? .command : [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: commandW ? "w" : "\u{1B}", charactersIgnoringModifiers: commandW ? "w" : "\u{1B}",
      isARepeat: false, keyCode: commandW ? 13 : 53
    ))
    if commandW {
      #expect(window.performKeyEquivalent(with: event))
    } else {
      window.keyDown(with: event)
    }
    #expect(try await task.value == nil)
    #expect(controller.windows.isEmpty)
  }

  @Test("Enter copies and P pins the selected rectangle", arguments: [false, true])
  func keyboardActions(pinToScreen: Bool) async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    let view = window.selectionView
    view.beginSelection(at: NSPoint(x: 10, y: 20))
    view.updateSelection(to: NSPoint(x: 110, y: 80))
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: 0, windowNumber: window.windowNumber, context: nil,
      characters: pinToScreen ? "p" : "\r", charactersIgnoringModifiers: pinToScreen ? "p" : "\r",
      isARepeat: false, keyCode: pinToScreen ? 35 : 36
    ))
    view.keyDown(with: event)
    let result = try #require(try await task.value)
    #expect(result.pinToScreen == pinToScreen)
    #expect(controller.windows.isEmpty)
  }

  @Test("Repeated shortcuts cannot stack selection windows")
  func repeatedSelection() async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    await #expect(throws: ScreenshotCaptureSession.Failure.alreadyCapturing) {
      try await controller.select(pinImmediately: false)
    }
    #expect(controller.windows.count == 2)
    controller.cancel()
    #expect(try await task.value == nil)
  }

  @Test("Timeout and task cancellation release all selection windows", arguments: [false, true])
  func cancellationCleanup(cancelTask: Bool) async throws {
    let controller = controller()
    let task = Task {
      try await controller.select(pinImmediately: false, timeout: cancelTask ? .seconds(30) : .milliseconds(50))
    }
    try await waitForSelection(controller)
    if cancelTask { task.cancel() }
    #expect(try await task.value == nil)
    #expect(!controller.isSelecting)
    #expect(controller.windows.isEmpty)
  }

  @Test("Element detection over a frozen screen uses the windows listed when it was frozen")
  func frozenWindowList() {
    let frame = NSRect(x: 100, y: 100, width: 300, height: 200)
    let windows = [ScreenshotElementDetection.Window(pid: -1, frame: frame)]
    #expect(ScreenshotElementDetection.rectangles(at: NSPoint(x: 150, y: 150), in: windows) == [frame])
    #expect(ScreenshotElementDetection.rectangles(at: NSPoint(x: 50, y: 50), in: windows).isEmpty)
    #expect(ScreenshotElementDetection.rectangles(at: NSPoint(x: 150, y: 150), in: []).isEmpty)
  }

  @Test("The screen is frozen when selection starts: the overlay shows it and copy and edit cut from it")
  func frozenScreen() async throws {
    let context = try #require(CGContext(
      data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(NSColor.blue.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
    let frozen = try #require(context.makeImage())
    for edit in [false, true] {
      let controller = controller(frozen: [frozen, nil])
      defer { controller.cancel() }
      let task = Task { try await controller.select(pinImmediately: false) }
      try await waitForSelection(controller)
      let window = try #require(controller.windows.first)
      #expect(window.selectionView.frozen?.size == NSSize(width: 800, height: 600))
      #expect(controller.windows.last?.selectionView.frozen == nil)
      let view = window.selectionView
      view.beginSelection(at: NSPoint(x: 10, y: 20))
      view.endSelection(at: NSPoint(x: 110, y: 80))
      if edit {
        let (image, frame) = try #require(try await window.loadSelectionImage?())
        #expect(frame == NSRect(x: 10, y: 20, width: 100, height: 60))
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(cgImage.width == 200 && cgImage.height == 120)
        controller.cancel()
        #expect(try await task.value == nil)
      } else {
        view.captureSelection(pinToScreen: false)
        let result = try #require(try await task.value)
        #expect(result.renderedData == nil)
        #expect(result.image?.width == 200 && result.image?.height == 120)
      }
    }
  }

  @Test("Dock, menu bar and Space changes keep selecting; a real display change cancels without capturing")
  func displayOrSpaceChange() async throws {
    var displays = Self.displays
    let controller = controller(displays: { displays })
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    displays[0].visibleFrame = NSRect(x: 0, y: 70, width: 800, height: 505)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    #expect(controller.isSelecting)
    #expect(controller.windows.count == 2)
    displays[1] = .init(
      frame: NSRect(x: -800, y: 0, width: 800, height: 600),
      captureFrame: NSRect(x: -800, y: 0, width: 800, height: 600), scale: 2
    )
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(try await task.value == nil)
    #expect(controller.windows.isEmpty)
  }

  private static let displays: [ScreenshotSelectionController.Display] = [
    .init(
      frame: NSRect(x: 0, y: 0, width: 800, height: 600),
      captureFrame: NSRect(x: 0, y: 0, width: 800, height: 600), scale: 2
    ),
    .init(
      frame: NSRect(x: -800, y: 0, width: 800, height: 600),
      captureFrame: NSRect(x: -800, y: 0, width: 800, height: 600), scale: 1
    )
  ]

  private func controller(
    pointer: NSPoint = .zero,
    displays: @escaping @MainActor () -> [ScreenshotSelectionController.Display] = { Self.displays },
    frozen: [CGImage?] = [],
    presentWindow: @escaping @MainActor (ScreenshotSelectionWindow, Bool) -> Void = { _, _ in }
  ) -> ScreenshotSelectionController {
    ScreenshotSelectionController(
      displays: displays, pointerLocation: { pointer }, presentWindow: presentWindow,
      captureRegion: { display, rectangle, _ in
      #expect(display.frame.size == NSSize(width: 800, height: 600))
      return NSImage(size: rectangle.size, flipped: false) { bounds in
        NSColor.white.setFill()
        bounds.fill()
        ("SAMPLE 42" as NSString).draw(at: NSPoint(x: 15, y: 20), withAttributes: [
          .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black
        ])
        return true
      }
    }, freezeDisplays: { _ in frozen })
  }

  private func waitForSelection(_ controller: ScreenshotSelectionController) async throws {
    for _ in 0..<100 {
      if controller.isSelecting { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Selection did not start")
    throw CancellationError()
  }
}
