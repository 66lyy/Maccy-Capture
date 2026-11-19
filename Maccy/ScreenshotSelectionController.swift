import AppKit
import CoreGraphics

@MainActor
final class ScreenshotSelectionController {
  struct Display: Sendable {
    let frame: NSRect
    let captureFrame: NSRect
    let scale: CGFloat
    var displayID: CGDirectDisplayID = 0
    var visibleFrame: NSRect?
  }

  struct Selection: Equatable {
    let captureRect: NSRect
    let anchor: NSPoint
    let pinToScreen: Bool
    var renderedData: Data?

    var screenRect: NSRect {
      NSRect(
        x: anchor.x - captureRect.width / 2, y: anchor.y - captureRect.height / 2,
        width: captureRect.width, height: captureRect.height
      )
    }
  }

  private(set) var windows: [ScreenshotSelectionWindow] = []
  var isSelecting: Bool { continuation != nil }

  private let displays: @MainActor () -> [Display]
  private let pointerLocation: @MainActor () -> NSPoint
  private let presentWindow: @MainActor (ScreenshotSelectionWindow, Bool) -> Void
  private let captureRegion: @MainActor (Display, NSRect, Set<CGWindowID>) async throws -> NSImage
  private var continuation: CheckedContinuation<Selection?, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?
  private var spaceObserver: NSObjectProtocol?

  init(
    displays: @escaping @MainActor () -> [Display] = {
      NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
          return nil
        }
        return Display(
          frame: screen.frame, captureFrame: CGDisplayBounds(number.uint32Value), scale: screen.backingScaleFactor,
          displayID: number.uint32Value, visibleFrame: screen.visibleFrame
        )
      }
    },
    pointerLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
    presentWindow: @escaping @MainActor (ScreenshotSelectionWindow, Bool) -> Void = { window, wantsKeyboard in
      window.orderFrontRegardless()
      if wantsKeyboard { window.makeKey() }
    },
    captureRegion: @escaping @MainActor (Display, NSRect, Set<CGWindowID>) async throws -> NSImage = {
      try await ScreenshotCaptureSession.captureSelection(on: $0, rectangle: $1, excluding: $2)
    }
  ) {
    self.displays = displays
    self.pointerLocation = pointerLocation
    self.presentWindow = presentWindow
    self.captureRegion = captureRegion
  }

  func select(pinImmediately: Bool, timeout: Duration = .seconds(120)) async throws -> Selection? {
    guard !isSelecting else { throw ScreenshotCaptureSession.Failure.alreadyCapturing }
    try Task.checkCancellation()
    let availableDisplays = displays()
    guard !availableDisplays.isEmpty else { throw ScreenshotCaptureSession.Failure.captureFailed }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        windows = availableDisplays.map { display in
          makeWindow(display: display, pinImmediately: pinImmediately)
        }
        screenObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.cancel() }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.cancel() }
        }
        timeoutTask = Task { [weak self] in
          do {
            try await Task.sleep(for: timeout)
            self?.cancel()
          } catch {
            return
          }
        }
        let pointer = pointerLocation()
        if let keyWindow = windows.first(where: { $0.frame.contains(pointer) }) ?? windows.first {
          for window in windows where window !== keyWindow { presentWindow(window, false) }
          presentWindow(keyWindow, true)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel() }
    }
  }

  func cancel() {
    finish(nil)
  }

  static func captureRectangle(_ localRect: NSRect, display: Display) -> NSRect {
    NSRect(
      x: display.captureFrame.minX + localRect.minX,
      y: display.captureFrame.minY + display.frame.height - localRect.maxY,
      width: localRect.width,
      height: localRect.height
    ).integral
  }

  nonisolated static func screenRectangle(_ captureRect: NSRect, display: Display) -> NSRect {
    NSRect(
      x: display.frame.minX + captureRect.minX - display.captureFrame.minX,
      y: display.frame.maxY - (captureRect.maxY - display.captureFrame.minY),
      width: captureRect.width, height: captureRect.height
    )
  }

  private func makeWindow(display: Display, pinImmediately: Bool) -> ScreenshotSelectionWindow {
    let window = ScreenshotSelectionWindow(
      frame: display.frame, visibleFrame: display.visibleFrame ?? display.frame,
      scale: display.scale, pinImmediately: pinImmediately
    )
    window.onCancel = { [weak self, weak window] in self?.finish(nil, closingWindow: window) }
    window.selectionView.movePointer = { point in
      CGWarpMouseCursorPosition(CGPoint(
        x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y
      ))
    }
    window.selectionView.findElements = { point in
      let global = NSPoint(x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y)
      return ScreenshotElementDetection.rectangles(at: global).map {
        Self.screenRectangle($0, display: display).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
      }
    }
    window.selectionView.onBegin = { [weak self, weak window] in
      guard let self, let window else { return }
      for other in windows where other !== window {
        other.selectionView.clearSelection()
      }
    }
    window.selectionView.canAdjustSelection = { [weak self] in
      self?.windows.allSatisfy { $0.canvas == nil && !$0.isPreparingImage } ?? false
    }
    func selection(_ rectangle: NSRect, pinToScreen: Bool, data: Data? = nil) -> Selection {
      let captureRect = Self.captureRectangle(rectangle, display: display)
      let screenRect = Self.screenRectangle(captureRect, display: display)
      return Selection(
        captureRect: captureRect,
        anchor: NSPoint(x: screenRect.midX, y: screenRect.midY),
        pinToScreen: pinToScreen, renderedData: data
      )
    }
    window.selectionView.onCapture = { [weak self] rectangle, pinToScreen in
      self?.finish(selection(rectangle, pinToScreen: pinToScreen))
    }
    window.loadSelectionImage = { [weak self, weak window] in
      guard let self, let window, let rectangle = window.selectionView.selectedRect else { throw CancellationError() }
      let captureRect = Self.captureRectangle(rectangle, display: display)
      let globalFrame = Self.screenRectangle(captureRect, display: display)
      let overlayIDs = Set(windows.filter {
        $0.isVisible && $0.frame.intersects(window.frame)
      }.compactMap { CGWindowID(exactly: $0.windowNumber) })
      let image = try await captureRegion(display, captureRect, overlayIDs)
      return (image, globalFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
    }
    window.onCanvasReady = { [weak self, weak window] in
      guard let self, let window else { return }
      timeoutTask?.cancel()
      timeoutTask = nil
      for other in windows where other !== window { other.orderOut(nil) }
      window.invalidateCursorRects(for: window.selectionView)
    }
    window.onOutput = { [weak self, weak window] data, _, action in
      guard let self, let data, let rectangle = window?.selectionView.selectedRect else { throw CancellationError() }
      finish(selection(rectangle, pinToScreen: action == .pin, data: data))
    }
    return window
  }

  private func finish(_ selection: Selection?, closingWindow: ScreenshotSelectionWindow? = nil) {
    guard let continuation else { return }
    self.continuation = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
    if let spaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
      self.spaceObserver = nil
    }
    for window in windows {
      window.onCancel = nil
      window.selectionView.finishInteraction()
      if window !== closingWindow {
        window.orderOut(nil)
        window.close()
      }
    }
    windows.removeAll()
    continuation.resume(returning: selection)
  }
}
