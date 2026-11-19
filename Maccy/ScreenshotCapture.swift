import AppKit
import CoreGraphics
import Defaults

@MainActor
final class ScreenshotCapture {
  static let shared = ScreenshotCapture()

  private enum CaptureMode {
    case mainDisplay
    case selection
  }

  private let session = ScreenshotCaptureSession()
  private let permission = ScreenCapturePermission()
  private let selectionController = ScreenshotSelectionController()
  private var captureTask: Task<Void, Never>?
  private var pinnedWindows: [UUID: PinnedScreenshotWindow] = [:]
  private var previewWindow: ScreenshotPreviewWindow?
  private var annotationWindows: [UUID: ScreenshotAnnotationWindow] = [:]
  private var annotationSources: [ObjectIdentifier: UUID] = [:]
  private var isShowingAlert = false

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
    guard let image = NSImage(pasteboard: .general), image.isValid else {
      showError("ScreenshotClipboardEmpty")
      return
    }
    pinImage(image)
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
    for window in Array(pinnedWindows.values) {
      window.close()
    }
  }

  private func startCapture(mode: CaptureMode, pinToScreen: Bool) {
    guard captureTask == nil, !isShowingAlert else { return }
    if let editor = annotationWindows.values.first {
      editor.present()
      return
    }
    switch permission.authorize() {
    case .granted:
      break
    case .requested, .requestInProgress:
      return
    case .needsSettings:
      showPermissionHelp()
      return
    }

    dismissPreview()
    AppState.shared.popup.close()
    captureTask = Task { [weak self] in
      guard let self else { return }
      defer { captureTask = nil }
      do {
        try await Task.sleep(for: .milliseconds(180))
        let data: Data
        var shouldPin = pinToScreen
        var pinAnchor: NSPoint?
        let shouldAnnotate: Bool
        var imageFrame: NSRect?
        switch mode {
        case .mainDisplay:
          imageFrame = NSScreen.screens.first?.frame
          shouldAnnotate = true
          data = try await session.capture(mode: .mainDisplay)
        case .selection:
          guard let selection = try await selectionController.select(pinImmediately: pinToScreen) else { return }
          shouldPin = selection.pinToScreen
          shouldAnnotate = false
          pinAnchor = selection.anchor
          imageFrame = selection.screenRect
          if let rendered = selection.renderedData {
            data = rendered
          } else {
            try await Task.sleep(for: .milliseconds(120))
            data = try await session.capture(mode: .region(selection.captureRect))
          }
        }
        try Task.checkCancellation()
        guard let image = NSImage(data: data), image.isValid else {
          throw ScreenshotCaptureSession.Failure.invalidImage
        }
        if shouldAnnotate {
          annotateImage(image, imageFrame: imageFrame, originalWasCopied: false)
        } else {
          try deliverScreenshot(data) {
            if shouldPin {
              pinImage(image, anchor: pinAnchor)
            } else {
              showPreview(image, imageFrame: imageFrame)
            }
          }
        }
        if Defaults[.screenshotSoundEnabled] {
          NSSound.write?.play()
        }
      } catch is CancellationError {
        return
      } catch {
        showError(error.localizedDescription, localized: true)
      }
    }
  }

  private func deliverScreenshot(_ pngData: Data, present: () -> Void) throws {
    let historyResult = try Self.deliverScreenshot(
      pngData, copy: Clipboard.shared.copyScreenshot, saveHistory: saveInHistory, present: present
    )
    if case .failure = historyResult {
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

  private func saveInHistory(_ pngData: Data) throws {
    let item = HistoryItem(contents: [
      HistoryItemContent(type: NSPasteboard.PasteboardType.png.rawValue, value: pngData)
    ])
    item.application = Bundle.main.bundleIdentifier
    item.title = text("ScreenshotTitle")

    if #unavailable(macOS 15.0) {
      try History.shared.insertIntoStorage(item)
    }
    History.shared.add(item)
    try Storage.shared.context.save()
  }

  private func pinImage(_ image: NSImage, anchor: NSPoint? = nil) {
    let pointer = anchor ?? NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else {
      return
    }
    let identifier = UUID()
    let window = PinnedScreenshotWindow(image: image, visibleFrame: screen.visibleFrame, anchor: pointer)
    let sourceID = ObjectIdentifier(window)
    window.onAnnotate = { [weak self, weak window] image in
      guard let window else { return }
      self?.annotateImage(image, source: window)
    }
    window.onClose = { [weak self] in
      if let editorID = self?.annotationSources[sourceID] {
        self?.annotationWindows[editorID]?.close()
      }
      self?.pinnedWindows.removeValue(forKey: identifier)
    }
    pinnedWindows[identifier] = window
    window.makeKeyAndOrderFront(nil)
  }

  private func showPreview(_ image: NSImage, imageFrame: NSRect? = nil) {
    let pointer = imageFrame.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
    let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    guard let screen else { return }
    let window = ScreenshotPreviewWindow(
      image: image, visibleFrame: screen.visibleFrame,
      onAnnotate: { [weak self] in self?.annotateImage(image, imageFrame: imageFrame) }
    ) {
      [weak self] in self?.pinImage(image, anchor: pointer)
    }
    window.onClose = { [weak self] in
      self?.previewWindow = nil
    }
    previewWindow = window
    window.present()
  }

  private func annotateImage(
    _ image: NSImage, source: PinnedScreenshotWindow? = nil, imageFrame: NSRect? = nil,
    originalWasCopied: Bool = true
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
    let targetFrame = source?.frame ?? imageFrame
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
        try deliverScreenshot(data) {
          source?.replaceImage(rendered)
          if source == nil {
            showPreview(rendered, imageFrame: targetFrame)
          }
        }
      case .pin:
        try deliverScreenshot(data) {
          pinImage(rendered, anchor: anchor)
        }
      case .apply:
        source?.replaceImage(rendered)
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
