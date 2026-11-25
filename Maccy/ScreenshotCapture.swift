import AppKit
import Combine
import CoreGraphics
import Defaults
import Observation

nonisolated enum ScreenshotImageLimits {
  static let maximumPixels = 100_000_000
}

nonisolated struct PinnedImageBudget {
  static let maximumBytes = 1_073_741_824
  private var estimates: [UUID: Int] = [:]
  private(set) var total = 0

  static func estimatedBytes(pixelWidth: Int, pixelHeight: Int) -> Int? {
    guard pixelWidth > 0, pixelHeight > 0,
          pixelWidth <= ScreenshotImageLimits.maximumPixels / pixelHeight else { return nil }
    return pixelWidth * pixelHeight * 4
  }

  @MainActor static func estimatedBytes(for image: NSImage) -> Int? {
    let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
    if !bitmaps.isEmpty {
      var largest = 0
      for bitmap in bitmaps {
        guard let bytes = estimatedBytes(pixelWidth: bitmap.pixelsWide, pixelHeight: bitmap.pixelsHigh)
        else { return nil }
        largest = max(largest, bytes)
      }
      return largest
    }
    guard let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return estimatedBytes(pixelWidth: image.width, pixelHeight: image.height)
  }

  func canAdd(_ bytes: Int) -> Bool {
    bytes > 0 && bytes <= ScreenshotImageLimits.maximumPixels * 4 && bytes <= Self.maximumBytes - total
  }

  @discardableResult
  mutating func add(_ id: UUID, bytes: Int) -> Bool {
    let previous = estimates[id] ?? 0
    guard bytes > 0, bytes <= ScreenshotImageLimits.maximumPixels * 4,
          bytes <= Self.maximumBytes - (total - previous) else { return false }
    estimates[id] = bytes
    total += bytes - previous
    return true
  }

  mutating func remove(_ id: UUID) {
    total -= estimates.removeValue(forKey: id) ?? 0
  }
}

@MainActor @Observable
final class PinnedImagesState {
  fileprivate(set) var clickThroughCount = 0
}

@MainActor
final class ScreenshotCapture {
  static let shared = ScreenshotCapture()

  let pinnedImages = PinnedImagesState()

  private enum CaptureMode {
    case mainDisplay
    case selection
  }

  private let session = ScreenshotCaptureSession()
  private let permission = ScreenCapturePermission()
  private let selectionController = ScreenshotSelectionController()
  private var captureTask: Task<Void, Never>?
  private var pinnedWindows: [UUID: PinnedScreenshotWindow] = [:]
  private var pinnedStacks: [CGDirectDisplayID: PinnedScreenshotStack] = [:]
  private var pinnedImageBudget = PinnedImageBudget()
  private var previewWindow: ScreenshotPreviewWindow?
  private var annotationWindows: [UUID: ScreenshotAnnotationWindow] = [:]
  private var annotationSources: [ObjectIdentifier: UUID] = [:]
  private var isShowingAlert = false
  private let connectedDisplayIDs: @MainActor () -> Set<CGDirectDisplayID>
  private var screenObserver: AnyCancellable?

  init(connectedDisplayIDs: @escaping @MainActor () -> Set<CGDirectDisplayID> = {
    Set(NSScreen.screens.map { ScreenshotCapture.displayID(for: $0) })
  }) {
    self.connectedDisplayIDs = connectedDisplayIDs
    screenObserver = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
      .sink { [weak self] _ in self?.pruneDisconnectedStacks() }
  }

  var isCapturing: Bool { captureTask != nil }

  var hasActiveCapture: Bool {
    captureTask != nil || !annotationWindows.isEmpty
  }

  func captureMainDisplay() {
    startCapture(mode: .mainDisplay, pinToScreen: false)
  }

  func captureSelection(pinToScreen: Bool = false) {
    startCapture(mode: .selection, pinToScreen: pinToScreen)
  }

  func pinClipboardImage() {
    guard let image = NSImage(pasteboard: Clipboard.shared.pasteboard), image.isValid else {
      showError("ScreenshotClipboardEmpty")
      return
    }
    Clipboard.shared.checkForChangesInPasteboard()
    pinImage(image)
  }

  func togglePinnedClickThrough() {
    let windows = Array(pinnedWindows.values)
    let enable = !windows.contains { $0.isClickThrough }
    for window in windows { window.isClickThrough = enable }
  }

  func turnOffPinnedClickThrough() {
    for window in pinnedWindows.values { window.isClickThrough = false }
  }

