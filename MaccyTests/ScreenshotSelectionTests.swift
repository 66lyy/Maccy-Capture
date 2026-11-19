import AppKit
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct ScreenshotSelectionTests {
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
  }

  @Test("Annotation or dedicated pinning starts after every overlay closes",
        arguments: [false, true])
  func releaseActions(pinToScreen: Bool) async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: pinToScreen) }
    try await waitForSelection(controller)
    let windows = controller.windows
    #expect(windows.count == 2)
    for window in windows {
      #expect(window.level == .floating)
      #expect(!window.isOpaque)
      #expect(window.canBecomeKey)
      #expect(!window.isReleasedWhenClosed)
    }
    let view = try #require(windows.first?.selectionView)
    view.beginSelection(at: NSPoint(x: 10, y: 20))
    view.endSelection(at: NSPoint(x: 110, y: 80))
    if !pinToScreen {
      #expect(controller.isSelecting)
      view.annotateSelection()
    }
    let result = try #require(try await task.value)
    #expect(result.pinToScreen == pinToScreen)
    #expect(result.annotate == !pinToScreen)
    #expect(result.captureRect == NSRect(x: 10, y: 520, width: 100, height: 60))
    #expect(result.anchor == NSPoint(x: 60, y: 50))
    #expect(result.screenRect == NSRect(x: 10, y: 20, width: 100, height: 60))
    #expect(!controller.isSelecting)
    #expect(controller.windows.isEmpty)
    #expect(windows.allSatisfy { !$0.isVisible && $0.onCancel == nil })
    controller.cancel()
    view.captureSelection(pinToScreen: true)
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

  @Test("A normal region stays editable and does not copy the original before annotation")
  func annotateSelection() async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    let windows = controller.windows
    let view = try #require(windows.first?.selectionView)
    view.beginSelection(at: NSPoint(x: 20, y: 30))
    view.endSelection(at: NSPoint(x: 220, y: 180))
    #expect(controller.isSelecting)
    view.annotateSelection()
    let result = try #require(try await task.value)
    #expect(result.annotate)
    #expect(!result.pinToScreen)
    #expect(controller.windows.isEmpty)
    #expect(windows.allSatisfy { !$0.isVisible && $0.selectionView.onAnnotate == nil })
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
      with: .mouseMoved, location: point, modifierFlags: .option,
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
    if !useParent {
      let back = try #require(NSEvent.keyEvent(
        with: .keyDown, location: point, modifierFlags: [.option, .shift], timestamp: 0, windowNumber: 0,
        context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
      ))
      view.keyDown(with: back)
    }
    let click = try #require(NSEvent.mouseEvent(
      with: .leftMouseDown, location: point, modifierFlags: .option,
      timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ))
    view.mouseDown(with: click)
    #expect(view.selectedRect == (useParent ? parent : child))
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

  @Test("A display configuration change cancels selection without capturing")
  func displayChange() async throws {
    let controller = controller()
    let task = Task { try await controller.select(pinImmediately: false) }
    try await waitForSelection(controller)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    #expect(try await task.value == nil)
    #expect(controller.windows.isEmpty)
  }

  private func controller() -> ScreenshotSelectionController {
    ScreenshotSelectionController(displays: {
      [
        .init(
          frame: NSRect(x: 0, y: 0, width: 800, height: 600),
          captureFrame: NSRect(x: 0, y: 0, width: 800, height: 600), scale: 2
        ),
        .init(
          frame: NSRect(x: -800, y: 0, width: 800, height: 600),
          captureFrame: NSRect(x: -800, y: 0, width: 800, height: 600), scale: 1
        )
      ]
    }, presentWindow: { _ in })
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
