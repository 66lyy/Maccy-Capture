import AppKit
import Darwin
import ScreenCaptureKit

@MainActor
final class ScreenshotCaptureSession {
  enum Mode: Equatable {
    case mainDisplay
    case region(NSRect)

    func arguments(output: URL) -> [String] {
      let options: [String]
      switch self {
      case .mainDisplay:
        options = ["-m"]
      case .region(let rectangle):
        let integralRect = rectangle.integral
        let coordinates = [integralRect.minX, integralRect.minY, integralRect.width, integralRect.height]
          .map { String(Int($0)) }.joined(separator: ",")
        options = ["-R\(coordinates)"]
      }
      return options + ["-x", "-t", "png", output.path]
    }
  }

  enum Failure: String, LocalizedError {
    case alreadyCapturing = "ScreenshotAlreadyCapturing"
    case captureFailed = "ScreenshotCaptureFailed"
    case invalidImage = "ScreenshotInvalidImage"
    case timedOut = "ScreenshotTimedOut"
    case clipboardWrite = "ScreenshotClipboardWriteFailed"

    var errorDescription: String? {
      NSLocalizedString(rawValue, tableName: "GeneralSettings", comment: "")
    }
  }

  typealias ProcessFactory = (Mode, URL) -> Process

  private(set) var isCapturing = false
  private var process: Process?
  private var wasCancelled = false
  private var didTimeOut = false
  private let processFactory: ProcessFactory
  private let temporaryRoot: URL

  init(
    temporaryRoot: URL = FileManager.default.temporaryDirectory,
    processFactory: @escaping ProcessFactory = { mode, output in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = mode.arguments(output: output)
      return process
    }
  ) {
    self.temporaryRoot = temporaryRoot
    self.processFactory = processFactory
  }

  static func sourceRectangle(_ rectangle: NSRect, displayFrame: NSRect) -> NSRect {
    rectangle.intersection(displayFrame).offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
  }

  static func captureSelection(
    on display: ScreenshotSelectionController.Display, rectangle: NSRect, excluding overlayIDs: Set<CGWindowID>
  ) async throws -> NSImage {
    let source = sourceRectangle(rectangle, displayFrame: display.captureFrame)
    guard source.width >= 3, source.height >= 3, !overlayIDs.isEmpty else { throw Failure.captureFailed }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    try Task.checkCancellation()
    guard let screen = content.displays.first(where: { $0.displayID == display.displayID }) else {
      throw Failure.captureFailed
    }
    let overlays = content.windows.filter { overlayIDs.contains($0.windowID) }
    guard Set(overlays.map(\.windowID)) == overlayIDs else { throw Failure.captureFailed }
    let filter = SCContentFilter(display: screen, excludingWindows: overlays)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = source
    configuration.width = Int((source.width * display.scale).rounded())
    configuration.height = Int((source.height * display.scale).rounded())
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    try Task.checkCancellation()
    return NSImage(cgImage: image, size: source.size)
  }

  func capture(mode: Mode, timeout: Duration = .seconds(120)) async throws -> Data {
    guard !isCapturing else { throw Failure.alreadyCapturing }
    try Task.checkCancellation()
    isCapturing = true
    wasCancelled = false
    didTimeOut = false
    let directory = temporaryRoot.appendingPathComponent("Maccy-Capture-\(UUID().uuidString)", isDirectory: true)
    defer {
      isCapturing = false
      self.process = nil
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let output = directory.appendingPathComponent("capture.png")
    let process = processFactory(mode, output)
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    self.process = process

    let watchdog = Task { [weak self] in
      do {
        try await Task.sleep(for: timeout)
        guard let self, process.isRunning else { return }
        didTimeOut = true
        stop(process)
      } catch {
        return
      }
    }
    defer { watchdog.cancel() }

    let status: Int32 = try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { process in
          continuation.resume(returning: process.terminationStatus)
        }
        do {
          try process.run()
        } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        guard self?.process === process else { return }
        self?.cancel()
      }
    }

    if didTimeOut { throw Failure.timedOut }
    if wasCancelled { throw CancellationError() }
    try Task.checkCancellation()
    let exists = FileManager.default.fileExists(atPath: output.path)
    guard status == 0, exists else { throw Failure.captureFailed }
    let data = try Data(contentsOf: output)
    guard data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
          NSBitmapImageRep(data: data) != nil else {
      throw Failure.invalidImage
    }
    return data
  }

  func cancel() {
    wasCancelled = true
    if let process {
      stop(process)
    }
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    Task {
      try? await Task.sleep(for: .seconds(1))
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
  }
}