  private func updatePinnedClickThroughCount() {
    pinnedImages.clickThroughCount = pinnedWindows.values.filter(\.isClickThrough).count
  }

  func cancelCapture() {
    captureTask?.cancel()
    selectionController.cancel()
    session.cancel()
  }

  func shutDown() {
    cancelCapture()
    dismissPreview()
    for window in Array(annotationWindows.values) {
      window.close()
    }
    closeAllPinnedImages()
  }

  private func startCapture(mode: CaptureMode, pinToScreen: Bool) {
    guard captureTask == nil, !isShowingAlert else { return }
    if let editor = annotationWindows.values.first {
      editor.present()
      return
    }
    let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    switch permission.authorize() {
    case .granted:
      break
    case .requested, .requestInProgress:
      return
    case .needsSettings:
      showPermissionHelp()
      return
    }

    if case .selection = mode { previewWindow?.animationBehavior = .none }
    dismissPreview()
    captureTask = Task { [weak self] in
      guard let self else { return }
      defer {
        captureTask = nil
        AppState.shared.appDelegate?.panel.restoreFocusAfterScreenshot()
      }
      do {
        if case .mainDisplay = mode {
          try await Task.sleep(for: .milliseconds(180))
        }
        let result: ScreenshotCaptureSession.ValidatedImage
        var shouldPin = pinToScreen
        let shouldAnnotate: Bool
        var imageFrame: NSRect?
        var preview: CGImage?
        switch mode {
        case .mainDisplay:
          imageFrame = NSScreen.screens.first?.frame
          shouldAnnotate = true
          result = try await session.capture(mode: .mainDisplay)
        case .selection:
          guard let selection = try await selectionController.select(pinImmediately: pinToScreen) else { return }
          shouldPin = selection.pinToScreen
          shouldAnnotate = false
          imageFrame = selection.screenRect
          preview = selection.previewImage
          if let rendered = selection.renderedData, let image = selection.image {
            result = ScreenshotCaptureSession.ValidatedImage(data: rendered, image: image)
          } else if let rendered = selection.renderedData {
            result = try await Task.detached(priority: .userInitiated) {
              try ScreenshotCaptureSession.ValidatedImage.validate(rendered)
            }.value
          } else if let frozen = selection.image {
            result = try await Task.detached(priority: .userInitiated) {
              guard let data = ScreenshotAnnotationDocument.RenderSnapshot.pngData(frozen) else {
                throw ScreenshotCaptureSession.Failure.captureFailed
              }
              return try ScreenshotCaptureSession.ValidatedImage.validate(data)
            }.value
          } else {
            try await Task.sleep(for: .milliseconds(120))
            result = try await session.capture(mode: .region(selection.captureRect))
          }
          if let scale = selection.renderedScale, scale.width > 0, scale.height > 0 {
            let size = NSSize(
              width: CGFloat(result.image.width) / scale.width, height: CGFloat(result.image.height) / scale.height
            )
            imageFrame = NSRect(x: selection.screenRect.minX, y: selection.screenRect.maxY - size.height,
                                width: size.width, height: size.height)
          }
        }
        try Task.checkCancellation()
        let data = result.data
        let image = NSImage(cgImage: result.image, size: imageFrame?.size ?? .zero)
        if shouldAnnotate {
          annotateImage(image, imageFrame: imageFrame, originalWasCopied: false, sourceApp: source)
        } else {
          try deliverScreenshot(data, sourceApp: source) {
            if shouldPin {
              pinImage(image, imageFrame: imageFrame, sourceApp: source)
            } else {
              showPreview(image, imageFrame: imageFrame, thumbnail: preview, sourceApp: source)
            }
          }
        }
      } catch is CancellationError {
        return
      } catch {
        showError(error.localizedDescription, localized: true)
      }
    }
  }

  private func deliverScreenshot(_ pngData: Data, sourceApp: String?, present: () -> Void) throws {
    let historyResult = try Self.deliverScreenshot(
      pngData, copy: Clipboard.shared.copyScreenshot, saveHistory: { try saveInHistory($0, sourceApp: sourceApp) }, present: present
    )
    if case .failure = historyResult {
      History.shared.logger.error("Failed to save screenshot history")
      Task { [weak self] in
        self?.showError("ScreenshotHistorySaveWarning", title: "ScreenshotHistorySaveWarningTitle")
      }
    }
  }

