import AppKit
import ApplicationServices
import CoreGraphics
import Defaults

@MainActor
final class ScreenshotSelectionController {
  struct Display: Sendable {
    let frame: NSRect
    let captureFrame: NSRect
    let scale: CGFloat
    var displayID: CGDirectDisplayID = 0
    var visibleFrame: NSRect?
    var colorSpace: CGColorSpace?
    var modePixelSize: CGSize?

    var pixelSize: CGSize {
      modePixelSize ?? CGSize(
        width: (captureFrame.width * scale).rounded(), height: (captureFrame.height * scale).rounded()
      )
    }

    func pixelBounds(for rectangle: NSRect, in rasterSize: CGSize? = nil) -> CGRect {
      let source = rectangle.intersection(captureFrame).offsetBy(dx: -captureFrame.minX, dy: -captureFrame.minY)
      return Self.pixelBounds(for: source, canvasSize: captureFrame.size, rasterSize: rasterSize ?? pixelSize)
    }

    nonisolated static func pixelBounds(for rectangle: CGRect, canvasSize: CGSize, rasterSize: CGSize) -> CGRect {
      guard !rectangle.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
      let scaleX = rasterSize.width / canvasSize.width
      let scaleY = rasterSize.height / canvasSize.height
      let x = (rectangle.minX * scaleX).rounded(), y = (rectangle.minY * scaleY).rounded()
      return CGRect(
        x: x, y: y, width: (rectangle.maxX * scaleX).rounded() - x,
        height: (rectangle.maxY * scaleY).rounded() - y
      )
    }

    func hasSameLayout(as other: Display) -> Bool {
      displayID == other.displayID && frame == other.frame && captureFrame == other.captureFrame
        && scale == other.scale && pixelSize == other.pixelSize
    }

    static func sameLayout(_ lhs: [Display], _ rhs: [Display]) -> Bool {
      lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.hasSameLayout(as: $1) }
    }

