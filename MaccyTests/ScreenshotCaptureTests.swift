import AppKit
import CoreData
import Defaults
import KeyboardShortcuts
import Testing
@testable import Maccy

@MainActor
struct ScreenshotCaptureTests {
  @Test("Global capture defaults use bare function keys and leave optional actions unassigned")
  func globalCaptureShortcutDefaults() {
    #expect(KeyboardShortcuts.Name.screenshot.initialShortcut == nil)
    #expect(KeyboardShortcuts.Name.screenshotSelection.initialShortcut == KeyboardShortcuts.Shortcut(.f1))
    #expect(KeyboardShortcuts.Name.pinScreenshot.initialShortcut == KeyboardShortcuts.Shortcut(.f3))
    #expect(KeyboardShortcuts.Name.pinClipboardImage.initialShortcut == nil)
  }

  @Test("Pin estimates reject oversized, empty and overflowing pixel dimensions")
  func pinPixelLimits() {
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 10_000, pixelHeight: 10_000) == 400_000_000)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 10_001, pixelHeight: 10_000) == nil)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: Int.max, pixelHeight: Int.max) == nil)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 0, pixelHeight: 100) == nil)
    #expect(PinnedImageBudget.estimatedBytes(pixelWidth: 100, pixelHeight: -1) == nil)
    var budget = PinnedImageBudget()
    #expect(!budget.canAdd(400_000_004))
    let oversizedAdded = budget.add(UUID(), bytes: 400_000_004)
    #expect(!oversizedAdded)
    #expect(!budget.canAdd(0))
    #expect(budget.total == 0)
  }

  @Test("Pin budget reaches the aggregate limit and removing pins frees capacity")
  func aggregatePinBudget() {
    var budget = PinnedImageBudget()
    let first = UUID()
    let second = UUID()
    let third = UUID()
    let firstAdded = budget.add(first, bytes: 400_000_000)
    let secondAdded = budget.add(second, bytes: 400_000_000)
    #expect(firstAdded && secondAdded)
    let remaining = PinnedImageBudget.maximumBytes - budget.total
    #expect(budget.canAdd(remaining))
    let thirdAdded = budget.add(third, bytes: remaining)
    #expect(thirdAdded)
    #expect(budget.total == PinnedImageBudget.maximumBytes)
    #expect(!budget.canAdd(4))
    let overflowAdded = budget.add(UUID(), bytes: 4)
    #expect(!overflowAdded)
    budget.remove(first)
    budget.remove(first)
    #expect(budget.total == PinnedImageBudget.maximumBytes - 400_000_000)
    #expect(budget.canAdd(400_000_000))
    let thirdUpdated = budget.add(third, bytes: 4)
    #expect(thirdUpdated)
    #expect(budget.total == 400_000_004)
    budget.remove(second)
    budget.remove(third)
    #expect(budget.total == 0)
  }

  @Test("Pin estimates use the largest bitmap pixels rather than Retina points")
  func retinaPinEstimate() throws {
    let retina = try #require(NSBitmapImageRep(data: generatedPNG()))
    retina.size = NSSize(width: 4, height: 4)
    let small = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    ))
    let image = NSImage(size: NSSize(width: 4, height: 4))
    image.addRepresentation(small)
    image.addRepresentation(retina)
    #expect(PinnedImageBudget.estimatedBytes(for: image) == 8 * 8 * 4)
  }

  @Test("Pinned image context menus route close-all through the coordinator callback")
  func closeAllPinnedAction() throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    var calls = 0
    window.onCloseAll = { calls += 1 }
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let menu = try #require(imageView.menu)
    let item = try #require(menu.items.last)
    #expect(item.action == #selector(PinnedScreenshotWindow.closeAllImages))
    #expect(item.target === window)
    window.perform(item.action)
    #expect(calls == 1)
    window.close()
    #expect(window.onCloseAll == nil)
  }

  @Test("PNG validation decodes one full-resolution image off-main")
  func validatedImage() async throws {
    let data = try generatedPNG()
    let result = try await Task.detached {
      try ScreenshotCaptureSession.ValidatedImage.validate(data)
    }.value
    #expect(result.data == data)
    #expect(result.image.width == 8 && result.image.height == 8)
  }

  @Test("PNG validation rejects truncated and non-image data")
  func malformedImageData() throws {
    let data = try generatedPNG()
    for invalid in [Data(), Data("not an image".utf8), Data(data.prefix(24)), Data(data.dropLast(20))] {
      #expect(throws: ScreenshotCaptureSession.Failure.invalidImage) {
        try ScreenshotCaptureSession.ValidatedImage.validate(invalid)
      }
    }
  }

  @Test("PNG validation rejects images exceeding the pixel limit before decoding")
  func oversizedImageData() throws {
    let data = try generatedPNG()
    #expect(throws: ScreenshotCaptureSession.Failure.invalidImage) {
      try ScreenshotCaptureSession.ValidatedImage.validate(data, maximumPixels: 63)
    }
    #expect(try ScreenshotCaptureSession.ValidatedImage.validate(data, maximumPixels: 64).image.width == 8)
  }

  @Test("A history save failure does not block screenshot output", arguments: [false, true])
  func deliverWithHistoryResult(historyFails: Bool) throws {
    let data = try generatedPNG()
    let storageError = CocoaError(.persistentStoreSave)
    var steps: [String] = []
    let result = try ScreenshotCapture.deliverScreenshot(data, copy: { copied in
      #expect(copied == data)
      steps.append("copy")
      return true
    }, saveHistory: { saved in
      #expect(saved == data)
      steps.append("save")
      if historyFails { throw storageError }
    }, present: {
      steps.append("present")
    })
    #expect(steps == ["copy", "save", "present"])
    switch result {
    case .failure(let error):
      #expect(historyFails)
      #expect((error as? CocoaError)?.code == storageError.code)
    case .success:
      #expect(!historyFails)
    }
  }

  @Test("A clipboard write failure does not add screenshot history")
  func failedClipboardDelivery() throws {
    let data = try generatedPNG()
    #expect(throws: ScreenshotCaptureSession.Failure.clipboardWrite) {
      try ScreenshotCapture.deliverScreenshot(data, copy: { _ in false }, saveHistory: { _ in
        Issue.record("History was saved after a clipboard failure")
      }, present: {
        Issue.record("Output was presented after a clipboard failure")
      })
    }
  }

  @Test("Capture is silent and noninteractive; region coordinates support displays left of the main display")
  func captureArguments() {
    let output = URL(fileURLWithPath: "/private/tmp/generated-capture.png")
    let rectangle = NSRect(x: -1200, y: 120, width: 400, height: 300)
    #expect(ScreenshotCaptureSession.Mode.region(rectangle).arguments(output: output) == [
      "-R-1200,120,400,300", "-x", "-t", "png", output.path
    ])
    #expect(ScreenshotCaptureSession.Mode.mainDisplay.arguments(output: output) == [
      "-m", "-x", "-t", "png", output.path
    ])
  }

  @Test("Display freezing prefers the rectangle screenshot over the filtered rendering")
  func rectangleDisplayCapture() async throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let result = await ScreenshotCaptureSession.captureDisplayImage(rectangleCapture: {
      image
    }, filteredCapture: {
      Issue.record("Filtered rendering was used after a successful rectangle screenshot")
      return image
    })
    #expect(result === image)
  }

  @Test("Display captures require native pixel resolution with one-pixel rounding tolerance")
  func displayCaptureResolution() throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    func accepts(width: CGFloat, height: CGFloat, scale: CGFloat) -> Bool {
      let frame = NSRect(x: 0, y: 0, width: width, height: height)
      let display = ScreenshotSelectionController.Display(frame: frame, captureFrame: frame, scale: scale)
      return ScreenshotCaptureSession.hasSufficientResolution(image, for: display)
    }
    #expect(accepts(width: 8, height: 8, scale: 1))
    #expect(accepts(width: 7, height: 7, scale: 1))
    #expect(accepts(width: 9, height: 9, scale: 1))
    #expect(!accepts(width: 10, height: 8, scale: 1))
    #expect(!accepts(width: 8, height: 10, scale: 1))
    #expect(accepts(width: 4, height: 4, scale: 2))
    #expect(!accepts(width: 8, height: 8, scale: 2))
    #expect(accepts(width: 4.7, height: 4.7, scale: 2))
    #expect(!accepts(width: 4.8, height: 4.8, scale: 2))
  }

  @Test("Display freezing falls back when rectangle capture is unavailable or fails", arguments: [false, true])
  func filteredDisplayCapture(throwsError: Bool) async throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    var fallbackCalls = 0
    let result = await ScreenshotCaptureSession.captureDisplayImage(rectangleCapture: {
      if throwsError { throw ScreenshotCaptureSession.Failure.captureFailed }
      return nil
    }, filteredCapture: {
      fallbackCalls += 1
      return image
    })
    #expect(result === image)
    #expect(fallbackCalls == 1)
  }

  @Test("Display freezing returns no frozen image when both capture methods fail")
  func failedDisplayCapture() async {
    let result = await ScreenshotCaptureSession.captureDisplayImage(rectangleCapture: {
      throw ScreenshotCaptureSession.Failure.captureFailed
    }, filteredCapture: {
      throw ScreenshotCaptureSession.Failure.captureFailed
    })
    #expect(result == nil)
  }

  @Test("Display freezing with no displays returns no images")
  func emptyDisplayCapture() async {
    let images = await ScreenshotCaptureSession.captureDisplays([])
    #expect(images.isEmpty)
  }

  @Test("Display freezes overlap and keep display order even when a capture fails")
  func concurrentDisplayCapture() async throws {
    let image = try #require(NSBitmapImageRep(data: generatedPNG())?.cgImage)
    let displays = (1...3).map { id in
      ScreenshotSelectionController.Display(
        frame: NSRect(x: 0, y: 0, width: 800, height: 600),
        captureFrame: NSRect(x: 0, y: 0, width: 800, height: 600), scale: 1,
        displayID: CGDirectDisplayID(id), visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600)
      )
    }
    var completed: [CGDirectDisplayID] = []
    let images = await ScreenshotCaptureSession.captureDisplays(displays, capture: { display in
      try? await Task.sleep(for: .milliseconds(display.displayID == 1 ? 50 : 1))
      completed.append(display.displayID)
      return display.displayID == 2 ? nil : image
    })
    #expect(completed.last == 1)
    #expect(images.count == 3)
    #expect(images[0] === image)
    #expect(images[1] == nil)
    #expect(images[2] === image)
  }

  @Test("Missing region output is an error and temporary files are removed before retry",
        arguments: ["/usr/bin/true", "/usr/bin/false"])
  func missingRegionResult(executable: String) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, _ in
      process(executable)
    }
    let mode = ScreenshotCaptureSession.Mode.region(NSRect(x: 10, y: 20, width: 40, height: 30))
    await #expect(throws: ScreenshotCaptureSession.Failure.captureFailed) {
      try await session.capture(mode: mode)
    }
    #expect(!session.isCapturing)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    await #expect(throws: ScreenshotCaptureSession.Failure.captureFailed) {
      try await session.capture(mode: mode)
    }
  }

  @Test("A missing full-screen result is an error, not cancellation")
  func missingFullScreenResult() async throws {
    let session = ScreenshotCaptureSession { _, _ in process("/usr/bin/true") }
    await #expect(throws: ScreenshotCaptureSession.Failure.captureFailed) {
      try await session.capture(mode: .mainDisplay)
    }
    #expect(!session.isCapturing)
  }

  @Test("A capture tool that fails to launch releases the session")
  func launchFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, _ in
      process("/nonexistent/maccy-capture-test")
    }
    await #expect(throws: (any Error).self) {
      try await session.capture(mode: .mainDisplay)
    }
    #expect(!session.isCapturing)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Invalid image output never reaches the history pipeline")
  func invalidImage() async throws {
    let session = ScreenshotCaptureSession { _, output in
      process("/usr/bin/touch", arguments: [output.path])
    }
    await #expect(throws: ScreenshotCaptureSession.Failure.invalidImage) {
      try await session.capture(mode: .mainDisplay)
    }
    #expect(!session.isCapturing)
  }

  @Test("Only generated PNG data is returned and private temporary files are removed")
  func generatedImage() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = root.appendingPathComponent("generated.png")
    let data = try generatedPNG()
    try data.write(to: fixture)
    var permissions: Int?
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, output in
      let attributes = try? FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)
      permissions = attributes?[.posixPermissions] as? Int
      return process("/bin/cp", arguments: [fixture.path, output.path])
    }
    let result = try await session.capture(mode: .mainDisplay)
    #expect(result.data == data)
    #expect(result.image.width == 8 && result.image.height == 8)
    #expect(permissions == 0o700)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["generated.png"])
  }

  @Test("Timeout terminates the child and resets capture state")
  func timeout() async throws {
    let child = process("/bin/sleep", arguments: ["30"])
    let session = ScreenshotCaptureSession { _, _ in child }
    await #expect(throws: ScreenshotCaptureSession.Failure.timedOut) {
      try await session.capture(mode: .mainDisplay, timeout: .milliseconds(50))
    }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
  }

  @Test("Repeated shortcuts cannot create overlapping capture sessions")
  func repeatedCapture() async throws {
    let child = process("/bin/sleep", arguments: ["30"])
    let session = ScreenshotCaptureSession { _, _ in child }
    let first = Task { try await session.capture(mode: .mainDisplay) }
    try await waitForStart(session)
    await #expect(throws: ScreenshotCaptureSession.Failure.alreadyCapturing) {
      try await session.capture(mode: .mainDisplay)
    }
    session.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
  }

  @Test("A stuck capture that ignores termination is killed after timeout")
  func unresponsiveCapture() async throws {
    let child = process("/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"])
    let session = ScreenshotCaptureSession { _, _ in child }
    await #expect(throws: ScreenshotCaptureSession.Failure.timedOut) {
      try await session.capture(mode: .mainDisplay, timeout: .milliseconds(100))
    }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
  }

  @Test("Task cancellation terminates capture and removes temporary files")
  func taskCancellation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let child = process("/bin/sleep", arguments: ["30"])
    let session = ScreenshotCaptureSession(temporaryRoot: root) { _, _ in child }
    let task = Task { try await session.capture(mode: .mainDisplay) }
    try await waitForStart(session)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!child.isRunning)
    #expect(!session.isCapturing)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Pinned images fit within displays with negative coordinates")
  func pinPlacement() {
    let screen = NSRect(x: -1920, y: -1080, width: 1920, height: 1040)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: NSSize(width: 6000, height: 3000),
      visibleFrame: screen,
      anchor: NSPoint(x: -1, y: -1)
    )
    #expect(screen.contains(frame))
    #expect(frame.width <= screen.width)
    #expect(abs(frame.width / frame.height - 2) < 0.001)
  }

  @Test("Capture pins preserve their screen rectangle regardless of pixel density", arguments: [CGFloat(1), CGFloat(2)])
  func capturePinPointSize(scale: CGFloat) {
    let capture = NSRect(x: -1800, y: -900, width: 1500, height: 900)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: NSSize(width: capture.width * scale, height: capture.height * scale),
      visibleFrame: NSRect(x: -1920, y: -1080, width: 1920, height: 1040),
      anchor: NSPoint(x: capture.midX, y: capture.midY), captureFrame: capture
    )
    #expect(frame == capture)
  }

  @Test("Clipboard pins use representation point size rather than bitmap pixels")
  func clipboardPinPointSize() throws {
    let bitmap = try #require(NSBitmapImageRep(data: generatedPNG()))
    bitmap.size = NSSize(width: 4, height: 4)
    let image = NSImage(size: .zero)
    image.addRepresentation(bitmap)
    let frame = PinnedScreenshotWindow.initialFrame(
      imageSize: image.size, visibleFrame: NSRect(x: 0, y: 0, width: 100, height: 100),
      anchor: NSPoint(x: 99, y: 99)
    )
    #expect(frame == NSRect(x: 96, y: 96, width: 4, height: 4))
  }

  @Test("Clipboard pins only shrink when their point size exceeds the visible screen")
  func clipboardPinFitsScreen() {
    let screen = NSRect(x: -100, y: 0, width: 100, height: 100)
    for width: CGFloat in [80, 200] {
      let frame = PinnedScreenshotWindow.initialFrame(
        imageSize: NSSize(width: width, height: width / 2), visibleFrame: screen, anchor: .zero
      )
      #expect(frame.size == NSSize(width: min(width, 100), height: min(width, 100) / 2))
      #expect(screen.contains(frame))
    }
  }

  @Test("Invalid clipboard image sizes produce no frame", arguments: [
    NSSize.zero, NSSize(width: -1, height: 100), NSSize(width: CGFloat.infinity, height: 100)
  ])
  func invalidPinPointSize(size: NSSize) {
    #expect(PinnedScreenshotWindow.initialFrame(
      imageSize: size, visibleFrame: NSRect(x: 0, y: 0, width: 100, height: 100), anchor: .zero
    ) == .zero)
  }

  @Test("A pinned image has an exit path and close cleanup runs only once")
  func pinnedWindowCloses() throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image,
      visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    var closes = 0
    window.onClose = { closes += 1 }
    #expect(window.level == .floating)
    #expect(window.canBecomeKey)
    #expect(!window.isReleasedWhenClosed)
    window.cancelOperation(nil)
    window.close()
    #expect(closes == 1)
  }

  @Test("Pinned windows respond to Escape and Command-W without a system event tap",
        arguments: [false, true])
  func pinnedKeyboardExit(commandW: Bool) throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image,
      visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    var closed = false
    window.onClose = { closed = true }
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
    #expect(closed)
  }

  @Test("Pinned zoom preserves the image point beneath the pointer and the aspect ratio")
  func pinnedZoomAnchor() {
    let frame = NSRect(x: 300, y: 200, width: 400, height: 200)
    let zoomed = PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 800, height: 400), frame: frame, factor: 1.5,
      visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
      anchor: NSPoint(x: 400, y: 250)
    )
    #expect(zoomed == NSRect(x: 250, y: 175, width: 600, height: 300))
  }

  @Test("A remapped pinned-window shortcut works without keeping its old binding")
  func remappedPinnedShortcut() throws {
    try #require(AppDelegate.isTesting)
    let action = ScopedShortcut.closePinnedImage
    let previous = Defaults[.scopedShortcuts][action.rawValue]
    defer { Defaults[.scopedShortcuts][action.rawValue] = previous }
    let newShortcut = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
    action.set(newShortcut)
    let image = try #require(NSImage(data: generatedPNG()))
    let window = PinnedScreenshotWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      anchor: NSPoint(x: 400, y: 300)
    )
    var closed = false
    window.onClose = { closed = true }
    defer { window.close() }
    let oldEvent = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
      windowNumber: window.windowNumber, context: nil,
      characters: "w", charactersIgnoringModifiers: "w", isARepeat: false,
      keyCode: UInt16(action.initial.carbonKeyCode)
    ))
    #expect(!action.matches(oldEvent))
    let newEvent = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: newShortcut.modifiers, timestamp: 0,
      windowNumber: window.windowNumber, context: nil,
      characters: "k", charactersIgnoringModifiers: "k", isARepeat: false,
      keyCode: UInt16(newShortcut.carbonKeyCode)
    ))
    #expect(window.performKeyEquivalent(with: newEvent))
    #expect(closed)
  }

  @Test("Shortcut conflicts respect window scope and global assignments")
  func shortcutConflictScopes() {
    let chord = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
    let capture = ShortcutAssignment(id: "capture", title: "Capture", scope: .capture, shortcut: chord)
    let editor = ShortcutAssignment(id: "edit", title: "Edit", scope: .annotation, shortcut: chord)
    let selection = ShortcutAssignment(id: "selection", title: "Selection", scope: .selection, shortcut: chord)
    let pin = ShortcutAssignment(id: "pin", title: "Pin", scope: .pinnedImage, shortcut: chord)
    let global = ShortcutAssignment(id: "global", title: "Global", scope: .global, shortcut: chord)
    let assignments = [capture, editor, selection, pin, global]
    #expect(Set(capture.conflicts(in: assignments).map(\.id)) == ["edit", "selection", "global"])
    #expect(Set(editor.conflicts(in: assignments).map(\.id)) == ["capture", "global"])
    #expect(pin.conflicts(in: assignments).map(\.id) == ["global"])
    #expect(global.conflicts(in: assignments).count == 4)
  }

  @Test("Shortcut storage distinguishes a cleared binding from its default")
  func scopedShortcutStorage() throws {
    let action = ScopedShortcut.copyCapture
    let cleared = try JSONEncoder().encode(nil as KeyboardShortcuts.Shortcut?)
    let custom = KeyboardShortcuts.Shortcut(.k, modifiers: .command)
    let customData = try JSONEncoder().encode(custom)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: nil) == action.initial)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: cleared) == nil)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: customData) == custom)
    #expect(ScopedShortcut.resolve(initial: action.initial, stored: Data()) == action.initial)
  }

  @Test("Pinned zoom stays on negative-coordinate displays for wide, tall, and tiny images",
        arguments: [
          NSSize(width: 800, height: 400), NSSize(width: 400, height: 800),
          NSSize(width: 100000, height: 1000), NSSize(width: 1000, height: 100000),
          NSSize(width: 8, height: 8)
        ])
  func pinnedZoomBounds(imageSize: NSSize) {
    let visibleFrame = NSRect(x: -1920, y: -1080, width: 1920, height: 1040)
    let anchor = NSPoint(x: -5, y: -45)
    var frame = PinnedScreenshotWindow.initialFrame(
      imageSize: imageSize, visibleFrame: visibleFrame, anchor: anchor
    )
    for factor: CGFloat in [1000000, 0.000001, 2, 0.5] {
      frame = PinnedScreenshotWindow.zoomedFrame(
        imageSize: imageSize, frame: frame, factor: factor, visibleFrame: visibleFrame, anchor: anchor
      )
      #expect(visibleFrame.insetBy(dx: -0.001, dy: -0.001).contains(frame))
      #expect(frame.width > 0 && frame.height > 0)
      #expect(abs(frame.width / frame.height - imageSize.width / imageSize.height) < 0.001)
      #expect(frame.width <= imageSize.width * 5 + 0.001)
    }
  }

  @Test("Pinned zoom has minimum and maximum sizes")
  func pinnedZoomLimits() {
    let visibleFrame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    let frame = NSRect(x: 600, y: 400, width: 400, height: 200)
    let anchor = NSPoint(x: frame.midX, y: frame.midY)
    let smallest = PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 800, height: 400), frame: frame, factor: 0.000001,
      visibleFrame: visibleFrame, anchor: anchor
    )
    #expect(smallest.size == NSSize(width: 80, height: 40))
    let largest = PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 80, height: 40), frame: frame, factor: 1000000,
      visibleFrame: visibleFrame, anchor: anchor
    )
    #expect(largest.size == NSSize(width: 400, height: 200))
  }

  @Test("Invalid zoom factors leave pinned windows unchanged", arguments: [
    CGFloat.zero, -1, .nan, .infinity
  ])
  func invalidPinnedZoom(factor: CGFloat) {
    let frame = NSRect(x: 100, y: 100, width: 400, height: 200)
    #expect(PinnedScreenshotWindow.zoomedFrame(
      imageSize: NSSize(width: 800, height: 400), frame: frame, factor: factor,
      visibleFrame: NSRect(x: 0, y: 0, width: 1600, height: 1000),
      anchor: NSPoint(x: 300, y: 200)
    ) == frame)
  }

  @Test("Wheel zoom reaches the panel through its image view without extra buttons",
        arguments: [false, true], [false, true])
  func pinnedWheelZoom(precise: Bool, inverted: Bool) throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let image = try #require(imageView.image)
    let originalSize = image.size
    let event = PinnedZoomEvent()
    event.precise = precise
    event.inverted = inverted
    event.scrollDelta = (precise ? 10 : 1) * (inverted ? -1 : 1)
    imageView.scrollWheel(with: event)
    #expect(window.frame.width > originalFrame.width)
    #expect(abs(window.frame.width - window.frame.height * 2) <= 2)
    event.scrollDelta *= -1
    imageView.scrollWheel(with: event)
    #expect(abs(window.frame.width - originalFrame.width) <= 1)
    #expect(imageView.image === image)
    #expect(image.size == originalSize)
    let controls = try #require(window.contentView?.subviews.compactMap { $0 as? GlassControlStrip }.first)
    #expect(controls.controlsView.subviews.compactMap { $0 as? NSButton }.count == 1)
    #expect(window.contentView?.subviews.contains { $0 is NSButton } == false)
  }

  @Test("Trackpad pinch reaches the pinned panel through its image view")
  func pinnedPinchZoom() throws {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalWidth = window.frame.width
    let imageView = try #require(window.contentView?.subviews.compactMap { $0 as? NSImageView }.first)
    let event = PinnedZoomEvent()
    event.pinchDelta = 0.25
    imageView.magnify(with: event)
    #expect(abs(window.frame.width - originalWidth * 1.25) <= 1)
    event.pinchDelta = -0.2
    imageView.magnify(with: event)
    #expect(abs(window.frame.width - originalWidth) <= 1)
  }

  @Test("Subpixel trackpad scrolling accumulates without window-rounding drift")
  func precisePinnedZoomAccumulates() {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalWidth = window.frame.width
    let event = PinnedZoomEvent()
    event.precise = true
    event.scrollDelta = 0.02
    for _ in 0..<100 {
      window.scrollWheel(with: event)
    }
    #expect(abs(window.frame.width - originalWidth * exp(0.02)) <= 1)
    event.scrollDelta *= -1
    for _ in 0..<100 {
      window.scrollWheel(with: event)
    }
    #expect(abs(window.frame.width - originalWidth) <= 1)
  }

  @Test("Momentum, cancelled gestures, zero deltas, and invalid input cannot zoom a pin")
  func ignoredPinnedZoomEvents() {
    let window = pinnedZoomWindow()
    defer { window.close() }
    let originalFrame = window.frame
    let event = PinnedZoomEvent()
    event.scrollDelta = 2
    event.simulatedMomentum = .changed
    window.scrollWheel(with: event)
    #expect(window.frame == originalFrame)
    event.simulatedMomentum = []
    event.simulatedPhase = .cancelled
    event.pinchDelta = 0.25
    window.scrollWheel(with: event)
    window.magnify(with: event)
    #expect(window.frame == originalFrame)
    event.simulatedPhase = []
    for delta: CGFloat in [0, .nan, .infinity] {
      event.scrollDelta = delta
      event.pinchDelta = delta
      window.scrollWheel(with: event)
      window.magnify(with: event)
      #expect(window.frame == originalFrame)
    }
  }

  @Test("Screenshot previews stay in the bottom-left corner of the target display",
        arguments: [
          NSRect(x: -1920, y: -1080, width: 1920, height: 1040),
          NSRect(x: 0, y: 0, width: 200, height: 160)
        ])
  func previewPlacement(visibleFrame: NSRect) {
    let frame = ScreenshotPreviewWindow.initialFrame(
      imageSize: NSSize(width: 3840, height: 2160), visibleFrame: visibleFrame
    )
    #expect(visibleFrame.contains(frame))
    #expect(frame.width <= 220)
    #expect(frame.height <= 150)
    #expect(frame.minX == visibleFrame.minX + 16)
    #expect(frame.minY == visibleFrame.minY + 16)
  }

  @Test("Screenshot previews never take keyboard focus and clean up once on timeout")
  func previewAutoDismisses() async throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      dismissalDelay: .milliseconds(30), onPin: {}
    )
    var closes = 0
    window.onClose = { closes += 1 }
    #expect(!window.canBecomeKey)
    #expect(!window.canBecomeMain)
    #expect(window.level == .floating)
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(window.imageView.image === image)
    #expect(window.imageView.imageScaling == .scaleProportionallyUpOrDown)
    window.scheduleDismissal()
    try await waitForPreviewClose { closes > 0 }
    window.close()
    #expect(closes == 1)
  }

  @Test("The default thumbnail lifetime is two seconds")
  func previewTwoSeconds() async throws {
    let image = try #require(NSImage(data: generatedPNG()))
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      onPin: {}
    )
    var closed = false
    window.onClose = { closed = true }
    let started = ContinuousClock.now
    window.scheduleDismissal()
    try await Task.sleep(for: .milliseconds(1700))
    #expect(!closed)
    try await waitForPreviewClose { closed }
    #expect(closed)
    #expect(started.duration(to: .now) >= .seconds(2))
  }

  @Test("Pinning a thumbnail dismisses only that thumbnail and invokes its action once")
  func pinThumbnail() throws {
    let image = try #require(NSImage(data: generatedPNG()))
    var pins = 0
    var closes = 0
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      onPin: { pins += 1 }
    )
    window.onClose = { closes += 1 }
    window.pinImage()
    window.pinImage()
    #expect(pins == 1)
    #expect(closes == 1)
  }

  @Test("The thumbnail glass strip leaves its pin button clickable")
  func thumbnailGlassButton() throws {
    let image = try #require(NSImage(data: generatedPNG()))
    var pins = 0
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 600),
      onPin: { pins += 1 }
    )
    defer { window.close() }
    let surface = try #require(window.contentView as? GlassSurfaceView)
    surface.layoutSubtreeIfNeeded()
    let controls = try #require(surface.controlsView.subviews.compactMap { $0 as? GlassControlStrip }.first)
    let button = try #require(controls.controlsView.subviews.compactMap { $0 as? NSButton }.first)
    let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
    let hit = controls.hitTest(surface.controlsView.convert(center, from: button))
    #expect(hit === button)
    let gutter = surface.controlsView.convert(NSPoint(x: 1, y: controls.bounds.midY), from: controls)
    #expect(controls.hitTest(gutter) == nil)
    button.performClick(nil)
    #expect(pins == 1)
  }

  private func waitForPreviewClose(_ isClosed: () -> Bool) async throws {
    for _ in 0..<100 {
      if isClosed() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Preview did not dismiss")
  }

  private func pinnedZoomWindow() -> PinnedScreenshotWindow {
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    return PinnedScreenshotWindow(
      image: NSImage(size: NSSize(width: 200, height: 100)), visibleFrame: visibleFrame,
      anchor: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
    )
  }

  private func process(_ executable: String, arguments: [String] = []) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    return process
  }

  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Maccy-Test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func generatedPNG() throws -> Data {
    let bitmap = try #require(NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0
    ))
    for column in 0..<8 {
      for row in 0..<8 {
        bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.9, alpha: 1), atX: column, y: row)
      }
    }
    return try #require(bitmap.representation(using: .png, properties: [:]))
  }

  private func waitForStart(_ session: ScreenshotCaptureSession) async throws {
    for _ in 0..<100 {
      if session.isCapturing { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Capture did not start")
    throw CancellationError()
  }
}

private final class PinnedZoomEvent: NSEvent {
  var scrollDelta: CGFloat = 0
  var pinchDelta: CGFloat = 0
  var precise = false
  var inverted = false
  var simulatedMomentum: NSEvent.Phase = []
  var simulatedPhase: NSEvent.Phase = []

  override var scrollingDeltaY: CGFloat { scrollDelta }
  override var magnification: CGFloat { pinchDelta }
  override var hasPreciseScrollingDeltas: Bool { precise }
  override var isDirectionInvertedFromDevice: Bool { inverted }
  override var momentumPhase: NSEvent.Phase { simulatedMomentum }
  override var phase: NSEvent.Phase { simulatedPhase }
  override var locationInWindow: NSPoint { NSPoint(x: 100, y: 50) }
}
