import AppKit
import Defaults
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct ScreenshotSelectionTests {
  @Test("Long screenshot editor clamps extreme drags and keeps mosaic and crop ranges valid")
  func auditScrollingEditorDrags() throws {
    let context = try #require(CGContext(
      data: nil, width: 32, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try #require(context.makeImage())
    let panel = ScrollingScreenshotPanel(
      beside: .zero, bounds: NSRect(x: 0, y: 0, width: 1000, height: 800), level: 10
    )
    defer { panel.close() }
    panel.showEditor(image, width: 32, height: 64, frame: NSRect(x: 20, y: 20, width: 330, height: 410))
    func scrollViews(_ view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
    let content = try #require(panel.contentView)
    let editor = try #require(scrollViews(content).first?.documentView)
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      ))
    }
    editor.mouseDown(with: try event(.leftMouseDown, NSPoint(x: editor.bounds.midX, y: 42)))
    for point in [NSPoint(x: CGFloat.nan, y: 45), NSPoint(x: CGFloat.infinity, y: 45),
                  NSPoint(x: -100_000, y: 100_000)] {
      editor.mouseDragged(with: try event(.leftMouseDragged, point))
    }
    editor.mouseUp(with: try event(.leftMouseUp, .zero))
    let mosaic = try #require(panel.edit)
    #expect(!mosaic.cells.isEmpty)
    #expect(mosaic.cells.allSatisfy { $0.x >= 0 && $0.y >= 0 &&
      $0.x * mosaic.blockSize < mosaic.width && $0.y * mosaic.blockSize < mosaic.height })
    editor.mouseDown(with: try event(.leftMouseDown, NSPoint(x: editor.bounds.midX - 16, y: 10)))
    editor.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: editor.bounds.midX, y: CGFloat.nan)))
    editor.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: editor.bounds.midX, y: 26)))
    editor.mouseUp(with: try event(.leftMouseUp, .zero))
    let cropped = try #require(panel.edit)
    #expect(!cropped.rows.isEmpty && cropped.rows.lowerBound > 0 && cropped.rows.upperBound == 64)
  }

  @Test("Long capture backs off only after four unchanged frames and changed outcomes reset it")
  func scrollingCadence() {
    var cadence = ScrollingScreenshotCadence()
    #expect(cadence.delay(after: .appended, elapsed: .milliseconds(30)) == .milliseconds(20))
    for _ in 0..<3 {
      #expect(cadence.delay(after: .unchanged, elapsed: .milliseconds(30)) == .milliseconds(20))
      #expect(!cadence.isIdle)
    }
    for _ in 0..<8 {
      #expect(cadence.delay(after: .unchanged, elapsed: .milliseconds(30)) == .milliseconds(120))
      #expect(cadence.isIdle)
    }
    for result: ScrollingScreenshotStitcher.AppendResult in [.appended, .unmatched, .upward, .capped, .invalid] {
      #expect(cadence.delay(after: result, elapsed: .milliseconds(30)) == .milliseconds(20))
      #expect(!cadence.isIdle)
      for _ in 0..<4 { _ = cadence.delay(after: .unchanged, elapsed: .zero) }
    }
    #expect(cadence.delay(after: .appended, elapsed: .milliseconds(80)) == .milliseconds(17))
    #expect(cadence.delay(after: .unmatched, elapsed: .milliseconds(48)) == .milliseconds(17))
    #expect(cadence.delay(after: .appended, elapsed: .milliseconds(-10)) == .milliseconds(50))
  }

  @Test("Long capture panel prefers below, above, right, then left and stays on its visible screen")
  func scrollingPanelPlacement() {
    let bounds = NSRect(x: 0, y: 0, width: 1000, height: 800)
    let size = NSSize(width: 300, height: 240)
    let cases: [(NSRect, NSRect)] = [
      (.init(x: 100, y: 400, width: 400, height: 200), .init(x: 150, y: 152, width: 300, height: 240)),
      (.init(x: 100, y: 20, width: 400, height: 200), .init(x: 150, y: 228, width: 300, height: 240)),
      (.init(x: 100, y: 560, width: 400, height: 220), .init(x: 150, y: 312, width: 300, height: 240)),
      (.init(x: 50, y: 0, width: 500, height: 800), .init(x: 558, y: 280, width: 300, height: 240)),
      (.init(x: 450, y: 0, width: 500, height: 800), .init(x: 142, y: 280, width: 300, height: 240)),
      (.init(x: 0, y: 240, width: 1000, height: 560), .init(x: 350, y: 0, width: 300, height: 240))
    ]
    for (selection, expected) in cases {
      let frame = ScrollingScreenshotPanel.placement(beside: selection, bounds: bounds, size: size)
      #expect(frame == expected)
      #expect(bounds.contains(frame))
      #expect(!frame.intersects(selection))
      let offset = NSPoint(x: -1200, y: 300)
      #expect(ScrollingScreenshotPanel.placement(
        beside: selection.offsetBy(dx: offset.x, dy: offset.y),
        bounds: bounds.offsetBy(dx: offset.x, dy: offset.y), size: size
      ) == expected.offsetBy(dx: offset.x, dy: offset.y))
    }
    let full = ScrollingScreenshotPanel.placement(beside: bounds, bounds: bounds, size: size)
    #expect(bounds.contains(full))
    #expect(full.intersects(bounds))
    let tiny = NSRect(x: 40, y: 30, width: 180, height: 120)
    #expect(ScrollingScreenshotPanel.placement(beside: tiny, bounds: tiny, size: size) == tiny)
    #expect(ScrollingScreenshotPanel.placement(beside: bounds, bounds: .zero, size: size) == .zero)
    #expect(ScrollingScreenshotPanel.placement(beside: bounds, bounds: bounds, size: .zero) == .zero)
  }

  @Test("Observed scrolling keeps a minimum wait, while quiet captures retain their idle backoff")
  func scrollingActivityCadence() {
    var cadence = ScrollingScreenshotCadence()
    for result: ScrollingScreenshotStitcher.AppendResult in [.appended, .unchanged, .unmatched, .reanchored] {
      #expect(cadence.delay(after: result, elapsed: .milliseconds(1), scrollIsActive: true) == .milliseconds(17))
    }
    for _ in 0..<4 { _ = cadence.delay(after: .unchanged, elapsed: .zero) }
    #expect(cadence.delay(after: .unchanged, elapsed: .milliseconds(20)) == .milliseconds(130))
  }

  @Test("Scroll events waking the capture loop cannot skip its minimum frame interval")
  func scrollingActivityWakeKeepsFrameInterval() async throws {
    var captures: [ContinuousClock.Instant] = []
    let controller = ScreenshotSelectionController(displays: { [Self.displays[0]] },
      presentWindow: { _, _ in }, captureRegion: { _, rectangle, _ in
        captures.append(.now)
        return NSImage(size: rectangle.size, flipped: false) { bounds in
          NSColor.white.setFill(); bounds.fill(); return true
        }
      }, freezeDisplays: { _ in [] }, listWindows: { [] })
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 20))
    window.selectionView.endSelection(at: NSPoint(x: 80, y: 80))
    window.onLongScreenshot?()
    let panel = try #require(window.scrollingPanel)
    for _ in 0..<100 {
      if captures.count >= 4 { break }
      panel.onScrollActivity?()
      try await Task.sleep(for: .milliseconds(2))
    }
    controller.cancel()
    _ = try await task.value
    try #require(captures.count >= 4)
    for (previous, next) in zip(captures, captures.dropFirst()) {
      #expect(previous.duration(to: next) >= .milliseconds(17))
    }
  }

  @Test("Activity monitors only observe events, tolerate missing global monitoring and remove tokens once")
  func scrollingActivityMonitor() throws {
    var local: ((NSEvent) -> NSEvent?)?
    var global: ((NSEvent) -> Void)?
    var removed = 0
    let monitor = ScrollingScreenshotActivityMonitor(addLocal: { local = $0; return NSObject() },
      addGlobal: { global = $0; return NSObject() }, remove: { _ in removed += 1 })
    var observed = 0
    monitor.start { _ in observed += 1 }
    let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
      wheelCount: 2, wheel1: -40, wheel2: 17, wheel3: 0))
    let event = try #require(NSEvent(cgEvent: cgEvent))
    #expect(local?(event) === event)
    global?(event)
    #expect(observed == 2)
    #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -40)
    #expect(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2) == 17)
    monitor.stop()
    monitor.stop()
    #expect(removed == 2)
    let unavailable = ScrollingScreenshotActivityMonitor(addLocal: { _ in nil },
      addGlobal: { _ in nil }, remove: { _ in Issue.record("Removed a nonexistent monitor") })
    unavailable.start { _ in }
    unavailable.stop()
  }

  @Test("Long capture removes its activity monitors on copy, pin, Cancel, Escape and capture errors",
        arguments: ["copy", "pin", "cancel", "escape", "error"])
  func scrollingMonitorLifecycle(action: String) async throws {
    var installed = 0
    var removed = 0
    let monitor = ScrollingScreenshotActivityMonitor(addLocal: { _ in installed += 1; return NSObject() },
      addGlobal: { _ in installed += 1; return NSObject() }, remove: { _ in removed += 1 })
    let controller = ScreenshotSelectionController(displays: { [Self.displays[0]] },
      presentWindow: { _, _ in }, captureRegion: { _, rectangle, _ in
        if action == "error" { throw ScreenshotCaptureSession.Failure.captureFailed }
        return NSImage(size: rectangle.size, flipped: false) { bounds in
          NSColor.white.setFill(); bounds.fill(); return true
        }
      }, freezeDisplays: { _ in [] }, listWindows: { [] }, makeScrollMonitor: { monitor })
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    window.selectionView.beginSelection(at: NSPoint(x: 20, y: 20))
    window.selectionView.endSelection(at: NSPoint(x: 220, y: 180))
    window.onLongScreenshot?()
    #expect(installed == 2)
    if action != "error" {
      for _ in 0..<100 {
        if window.scrollingPanel?.image != nil { break }
        try await Task.sleep(for: .milliseconds(5))
      }
      let panel = try #require(window.scrollingPanel)
      if action == "copy" || action == "pin" { panel.onFinish?(action == "pin") }
      else if action == "cancel" { panel.onCancel?() }
      else {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
          charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        panel.keyDown(with: event)
      }
    }
    _ = try await task.value
    #expect(removed == 2)
    #expect(controller.windows.isEmpty)
    controller.cancel()
    #expect(removed == 2)
  }

  @Test("Panel non-control areas pass input through without event posting and buttons remain clickable")
  func scrollingPanelWheel() throws {
    let panel = ScrollingScreenshotPanel(beside: .zero,
      bounds: NSRect(x: 0, y: 0, width: 1000, height: 800), level: 10)
    defer { panel.close() }
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    func buttons(_ view: NSView) -> [NSButton] {
      (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let button = try #require(buttons(content).first)
    let frame = panel.convertToScreen(button.convert(button.bounds, to: nil))
    panel.updateMousePassthrough(at: NSPoint(x: frame.midX, y: frame.midY))
    #expect(!panel.ignoresMouseEvents)
    panel.updateMousePassthrough(at: NSPoint(x: panel.frame.midX, y: panel.frame.maxY - 40))
    #expect(panel.ignoresMouseEvents)
    #expect(ScrollingScreenshotPanel.ignoresMouse(at: .zero, controls: []))
    panel.close()
  }

  @Test("Long capture panel monitors follow visibility across direct ordering and close")
  func scrollingPanelMonitorLifecycle() {
    let panel = ScrollingScreenshotPanel(beside: .zero,
      bounds: NSRect(x: 0, y: 0, width: 1000, height: 800), level: 10)
    defer { panel.close() }
    #expect(!panel.isMonitoringScrollEvents)
    panel.orderFrontRegardless()
    #expect(panel.isMonitoringScrollEvents)
    panel.orderOut(nil)
    #expect(!panel.isMonitoringScrollEvents)
    panel.orderFrontRegardless()
    #expect(panel.isMonitoringScrollEvents)
    panel.order(.out, relativeTo: 0)
    #expect(!panel.isMonitoringScrollEvents)
    panel.orderFrontRegardless()
    #expect(panel.isMonitoringScrollEvents)
    panel.close()
    #expect(!panel.isMonitoringScrollEvents)
  }

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

  @Test("Hover failures back off exponentially to eight seconds", arguments: [false, true])
  func probeBackoffGrowth(timeout: Bool) {
    var backoff = ScreenshotProbeBackoff()
    var now: TimeInterval = 100
    for delay: TimeInterval in [0.5, 1, 2, 4, 8, 8, 8] {
      expectProbe(backoff.begin(pid: 1, now: now))
      if timeout { backoff.timeOut(pid: 1, now: now) }
      backoff.complete(pid: 1, outcome: .cannotComplete, now: now)
      expectProbe(!backoff.begin(pid: 1, now: now + delay - 0.001))
      now += delay
    }
    expectProbe(backoff.begin(pid: 1, now: now))
  }

  @Test("Successful hover probes reset the app's failure history")
  func probeBackoffReset() {
    var backoff = ScreenshotProbeBackoff()
    expectProbe(backoff.begin(pid: 1, now: 0))
    backoff.complete(pid: 1, outcome: .cannotComplete, now: 0)
    expectProbe(backoff.begin(pid: 1, now: 0.5))
    backoff.complete(pid: 1, outcome: .success, now: 0.5)
    expectProbe(backoff.begin(pid: 1, now: 0.5))
    backoff.complete(pid: 1, outcome: .cannotComplete, now: 0.5)
    expectProbe(!backoff.begin(pid: 1, now: 0.999))
    expectProbe(backoff.begin(pid: 1, now: 1))
  }

  @Test("Native calls keep their per-app slot after timeout and other apps are independent")
  func probeBackoffInFlight() {
    var backoff = ScreenshotProbeBackoff()
    expectProbe(backoff.begin(pid: 1, now: 0))
    expectProbe(!backoff.begin(pid: 1, now: 0))
    backoff.timeOut(pid: 1, now: 1)
    backoff.timeOut(pid: 1, now: 2)
    expectProbe(!backoff.begin(pid: 1, now: 100))
    expectProbe(backoff.begin(pid: 2, now: 100))
    backoff.complete(pid: 2, outcome: .success, now: 100)
    expectProbe(!backoff.complete(pid: 1, outcome: .success, now: 100))
    expectProbe(!backoff.begin(pid: 1, now: 100.499))
    expectProbe(backoff.begin(pid: 1, now: 100.5))
    backoff.complete(pid: 1, outcome: .cannotComplete, now: 100.5)
    expectProbe(!backoff.begin(pid: 1, now: 101.499))
    expectProbe(backoff.begin(pid: 2, now: 100.5))
    expectProbe(backoff.begin(pid: 1, now: 101.5))
  }

  @Test("Timed out native calls keep their slot across pointer moves and fall back to window bounds")
  func timedOutHoverProbe() async throws {
    #expect(ScreenshotElementDetection.applicationMessagingTimeout > 0)
    #expect(ScreenshotElementDetection.applicationMessagingTimeout <= 0.25)
    #expect(ScreenshotElementDetection.elementMessagingTimeout > 0)
    #expect(ScreenshotElementDetection.elementMessagingTimeout <= 0.25)
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    defer { view.finishInteraction() }
    let left = NSRect(x: 0, y: 0, width: 200, height: 300)
    let right = NSRect(x: 200, y: 0, width: 200, height: 300)
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    let otherChild = NSRect(x: 220, y: 30, width: 60, height: 30)
    let worker = SelectionProbeWorker()
    defer { worker.release.signal() }
    view.findElementWindow = { point in .init(pid: point.x < 200 ? 1 : 2, frame: point.x < 200 ? left : right) }
    view.findElements = { _, window in
      if window.pid == 1 {
        worker.run()
        return .init(rectangles: [child])
      }
      return .init(rectangles: [otherChild])
    }
    try hover(view, x: 50)
    try await Task.sleep(for: ScreenshotElementProbe.timeout + .milliseconds(100))
    #expect(view.snapRectangle(near: NSPoint(x: 50, y: 40)) == left)
    for x in stride(from: 60, through: 150, by: 10) {
      try hover(view, x: CGFloat(x))
      #expect(view.snapRectangle(near: NSPoint(x: x, y: 40)) == left)
    }
    #expect(worker.calls == 1)
    try hover(view, x: 250)
    for _ in 0..<100 {
      if view.snapRectangle(near: NSPoint(x: 250, y: 40)) == otherChild { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: NSPoint(x: 250, y: 40)) == otherChild)
    worker.release.signal()
    try await Task.sleep(for: .milliseconds(100))
    try hover(view, x: 60)
    #expect(view.snapRectangle(near: NSPoint(x: 60, y: 40)) == left)
    #expect(worker.calls == 1)
    try await Task.sleep(for: .milliseconds(550))
    try hover(view, x: 66)
    for _ in 0..<100 {
      if view.snapRectangle(near: NSPoint(x: 66, y: 40)) == child { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: NSPoint(x: 66, y: 40)) == child)
    #expect(worker.calls == 2)
  }

  @Test("Window snapshots load off-main once per selection, including empty and live overlays",
        arguments: [false, true], [false, true])
  func selectionWindowSnapshot(frozen: Bool, empty: Bool) async throws {
    let source = SelectionProbeWorker()
    defer { source.release.signal() }
    let nativeFrame = NSRect(x: 10, y: 20, width: 200, height: 100)
    let localFrame = NSRect(x: 10, y: 480, width: 200, height: 100)
    let snapshot: [ScreenshotElementDetection.Window] = empty ? [] : [.init(pid: 1, frame: nativeFrame)]
    let image = frozen ? try colorPickerImage() : nil
    let controller = controller(frozen: [image, nil], listWindows: {
      #expect(!Thread.isMainThread)
      source.run()
      return snapshot
    })
    defer { controller.cancel() }
    let selection = Task { try await controller.select(pinImmediately: false) }
    for _ in 0..<100 {
      if source.calls > 0 { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(source.calls == 1)
    #expect(!controller.isSelecting)
    source.release.signal()
    try await waitForSelection(controller)
    let view = try #require(controller.windows.first?.selectionView)
    view.elementProbe = ScreenshotElementProbe()
    let probes = SelectionProbeWorker()
    probes.release.signal()
    view.findElements = { _, window in
      probes.run()
      return .init(rectangles: [window.frame], outcome: .cannotComplete)
    }
    view.moveHover(to: NSPoint(x: 50, y: 500))
    for _ in 0..<100 {
      if empty || view.snapRectangle(near: NSPoint(x: 50, y: 500)) != nil { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    for x in stride(from: 60, through: 150, by: 5) {
      let point = NSPoint(x: x, y: 500)
      #expect(view.findElementWindow?(point)?.frame == (empty ? nil : localFrame))
      view.moveHover(to: point)
      #expect(view.snapRectangle(near: point) == (empty ? nil : localFrame))
    }
    #expect(source.calls == 1)
    #expect(probes.calls == (empty ? 0 : 1))
    controller.cancel()
    #expect(try await selection.value == nil)
    let nextSelection = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    #expect(source.calls == 2)
    controller.cancel()
    #expect(try await nextSelection.value == nil)
  }

  @Test("Late probe results cannot replace a newer hover generation", arguments: [false, true])
  func hoverProbeGeneration(returnToFirstApp: Bool) async throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    defer { view.finishInteraction() }
    let left = NSRect(x: 0, y: 0, width: 200, height: 300)
    let right = NSRect(x: 200, y: 0, width: 200, height: 300)
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    let otherChild = NSRect(x: 220, y: 30, width: 60, height: 30)
    let worker = SelectionProbeWorker()
    defer { worker.release.signal() }
    view.findElementWindow = { point in .init(pid: point.x < 200 ? 1 : 2, frame: point.x < 200 ? left : right) }
    view.findElements = { _, window in
      if window.pid == 1 {
        worker.run()
        return .init(rectangles: [child])
      }
      return .init(rectangles: [otherChild])
    }
    try hover(view, x: 50)
    try hover(view, x: 250)
    for _ in 0..<100 {
      if view.snapRectangle(near: NSPoint(x: 250, y: 40)) == otherChild { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(view.snapRectangle(near: NSPoint(x: 250, y: 40)) == otherChild)
    if returnToFirstApp { try hover(view, x: 50) }
    worker.release.signal()
    try await Task.sleep(for: .milliseconds(100))
    let point = NSPoint(x: returnToFirstApp ? 50 : 250, y: 40)
    #expect(view.snapRectangle(near: point) == (returnToFirstApp ? left : otherChild))
    #expect(worker.calls == 1)
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
    let source = try #require(selection.image)
    #expect(source.width == image.width && source.height == image.height)
    if pin {
      #expect(selection.previewImage == nil)
    } else {
      let thumbnail = try #require(selection.previewImage)
      #expect(thumbnail.width <= 440 && thumbnail.height <= 300)
      let fullImage = NSImage(cgImage: source, size: .zero)
      let displayedImage = ScreenshotCapture.previewImage(for: fullImage, thumbnail: thumbnail)
      #expect(displayedImage !== fullImage)
      #expect(displayedImage.size.width <= CGFloat(thumbnail.width))
      #expect(displayedImage.size.height <= CGFloat(thumbnail.height))
    }
    #expect(image.width > preview.width && image.height > preview.height)
    #expect(selection.renderedScale == CGSize(width: 2, height: 2))
    #expect(selection.pinToScreen == pin)
    #expect(controller.windows.isEmpty && !panel.isVisible)
  }

  @Test("Finishing a long capture without an image closes every overlay")
  func scrollingEmptyOutput() async throws {
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
    for _ in 0..<100 where controller.isSelecting {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(!controller.isSelecting)
    #expect(try await task.value == nil)
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

  @Test("A drag ignores nonfinite AppKit pointer coordinates")
  func invalidSelectionDrag() throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    defer { view.finishInteraction() }
    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
      try #require(NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1
      ))
    }
    let invalid = NSPoint(x: CGFloat.nan, y: 120)
    var begins = 0
    var finished: NSRect?
    view.onBegin = { begins += 1 }
    view.onValidSelection = { finished = $0 }
    view.mouseDown(with: try event(.leftMouseDown, at: invalid))
    #expect(begins == 0)
    view.mouseDown(with: try event(.leftMouseDown, at: NSPoint(x: 50, y: 50)))
    view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 100, y: 100)))
    let selected = try #require(view.selectedRect)
    view.mouseMoved(with: try event(.mouseMoved, at: invalid))
    view.mouseDragged(with: try event(.leftMouseDragged, at: invalid))
    #expect(view.selectedRect == selected)
    view.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: 150, y: 125)))
    let expected = NSRect(x: 50, y: 50, width: 100, height: 75)
    #expect(view.selectedRect == expected)
    view.mouseUp(with: try event(.leftMouseUp, at: invalid))
    #expect(finished == expected)
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

  @Test("Adjacent selections share raster edges in a scaled display mode, including a frozen crop")
  func scaledDisplayPixels() throws {
    let frame = CGRect(x: -1200, y: 300, width: 3, height: 4)
    let display = ScreenshotSelectionController.Display(
      frame: frame, captureFrame: frame, scale: 2, modePixelSize: CGSize(width: 8, height: 10)
    )
    let left = CGRect(x: frame.minX, y: frame.minY, width: 1, height: 4)
    let right = CGRect(x: frame.minX + 1, y: frame.minY, width: 2, height: 4)
    let leftPixels = display.pixelBounds(for: left)
    let rightPixels = display.pixelBounds(for: right)
    #expect(leftPixels == CGRect(x: 0, y: 0, width: 3, height: 10))
    #expect(rightPixels == CGRect(x: 3, y: 0, width: 5, height: 10))
    #expect(leftPixels.union(rightPixels).size == display.pixelSize)

    let frozen = try colorPickerImage()
    let crop = try #require(ScreenshotSelectionController.crop(frozen, to: right, display: display))
    #expect(crop.width == 1 && crop.height == 2)
    #expect(ScreenshotPixelLoupe.sample(crop, at: .zero)?.hex == "#04A0FF")
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
    #expect(presentation.allSatisfy { $0.window.animationBehavior == .none })
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

  @Test("Tapping C copies the remembered format, Shift-C copies RGB, and Command-C remains a capture shortcut",
        arguments: [false, true])
  func copyLoupeColor(rgb: Bool) throws {
    let saved = Defaults[.screenshotColorFormat]
    defer { Defaults[.screenshotColorFormat] = saved }
    Defaults[.screenshotColorFormat] = "hex"
    let view = try colorPickerView()
    defer { view.finishInteraction() }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(try !view.handleColorShortcut(colorKey(.keyDown, "c", 8, .command), to: pasteboard))
    #expect(try view.handleColorShortcut(colorKey(.keyDown, "c", 8, rgb ? .shift : []), to: pasteboard))
    #expect(view.isPickingColor)
    #expect(pasteboard.string(forType: .string) == nil)
    #expect(try view.handleColorShortcut(colorKey(.keyUp, "c", 8, rgb ? .shift : []), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == (rgb ? "rgb(4, 160, 255)" : "#04A0FF"))
    #expect(!view.isPickingColor)
    #expect(Defaults[.screenshotColorFormat] == "hex")
  }

  @Test("Holding C cycles formats with Space, Tab, Shift-Tab and digits, and releasing C copies the shown one")
  func cycleLoupeColorFormat() throws {
    let saved = Defaults[.screenshotColorFormat]
    defer { Defaults[.screenshotColorFormat] = saved }
    Defaults[.screenshotColorFormat] = "hex"
    let view = try colorPickerView()
    defer { view.finishInteraction() }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    view.keyDown(with: try colorKey(.keyDown, "c", 8))
    view.keyDown(with: try colorKey(.keyDown, "c", 8, repeating: true))
    view.keyDown(with: try colorKey(.keyDown, " ", 49))
    view.keyDown(with: try colorKey(.keyDown, "c", 8, repeating: true))
    view.keyDown(with: try colorKey(.keyDown, "\t", 48))
    view.keyDown(with: try colorKey(.keyDown, "\t", 48))
    view.keyDown(with: try colorKey(.keyDown, "\t", 48, .shift))
    view.keyDown(with: try colorKey(.keyDown, "\r", 36))
    #expect(view.isPickingColor)
    #expect(view.selectedRect == nil)
    #expect(try !view.handleColorShortcut(colorKey(.keyUp, " ", 49), to: pasteboard))
    #expect(try view.handleColorShortcut(colorKey(.keyUp, "c", 8), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "hsl(203, 100%, 51%)")
    #expect(Defaults[.screenshotColorFormat] == "hsl")

    let next = try colorPickerView()
    defer { next.finishInteraction() }
    #expect(try next.handleColorShortcut(colorKey(.keyDown, "c", 8), to: pasteboard))
    #expect(try next.handleColorShortcut(colorKey(.keyDown, "4", 21), to: pasteboard))
    #expect(try next.handleColorShortcut(colorKey(.keyUp, "c", 8), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "Color(red: 0.016, green: 0.627, blue: 1.000)")
    #expect(Defaults[.screenshotColorFormat] == "swiftUI")
  }

  @Test("Space wraps from the last format to the first and Shift-Tab wraps back")
  func colorFormatWraps() throws {
    #expect(try ScreenshotSelectionView.colorFormat(after: .nsColor, for: colorKey(.keyDown, " ", 49)) == .hex)
    #expect(try ScreenshotSelectionView.colorFormat(after: .hex, for: colorKey(.keyDown, "\t", 48, .shift)) == .nsColor)
    #expect(try ScreenshotSelectionView.colorFormat(after: .hex, for: colorKey(.keyDown, "5", 23)) == .nsColor)
    #expect(try ScreenshotSelectionView.colorFormat(after: .hex, for: colorKey(.keyDown, "6", 22)) == nil)
    #expect(try ScreenshotSelectionView.colorFormat(after: .hex, for: colorKey(.keyDown, "\t", 48, .option)) == nil)
  }

  @Test("The color picker ignores invalid numeric key input and still copies the selected format",
        arguments: [String(Int.min), "-1", "0", "6", "01", "+1", "12"])
  func colorPickerIgnoresInvalidNumericKey(_ key: String) throws {
    let view = try colorPickerView()
    defer { view.finishInteraction() }
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(try view.handleColorShortcut(colorKey(.keyDown, "c", 8, .shift), to: pasteboard))
    #expect(try view.handleColorShortcut(colorKey(.keyDown, key, 23), to: pasteboard))
    #expect(try view.handleColorShortcut(colorKey(.keyUp, "c", 8, .shift), to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "rgb(4, 160, 255)")
  }

  @Test("Each color format produces text that pastes into CSS or Swift")
  func colorFormats() {
    let color = ScreenshotPixelLoupe.Color(red: 4, green: 160, blue: 255)
    #expect(color.string(in: .hex) == "#04A0FF")
    #expect(color.string(in: .rgb) == "rgb(4, 160, 255)")
    #expect(color.string(in: .hsl) == "hsl(203, 100%, 51%)")
    #expect(color.string(in: .swiftUI) == "Color(red: 0.016, green: 0.627, blue: 1.000)")
    #expect(color.string(in: .nsColor) == "NSColor(srgbRed: 0.016, green: 0.627, blue: 1.000, alpha: 1)")
    #expect(ScreenshotPixelLoupe.Color(red: 0, green: 0, blue: 0).hsl == "hsl(0, 0%, 0%)")
    #expect(ScreenshotPixelLoupe.Color(red: 255, green: 255, blue: 255).hsl == "hsl(0, 0%, 100%)")
    #expect(ScreenshotPixelLoupe.Color(red: 128, green: 128, blue: 128).hsl == "hsl(0, 0%, 50%)")
    #expect(ScreenshotPixelLoupe.Color(red: 255, green: 0, blue: 128).hsl == "hsl(330, 100%, 50%)")
    #expect(ScreenshotPixelLoupe.Color(red: 255, green: 0, blue: 1).hsl == "hsl(0, 100%, 50%)")
    #expect(ScreenshotPixelLoupe.Color(red: 0, green: 255, blue: 0).hsl == "hsl(120, 100%, 50%)")
    #expect(ScreenshotPixelLoupe.Color(red: 10, green: 20, blue: 30).hsl == "hsl(210, 50%, 8%)")
  }

  private func colorPickerView() throws -> ScreenshotSelectionView {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 100, height: 100), scale: 1, pinImmediately: false
    )
    view.setFrozenImage(try colorPickerImage())
    view.moveHover(to: NSPoint(x: 75, y: 75))
    return view
  }

  private func colorKey(
    _ type: NSEvent.EventType, _ key: String, _ code: UInt16,
    _ modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false
  ) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
      windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
      isARepeat: repeating, keyCode: code
    ))
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
    view.findElementWindow = { _ in .init(pid: 1, frame: parent) }
    view.findElements = { _, _ in .init(rectangles: [child, parent]) }
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
    view.findElementWindow = { _ in .init(pid: 1, frame: parent) }
    view.findElements = { _, _ in .init(rectangles: [child, parent]) }
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

  @Test("Finishing during a hover probe leaves the view free to probe again after native completion")
  func probeAfterCancelledProbe() async throws {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 400, height: 300), scale: 2, pinImmediately: false
    )
    let child = NSRect(x: 20, y: 30, width: 60, height: 30)
    view.findElementWindow = { _ in .init(pid: 1, frame: child) }
    view.findElements = { _, _ in .init(rectangles: [child]) }
    let first = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: NSPoint(x: 50, y: 40), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: first)
    view.finishInteraction()
    try await Task.sleep(for: .milliseconds(100))
    view.findElementWindow = { _ in .init(pid: 1, frame: child) }
    view.findElements = { _, _ in .init(rectangles: [child]) }
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
    view.findElementWindow = { _ in .init(pid: 1, frame: NSRect(x: 0, y: 0, width: 400, height: 300)) }
    view.findElements = { _, _ in .init(rectangles: []) }
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

  @Test("The Escape fallback cancels selection when the event is not routed to a capture window")
  func fallbackEscapeCancellation() async throws {
    let controller = controller()
    defer { controller.cancel() }
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let window = try #require(controller.windows.first)
    let event = try #require(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
      characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53
    ))
    #expect(!controller.handleFallbackEscape(event, target: window))
    #expect(controller.isSelecting)
    try #require(controller.handleFallbackEscape(event, target: nil))
    #expect(try await task.value == nil)
    #expect(controller.windows.isEmpty)
    #expect(!controller.handleFallbackEscape(event, target: nil))
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

  @Test("Window hover snaps immediately and Shift selection tracks IDs and clips the on-screen union")
  func windowCascadeSelection() {
    let view = ScreenshotSelectionView(
      frame: NSRect(x: 0, y: 0, width: 300, height: 200), scale: 1, pinImmediately: false
    )
    let main = ScreenshotElementDetection.Window(pid: 10, frame: CGRect(x: 10, y: 30, width: 210, height: 160), id: 1)
    let menu = ScreenshotElementDetection.Window(pid: 10, frame: CGRect(x: 160, y: 150, width: 160, height: 80), id: 2)
    view.findElementWindow = { point in [menu, main].first { $0.frame.contains(point) } }
    let mainPoint = NSPoint(x: 40, y: 100)
    #expect(view.snapRectangle(near: mainPoint) == main.frame)
    view.beginSelection(at: mainPoint)
    view.endSelection(at: mainPoint)
    #expect(view.selectedWindows == [main])
    view.toggleWindow(menu)
    #expect(view.selectedWindows == [main, menu])
    #expect(view.selectedRect == CGRect(x: 10, y: 30, width: 290, height: 170))
    view.toggleWindow(main)
    #expect(view.selectedRect == CGRect(x: 160, y: 150, width: 140, height: 50))
    view.toggleWindow(menu)
    #expect(view.selectedRect == nil)
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
    listWindows: @escaping @Sendable () -> [ScreenshotElementDetection.Window] = {
      ScreenshotElementDetection.windows()
    },
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
    }, freezeDisplays: { _ in frozen }, listWindows: listWindows)
  }

  private func waitForSelection(_ controller: ScreenshotSelectionController) async throws {
    for _ in 0..<100 {
      if controller.isSelecting { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Selection did not start")
    throw CancellationError()
  }

  private func hover(_ view: ScreenshotSelectionView, x: CGFloat) throws {
    let event = try #require(NSEvent.mouseEvent(
      with: .mouseMoved, location: NSPoint(x: x, y: 40), modifierFlags: [],
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
    ))
    view.mouseMoved(with: event)
  }

  private func expectProbe(_ condition: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(condition, sourceLocation: sourceLocation)
  }
}

nonisolated private final class SelectionProbeWorker: @unchecked Sendable {
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0

  var calls: Int { lock.withLock { count } }

  func run() {
    let first = lock.withLock {
      count += 1
      return count == 1
    }
    if first { release.wait() }
  }
}