  static func deliverScreenshot(
    _ pngData: Data, copy: (Data) -> Bool, saveHistory: (Data) throws -> Void, present: () -> Void
  ) throws -> Result<Void, any Error> {
    guard copy(pngData) else { throw ScreenshotCaptureSession.Failure.clipboardWrite }
    let historyResult = Result { try saveHistory(pngData) }
    present()
    return historyResult
  }

  func saveInHistory(_ pngData: Data) throws {
    try saveInHistory(pngData, sourceApp: Bundle.main.bundleIdentifier)
  }

  func saveInHistory(_ pngData: Data, sourceApp: String? = Bundle.main.bundleIdentifier, history: History = .shared) throws {
    guard Clipboard.shared.permitsHistory(types: [.png, .fromMaccy], source: sourceApp) else { return }
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: pngData),
      HistoryItemContent(type: Clipboard.hostOnlyType.rawValue, value: Data())
    ])
    item.application = Bundle.main.bundleIdentifier
    item.title = text("ScreenshotTitle")

    history.add(item, saveToStorage: false, indexImage: true, playNotificationSound: false)
    try history.insertIntoStorage(item)
  }

  func pinImage(_ image: NSImage, imageFrame: NSRect? = nil,
                sourceApp: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
    guard let bytes = PinnedImageBudget.estimatedBytes(for: image) else {
      showError("PinnedImageTooLarge")
      return
    }
    guard pinnedImageBudget.canAdd(bytes) else {
      showError("PinnedImageMemoryLimit")
      return
    }
    let pointer = imageFrame.map { NSPoint(x: $0.midX, y: $0.maxY - min(1, $0.height / 2)) } ?? NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
      return
    }
    let identifier = UUID()
    guard pinnedImageBudget.add(identifier, bytes: bytes) else { return }
    let window = PinnedScreenshotWindow(
      image: image, visibleFrame: screen.visibleFrame, anchor: pointer, captureFrame: imageFrame
    )
    let sourceID = ObjectIdentifier(window)
    window.onAnnotate = { [weak self, weak window] image in
      guard let window else { return }
      self?.annotateImage(image, source: window, sourceApp: sourceApp)
    }
    window.onClose = { [weak self] in
      if let editorID = self?.annotationSources[sourceID] {
        self?.annotationWindows[editorID]?.close()
      }
      self?.pinnedWindows.removeValue(forKey: identifier)
      self?.pinnedImageBudget.remove(identifier)
      self?.updatePinnedClickThroughCount()
    }
    window.onClickThroughChange = { [weak self] in self?.updatePinnedClickThroughCount() }
    window.onCloseAll = { [weak self] in self?.closeAllPinnedImages() }
    pinnedWindows[identifier] = window
    let popup = AppState.shared.popup
    if !popup.isClosed() { popup.close() }
    guard Defaults[.automaticPinStackingEnabled] else {
      window.present()
      return
    }
    let displayID = Self.displayID(for: screen)
    let stack = pinnedStacks[displayID] ?? PinnedScreenshotStack(onEmpty: { [weak self] in
      self?.pinnedStacks.removeValue(forKey: displayID)
    })
    let candidates = pinnedWindows.values.filter { $0 !== window && $0.screen?.frame == screen.frame }
    stack.add(window, alongside: candidates, visibleFrame: screen.visibleFrame)
    if !stack.pins.isEmpty { pinnedStacks[displayID] = stack }
  }

  private static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
  }

  private func pruneDisconnectedStacks() {
    let connected = connectedDisplayIDs()
    for id in pinnedStacks.keys.filter({ !connected.contains($0) }) {
      pinnedStacks.removeValue(forKey: id)?.restoreAll()
    }
  }

  func restorePinnedStacks() {
    for stack in pinnedStacks.values { stack.restoreAll() }
    pinnedStacks.removeAll()
  }

  private func closeAllPinnedImages() {
    pinnedStacks.removeAll()
    for window in Array(pinnedWindows.values) { window.close() }
    pinnedWindows.removeAll()
    pinnedImageBudget = PinnedImageBudget()
    updatePinnedClickThroughCount()
  }

  static func previewImage(for image: NSImage, thumbnail: CGImage?) -> NSImage {
    let size = image.size
    guard let thumbnail, size.width > 0, size.height > 0 else { return image }
    let scale = min(1, CGFloat(thumbnail.width) / size.width, CGFloat(thumbnail.height) / size.height)
    return NSImage(cgImage: thumbnail, size: NSSize(width: size.width * scale, height: size.height * scale))
  }

  private func showPreview(_ image: NSImage, imageFrame: NSRect? = nil, thumbnail: CGImage? = nil, sourceApp: String?) {
    let pointer = imageFrame.map { NSPoint(x: $0.midX, y: $0.maxY - min(1, $0.height / 2)) } ?? NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    guard let screen else { return }
    let window = ScreenshotPreviewWindow(
      image: Self.previewImage(for: image, thumbnail: thumbnail), visibleFrame: screen.visibleFrame,
      onAnnotate: { [weak self] in self?.annotateImage(image, imageFrame: imageFrame, sourceApp: sourceApp) }
    ) {
      [weak self] in self?.pinImage(image, imageFrame: imageFrame, sourceApp: sourceApp)
    }
    window.onClose = { [weak self] in
      self?.previewWindow = nil
    }
    previewWindow = window
    window.present()
  }

  private func annotateImage(
    _ image: NSImage, source: PinnedScreenshotWindow? = nil, imageFrame: NSRect? = nil,
    originalWasCopied: Bool = true, sourceApp: String?
  ) {
    let sourceID = source.map(ObjectIdentifier.init)
    if let sourceID, let identifier = annotationSources[sourceID], let window = annotationWindows[identifier] {
      window.present()
      return
    }
    if let window = annotationWindows.values.first {
      window.present()
      return
    }
    dismissPreview()
    let targetFrame = source?.editingFrame ?? imageFrame
    let anchor = targetFrame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
    guard let screen = source?.screen ?? NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main,
          let window = ScreenshotAnnotationWindow(
            image: image, visibleFrame: screen.visibleFrame, screenFrame: screen.frame, imageFrame: targetFrame,
            editingPin: source != nil,
            originalWasCopied: originalWasCopied
          ) else {
      showError("AnnotationOutputFailed")
      return
    }
    let identifier = UUID()
    window.onOutput = { [weak self, weak source] data, rendered, action in
      guard let self else { return }
      switch action {
      case .copy:
        guard let data else { throw CancellationError() }
        try deliverScreenshot(data, sourceApp: sourceApp) {
          if let source {
            replacePinnedImage(rendered, in: source)
          } else {
            showPreview(rendered, imageFrame: targetFrame, sourceApp: sourceApp)
          }
        }
      case .pin:
        guard let data else { throw CancellationError() }
        try deliverScreenshot(data, sourceApp: sourceApp) {
          pinImage(rendered, imageFrame: targetFrame, sourceApp: sourceApp)
        }
      case .apply:
        if let source { replacePinnedImage(rendered, in: source) }
      }
    }
    window.onClose = { [weak self] in
      self?.annotationWindows.removeValue(forKey: identifier)
      if let sourceID { self?.annotationSources.removeValue(forKey: sourceID) }
    }
    annotationWindows[identifier] = window
    if let sourceID { annotationSources[sourceID] = identifier }
    window.present()
  }

  private func replacePinnedImage(_ image: NSImage, in pin: PinnedScreenshotWindow) {
    guard let id = pinnedWindows.first(where: { $0.value === pin })?.key,
          let bytes = PinnedImageBudget.estimatedBytes(for: image), pinnedImageBudget.add(id, bytes: bytes)
    else { return }
    pin.replaceImage(image)
  }

  private func dismissPreview() {
    previewWindow?.close()
    previewWindow = nil
  }

  private func showPermissionHelp() {
    guard !isShowingAlert else { return }
    isShowingAlert = true
    defer { isShowingAlert = false }
    let alert = NSAlert()
    alert.messageText = text("ScreenshotPermissionTitle")
    alert.informativeText = text("ScreenshotPermissionHelp")
    alert.addButton(withTitle: text("ScreenshotOpenSettings"))
    alert.addButton(withTitle: text("ScreenshotRestartCurrentApp"))
    alert.addButton(withTitle: text("ScreenshotCancel"))
    NSApp.activate(ignoringOtherApps: true)
    switch alert.runModal() {
    case .alertFirstButtonReturn:
      openPermissionSettings()
    case .alertSecondButtonReturn:
      AppState.shared.appDelegate?.restartCurrentApplication()
    default:
      break
    }
  }

  func openPermissionSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
      NSWorkspace.shared.open(url)
    }
  }

  private func showError(_ message: String, localized: Bool = false, title: String = "ScreenshotErrorTitle") {
    guard !isShowingAlert else { return }
    isShowingAlert = true
    defer { isShowingAlert = false }
    let alert = NSAlert()
    alert.messageText = text(title)
    alert.informativeText = localized ? message : text(message)
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }

  private func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}
