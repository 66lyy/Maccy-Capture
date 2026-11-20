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

    func hasSameLayout(as other: Display) -> Bool {
      displayID == other.displayID && frame == other.frame && captureFrame == other.captureFrame
        && scale == other.scale
    }

    static func sameLayout(_ lhs: [Display], _ rhs: [Display]) -> Bool {
      lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.hasSameLayout(as: $1) }
    }

    static func current() -> [Display] {
      NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
          return nil
        }
        return Display(
          frame: screen.frame, captureFrame: CGDisplayBounds(number.uint32Value), scale: screen.backingScaleFactor,
          displayID: number.uint32Value, visibleFrame: screen.visibleFrame
        )
      }
    }
  }

  struct Selection: Equatable {
    let captureRect: NSRect
    let anchor: NSPoint
    let pinToScreen: Bool
    var renderedData: Data?
    var image: CGImage?
    var renderedScale: CGFloat?

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
  private let freezeDisplays: @MainActor ([Display]) async -> [CGImage?]
  private var isFreezing = false
  private var continuation: CheckedContinuation<Selection?, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?
  private var scrollingTask: Task<Void, Never>?

  init(
    displays: @escaping @MainActor () -> [Display] = { Display.current() },
    pointerLocation: @escaping @MainActor () -> NSPoint = { NSEvent.mouseLocation },
    presentWindow: @escaping @MainActor (ScreenshotSelectionWindow, Bool) -> Void = { window, wantsKeyboard in
      window.orderFrontRegardless()
      if wantsKeyboard { window.makeKey() }
    },
    captureRegion: @escaping @MainActor (Display, NSRect, Set<CGWindowID>) async throws -> NSImage = {
      try await ScreenshotCaptureSession.captureSelection(on: $0, rectangle: $1, excluding: $2)
    },
    freezeDisplays: @escaping @MainActor ([Display]) async -> [CGImage?] = {
      await ScreenshotCaptureSession.captureDisplays($0)
    }
  ) {
    self.displays = displays
    self.pointerLocation = pointerLocation
    self.presentWindow = presentWindow
    self.captureRegion = captureRegion
    self.freezeDisplays = freezeDisplays
  }

  func select(pinImmediately: Bool, timeout: Duration = .seconds(120)) async throws -> Selection? {
    guard !isSelecting, !isFreezing else { throw ScreenshotCaptureSession.Failure.alreadyCapturing }
    try Task.checkCancellation()
    let availableDisplays = displays()
    guard !availableDisplays.isEmpty else { throw ScreenshotCaptureSession.Failure.captureFailed }
    isFreezing = true
    let frozenWindows = ScreenshotElementDetection.windows()
    let frozen = await freezeDisplays(availableDisplays)
    isFreezing = false
    try Task.checkCancellation()
    guard Display.sameLayout(availableDisplays, displays()) else { return nil }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        windows = availableDisplays.enumerated().map { index, display in
          makeWindow(
            display: display, frozen: index < frozen.count ? frozen[index] : nil, frozenWindows: frozenWindows,
            pinImmediately: pinImmediately
          )
        }
        screenObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self, !Display.sameLayout(availableDisplays, self.displays()) else { return }
            self.cancel()
          }
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

  static func crop(_ frozen: CGImage, to captureRect: NSRect, display: Display) -> CGImage? {
    let source = ScreenshotCaptureSession.sourceRectangle(captureRect, displayFrame: display.captureFrame)
    guard display.captureFrame.width > 0, display.captureFrame.height > 0 else { return nil }
    let scaleX = CGFloat(frozen.width) / display.captureFrame.width
    let scaleY = CGFloat(frozen.height) / display.captureFrame.height
    let pixels = NSRect(
      x: source.minX * scaleX, y: source.minY * scaleY, width: source.width * scaleX, height: source.height * scaleY
    ).integral
    return frozen.cropping(to: pixels)
  }

  private func makeWindow(
    display: Display, frozen: CGImage?, frozenWindows: [ScreenshotElementDetection.Window], pinImmediately: Bool
  ) -> ScreenshotSelectionWindow {
    let window = ScreenshotSelectionWindow(
      frame: display.frame, visibleFrame: display.visibleFrame ?? display.frame,
      scale: display.scale, pinImmediately: pinImmediately, frozen: frozen
    )
    window.onCancel = { [weak self, weak window] in self?.finish(nil, closingWindow: window) }
    window.selectionView.movePointer = { point in
      CGWarpMouseCursorPosition(CGPoint(
        x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y
      ))
    }
    let elementWindows = frozen == nil ? nil : frozenWindows
    window.selectionView.findElements = { point in
      let global = NSPoint(x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y)
      return ScreenshotElementDetection.rectangles(at: global, in: elementWindows).map {
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
      self?.windows.allSatisfy { $0.canvas == nil && !$0.isPreparingImage && !$0.selectionView.isScrolling } ?? false
    }
    func selection(_ rectangle: NSRect, pinToScreen: Bool, data: Data? = nil) -> Selection {
      let captureRect = Self.captureRectangle(rectangle, display: display)
      let screenRect = Self.screenRectangle(captureRect, display: display)
      return Selection(
        captureRect: captureRect,
        anchor: NSPoint(x: screenRect.midX, y: screenRect.midY),
        pinToScreen: pinToScreen, renderedData: data,
        image: data == nil ? frozen.flatMap { Self.crop($0, to: captureRect, display: display) } : nil
      )
    }
    window.selectionView.onCapture = { [weak self] rectangle, pinToScreen in
      self?.finish(selection(rectangle, pinToScreen: pinToScreen))
    }
    window.onLongScreenshot = { [weak self, weak window] in
      guard let self, let window, let rectangle = window.selectionView.selectedRect,
            scrollingTask == nil else { return }
      timeoutTask?.cancel()
      timeoutTask = nil
      for overlay in windows {
        overlay.ignoresMouseEvents = true
        overlay.selectionView.frozen = nil
        overlay.selectionView.isScrolling = true
        overlay.annotationToolbar.isHidden = true
      }
      let screenRect = rectangle.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
      let panel = ScrollingScreenshotPanel(
        beside: screenRect, bounds: display.visibleFrame ?? display.frame, level: window.level.rawValue + 1
      )
      window.scrollingPanel = panel
      panel.onCancel = { [weak self] in self?.cancel() }
      panel.onFinish = { [weak self, weak panel] pin in
        guard let self, let image = panel?.stitcher?.image,
              let data = ScreenshotAnnotationDocument.RenderSnapshot.pngData(image) else { return }
        var result = selection(rectangle, pinToScreen: pin, data: data)
        result.renderedScale = display.scale
        finish(result)
      }
      panel.orderFrontRegardless()
      panel.makeKey()
      let captureRect = Self.captureRectangle(rectangle, display: display)
      scrollingTask = Task { [weak self, weak panel] in
        var lastThumbnailUpdate: ContinuousClock.Instant?
        var thumbnailNeedsUpdate = false
        while !Task.isCancelled {
          guard let self, let panel, isSelecting else { return }
          let ids = Set((windows.map(\.windowNumber) + [panel.windowNumber]).compactMap { CGWindowID(exactly: $0) })
          do {
            let frame = try await captureRegion(display, captureRect, ids)
            guard !Task.isCancelled, isSelecting else { return }
            guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
              throw ScreenshotCaptureSession.Failure.captureFailed
            }
            if panel.stitcher == nil {
              guard cgImage.width > 0, cgImage.height > 0,
                    cgImage.width <= ScreenshotImageLimits.maximumPixels / cgImage.height else {
                throw ScreenshotCaptureSession.Failure.captureFailed
              }
              panel.stitcher = ScrollingScreenshotStitcher(
                width: cgImage.width, height: cgImage.height, maximumPixels: ScreenshotImageLimits.maximumPixels
              )
            }
            let changed = panel.stitcher?.append(cgImage) == true
            thumbnailNeedsUpdate = thumbnailNeedsUpdate || changed
            let capped = panel.stitcher?.capReached == true
            let now = ContinuousClock.now
            let refreshDue = lastThumbnailUpdate.map { $0.duration(to: now) >= .milliseconds(500) } ?? true
            if thumbnailNeedsUpdate, capped || refreshDue,
               let image = panel.stitcher?.image {
              panel.update(image, capped: capped)
              lastThumbnailUpdate = now
              thumbnailNeedsUpdate = false
            }
            if capped { return }
            try await Task.sleep(for: .milliseconds(150))
          } catch {
            if !Task.isCancelled { cancel() }
            return
          }
        }
      }
    }
    window.loadSelectionImage = { [weak self, weak window] in
      guard let self, let window, let rectangle = window.selectionView.selectedRect else { throw CancellationError() }
      let captureRect = Self.captureRectangle(rectangle, display: display)
      let globalFrame = Self.screenRectangle(captureRect, display: display)
      let localFrame = globalFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
      if let frozen {
        guard let image = Self.crop(frozen, to: captureRect, display: display) else {
          throw ScreenshotCaptureSession.Failure.captureFailed
        }
        return (NSImage(cgImage: image, size: captureRect.size), localFrame)
      }
      let overlayIDs = Set(windows.filter {
        $0.isVisible && $0.frame.intersects(window.frame)
      }.compactMap { CGWindowID(exactly: $0.windowNumber) })
      let image = try await captureRegion(display, captureRect, overlayIDs)
      return (image, localFrame)
    }
    window.onCanvasReady = { [weak self, weak window] in
      guard let self, let window else { return }
      timeoutTask?.cancel()
      timeoutTask = nil
      window.longScreenshotButton?.isHidden = true
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
    scrollingTask?.cancel()
    scrollingTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
      self.screenObserver = nil
    }
    for window in windows {
      window.scrollingPanel?.onFinish = nil
      window.scrollingPanel?.onCancel = nil
      window.scrollingPanel?.orderOut(nil)
      window.scrollingPanel?.close()
      window.scrollingPanel = nil
      window.onLongScreenshot = nil
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
