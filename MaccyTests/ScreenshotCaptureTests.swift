import AppKit
import CoreData
import Defaults
import KeyboardShortcuts
import Testing
@testable import Maccy

@MainActor
struct ScreenshotCaptureTests {
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
    #expect(try await session.capture(mode: .mainDisplay) == data)
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
    #expect(frame.width <= screen.width * 0.7)
    #expect(abs(frame.width / frame.height - 2) < 0.001)
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

  @Test("Screenshot previews remain inside the target display",
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
    #expect(frame.minX >= visibleFrame.midX || frame.width > visibleFrame.width / 2)
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