    static func current() -> [Display] {
      NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
          return nil
        }
        let id = number.uint32Value
        let captureFrame = CGDisplayBounds(id)
        let pixelSize = CGDisplayCopyDisplayMode(id).flatMap { mode -> CGSize? in
          guard mode.pixelWidth > 0, mode.pixelHeight > 0 else { return nil }
          let transposed = (mode.pixelWidth > mode.pixelHeight) != (captureFrame.width > captureFrame.height)
          return CGSize(
            width: transposed ? mode.pixelHeight : mode.pixelWidth,
            height: transposed ? mode.pixelWidth : mode.pixelHeight
          )
        }
        return Display(
          frame: screen.frame, captureFrame: captureFrame, scale: screen.backingScaleFactor,
          displayID: id, visibleFrame: screen.visibleFrame, colorSpace: screen.colorSpace?.cgColorSpace,
          modePixelSize: pixelSize
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
    var previewImage: CGImage?
    var renderedScale: CGSize?

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
  private let listWindows: @Sendable () -> [ScreenshotElementDetection.Window]
  private var isFreezing = false
  private var continuation: CheckedContinuation<Selection?, any Error>?
  private var timeoutTask: Task<Void, Never>?
  private var screenObserver: NSObjectProtocol?
  private var localEscapeMonitor: Any?
  private var globalEscapeMonitor: Any?
  private var windowCaptureTask: Task<Void, Never>?
  private var scrollingTask: Task<Void, Never>?
  private var scrollingDelayTask: Task<Void, Error>?
  private var scrollingLastActivity: ContinuousClock.Instant?
  private let makeScrollMonitor: @MainActor () -> ScrollingScreenshotActivityMonitor

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
    },
    listWindows: @escaping @Sendable () -> [ScreenshotElementDetection.Window] = {
      ScreenshotElementDetection.windows()
    },
    makeScrollMonitor: @escaping @MainActor () -> ScrollingScreenshotActivityMonitor = { .init() }
  ) {
    self.displays = displays
    self.pointerLocation = pointerLocation
    self.presentWindow = presentWindow
    self.captureRegion = captureRegion
    self.freezeDisplays = freezeDisplays
    self.listWindows = listWindows
    self.makeScrollMonitor = makeScrollMonitor
  }

  func select(pinImmediately: Bool, timeout: Duration = .seconds(120)) async throws -> Selection? {
    guard !isSelecting, !isFreezing else { throw ScreenshotCaptureSession.Failure.alreadyCapturing }
    try Task.checkCancellation()
    let availableDisplays = displays()
    guard !availableDisplays.isEmpty else { throw ScreenshotCaptureSession.Failure.captureFailed }
    isFreezing = true
    let frozenWindows = await Task.detached(priority: .userInitiated) { [listWindows] in
      listWindows()
    }.value
    let removeWindowShadow = Defaults[.screenshotRemoveWindowShadow]
    async let frozenDisplays = freezeDisplays(availableDisplays)
    async let popupSnapshots = ScreenshotCaptureSession.snapshotPopups(
      frozenWindows, on: availableDisplays, removeShadow: removeWindowShadow
    )
    let (frozen, snapshots) = await (frozenDisplays, popupSnapshots)
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
            snapshots: snapshots, pinImmediately: pinImmediately, removeWindowShadow: removeWindowShadow
          )
        }
        monitorEscape()
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
          if keyWindow.frame.contains(pointer) {
            keyWindow.selectionView.moveHover(to: NSPoint(
              x: pointer.x - keyWindow.frame.minX, y: pointer.y - keyWindow.frame.minY
            ))
          }
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel() }
    }
  }

  func cancel() {
    finish(nil)
  }

  private func monitorEscape() {
    localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      self?.handleFallbackEscape(event, target: event.window ?? NSApp?.keyWindow) == true ? nil : event
    }
    if !AppDelegate.isTesting, AXIsProcessTrusted() {
      globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
        _ = self?.handleFallbackEscape(event, target: nil)
      }
    }
  }

  func handleFallbackEscape(_ event: NSEvent, target: NSWindow?) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    guard isSelecting, event.keyCode == 53, modifiers.isEmpty else { return false }
    if let target, windows.contains(where: { $0 === target || $0.scrollingPanel === target }) {
      return false
    }
    cancel()
    return true
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
    let pixels = display.pixelBounds(for: captureRect, in: CGSize(width: frozen.width, height: frozen.height))
    guard !pixels.isEmpty else { return nil }
    return frozen.cropping(to: pixels)
  }

  private func makeWindow(
    display: Display, frozen: CGImage?, frozenWindows: [ScreenshotElementDetection.Window],
    snapshots: [CGWindowID: ScreenshotCaptureSession.WindowLayer], pinImmediately: Bool, removeWindowShadow: Bool
  ) -> ScreenshotSelectionWindow {
    let window = ScreenshotSelectionWindow(
      frame: display.frame, visibleFrame: display.visibleFrame ?? display.frame,
      scale: display.scale, pinImmediately: pinImmediately, frozen: frozen, pixelSize: display.pixelSize
    )
    window.onCancel = { [weak self, weak window] in self?.finish(nil, closingWindow: window) }
    window.selectionView.movePointer = { point in
      guard !AppDelegate.isTesting else { return }
      CGWarpMouseCursorPosition(CGPoint(
        x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y
      ))
    }
    window.selectionView.elementProbe = .shared
    window.selectionView.findElementWindow = { point in
      let global = NSPoint(x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y)
      guard let target = frozenWindows.first(where: {
        $0.frame.contains(global)
      }) else { return nil }
      let local = Self.screenRectangle(target.frame, display: display)
        .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
      return ScreenshotElementDetection.Window(pid: target.pid, frame: local, id: target.id, layer: target.layer)
    }
    window.selectionView.findElements = { point, target in
      let global = NSPoint(x: display.captureFrame.minX + point.x, y: display.captureFrame.maxY - point.y)
      let native = ScreenshotElementDetection.Window(pid: target.pid, frame: NSRect(
        x: display.captureFrame.minX + target.frame.minX,
        y: display.captureFrame.maxY - target.frame.maxY,
        width: target.frame.width, height: target.frame.height
      ))
      let result = ScreenshotElementDetection.probe(at: global, in: native)
      return ScreenshotElementDetection.Result(rectangles: result.rectangles.map {
        Self.screenRectangle($0, display: display).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
      }, outcome: result.outcome)
    }
    window.selectionView.onBegin = { [weak self, weak window] in
      guard let self, let window else { return }
      for other in windows where other !== window {
        other.selectionView.clearSelection()
      }
    }
    window.selectionView.canAdjustSelection = { [weak self] in
      guard let self, windowCaptureTask == nil else { return false }
      return windows.allSatisfy { $0.canvas == nil && !$0.isPreparingImage && !$0.selectionView.isScrolling }
    }
    window.selectionView.canPickColor = { [weak self, weak window] in
      self?.windows.allSatisfy {
        $0.canvas == nil && !$0.isPreparingImage && !$0.selectionView.isScrolling &&
          ($0 === window || !$0.selectionView.hasSelectionInteraction)
      } ?? false
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
    var renderedWindowFrame: NSRect?
    func captureWindows(_ targets: [ScreenshotElementDetection.Window]) async throws -> (CGImage, NSRect) {
      let ids = Set(targets.map(\.id))
      let native = frozenWindows.filter { ids.contains($0.id) }
      let result = try await ScreenshotCaptureSession.captureWindows(
        native, on: display, snapshots: snapshots, removeShadow: removeWindowShadow,
        addBackdrop: Defaults[.screenshotWindowBackdrop]
      )
      return (result.image, Self.screenRectangle(result.frame, display: display))
    }
    window.selectionView.onCapture = { [weak self, weak window] rectangle, pinToScreen in
      guard let self, let window else { return }
      let targets = window.selectionView.selectedWindows
      guard !targets.isEmpty else {
        finish(selection(rectangle, pinToScreen: pinToScreen))
        return
      }
      guard windowCaptureTask == nil else { return }
      windowCaptureTask = Task {
        do {
          let (image, frame) = try await captureWindows(targets)
          try Task.checkCancellation()
          finish(Selection(
            captureRect: frame, anchor: NSPoint(x: frame.midX, y: frame.midY), pinToScreen: pinToScreen, image: image
          ))
        } catch {
          if !Task.isCancelled { finish(nil, failure: error) }
        }
      }
    }
    window.onLongScreenshot = { [weak self, weak window] in
      guard let self, let window, let rectangle = window.selectionView.selectedRect,
            scrollingTask == nil, windowCaptureTask == nil, window.selectionView.selectedWindows.count <= 1 else {
        return
      }
      timeoutTask?.cancel()
      timeoutTask = nil
      for overlay in windows {
        overlay.ignoresMouseEvents = true
        overlay.selectionView.setFrozenImage(nil)
        overlay.selectionView.isScrolling = true
        overlay.annotationToolbar.isHidden = true
      }
      let screenRect = rectangle.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
      let panel = ScrollingScreenshotPanel(
        beside: screenRect, bounds: display.visibleFrame ?? display.frame, level: window.level.rawValue + 1,
        activityMonitor: makeScrollMonitor()
      )
      window.scrollingPanel = panel
      let processor = ScrollingScreenshotProcessor()
      let captureRect = Self.captureRectangle(rectangle, display: display)
      panel.onCancel = { [weak self] in self?.cancel() }
      panel.onScrollActivity = { [weak self] in
        guard let self else { return }
        scrollingLastActivity = .now
        scrollingDelayTask?.cancel()
      }
      panel.onEdit = { [weak self, weak panel] in
        guard let self, isSelecting else { return }
        scrollingTask?.cancel()
        scrollingDelayTask?.cancel()
        scrollingTask = Task { [weak self, weak panel] in
          guard let update = try? await processor.editingPreview(), let preview = update.thumbnail else {
            if !Task.isCancelled { self?.cancel() }
            return
          }
          guard !Task.isCancelled, let self, isSelecting, let panel else { return }
          let frame = ScrollingScreenshotPanel.placement(beside: screenRect,
            bounds: display.visibleFrame ?? display.frame, size: NSSize(width: 330, height: 410))
          panel.showEditor(preview, width: update.width, height: update.height, frame: frame)
        }
      }
      panel.onFinish = { [weak self, weak window, weak panel] pin in
        guard let self, isSelecting, let panel, panel.onFinish != nil else { return }
        panel.onFinish = nil
        panel.stopMonitoring()
        scrollingTask?.cancel()
        scrollingDelayTask?.cancel()
        let edit = panel.edit
        scrollingTask = Task { [weak self, weak window] in
          let output = try? await processor.export(includePreview: !pin, edit: edit)
          guard let self, let window, windows.contains(where: { $0 === window }) else { return }
          guard let output, !Task.isCancelled else {
            cancel()
            return
          }
          var result = selection(rectangle, pinToScreen: pin, data: output.data)
          result.image = output.image
          result.previewImage = output.preview
          let pixels = display.pixelBounds(for: captureRect)
          result.renderedScale = CGSize(
            width: pixels.width / captureRect.width, height: pixels.height / captureRect.height
          )
          finish(result)
        }
      }
      panel.orderFrontRegardless()
      panel.makeKey()
      scrollingTask = Task { [weak self, weak panel] in
        var lastThumbnailUpdate: ContinuousClock.Instant?
        var cadence = ScrollingScreenshotCadence()
        while !Task.isCancelled {
          guard let self, let panel, isSelecting else { return }
          let ids = Set((windows.map(\.windowNumber) + [panel.windowNumber]).compactMap { CGWindowID(exactly: $0) })
          do {
            let started = ContinuousClock.now
            let frame = try await captureRegion(display, captureRect, ids)
            guard !Task.isCancelled, isSelecting else { return }
            guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
              throw ScreenshotCaptureSession.Failure.captureFailed
            }
            let now = ContinuousClock.now
            let refreshDue = lastThumbnailUpdate.map { $0.duration(to: now) >= .milliseconds(500) } ?? true
            let update = try await processor.append(
              cgImage, refreshPreview: refreshDue, maximumPixels: ScreenshotImageLimits.maximumPixels
            )
            guard !Task.isCancelled, isSelecting else { return }
            if let image = update.thumbnail {
              panel.update(image, width: update.width, height: update.height, capped: update.capReached)
              lastThumbnailUpdate = now
            }
            panel.updateHint(capped: update.capReached, warning: update.warning)
            if update.capReached { return }
            let active = scrollingLastActivity.map { $0.duration(to: .now) < .milliseconds(200) } ?? false
            let delay = cadence.delay(after: update.appendResult, elapsed: started.duration(to: .now),
              scrollIsActive: active)
            let earliestNextCapture = ContinuousClock.now + ScrollingScreenshotCadence.minimumDelay
            let sleeper = Task { try await Task.sleep(for: delay) }
            scrollingDelayTask = sleeper
            do { try await sleeper.value }
            catch {
              try await ContinuousClock().sleep(until: earliestNextCapture)
            }
            scrollingDelayTask = nil
          } catch {
            if !Task.isCancelled { cancel() }
            return
          }
        }
      }
    }
    window.loadSelectionImage = { [weak self, weak window] in
      guard let self, let window, let rectangle = window.selectionView.selectedRect else { throw CancellationError() }
      let targets = window.selectionView.selectedWindows
      if !targets.isEmpty {
        let (image, frame) = try await captureWindows(targets)
        renderedWindowFrame = frame
        return (NSImage(cgImage: image, size: frame.size),
                frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
      }
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
      if let frame = renderedWindowFrame, window?.selectionView.selectedWindows.isEmpty == false {
        finish(Selection(
          captureRect: frame, anchor: NSPoint(x: frame.midX, y: frame.midY),
          pinToScreen: action == .pin, renderedData: data
        ))
      } else {
        finish(selection(rectangle, pinToScreen: action == .pin, data: data))
      }
    }
    return window
  }

  private func finish(_ selection: Selection?, closingWindow: ScreenshotSelectionWindow? = nil, failure: Error? = nil) {
    guard let continuation else { return }
    self.continuation = nil
    windowCaptureTask?.cancel()
    windowCaptureTask = nil
    scrollingTask?.cancel()
    scrollingDelayTask?.cancel()
    scrollingDelayTask = nil
    scrollingLastActivity = nil
    scrollingTask = nil
    timeoutTask?.cancel()
    timeoutTask = nil
    if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
    if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
    localEscapeMonitor = nil
    globalEscapeMonitor = nil
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
    if let failure {
      continuation.resume(throwing: failure)
    } else {
      continuation.resume(returning: selection)
    }
  }
}
