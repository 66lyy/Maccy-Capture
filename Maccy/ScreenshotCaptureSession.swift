import AppKit
import Darwin
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor
final class ScreenshotCaptureSession {
  nonisolated struct ValidatedImage: Sendable {
    let data: Data
    let image: CGImage

    nonisolated static func validate(
      _ data: Data, maximumPixels: Int = ScreenshotImageLimits.maximumPixels
    ) throws -> Self {
      guard data.suffix(12).elementsEqual([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130]),
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetType(source) == UTType.png.identifier as CFString,
            CGImageSourceGetCount(source) > 0,
            CGImageSourceGetStatus(source) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= maximumPixels / height,
            let image = CGImageSourceCreateImageAtIndex(source, 0, [
              kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary),
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            image.width == width, image.height == height else { throw Failure.invalidImage }
      return Self(data: data, image: image)
    }
  }

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
    var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    for _ in 0..<5 where !overlayIDs.isSubset(of: Set(content.windows.map(\.windowID))) {
      try await Task.sleep(for: .milliseconds(50))
      content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }
    try Task.checkCancellation()
    guard let screen = content.displays.first(where: { $0.displayID == display.displayID }) else {
      throw Failure.captureFailed
    }
    let overlays = content.windows.filter { overlayIDs.contains($0.windowID) }
    guard Set(overlays.map(\.windowID)) == overlayIDs else { throw Failure.captureFailed }
    let filter = SCContentFilter(display: screen, excludingWindows: overlays)
    let configuration = SCStreamConfiguration()
    configuration.sourceRect = source
    let pixels = display.pixelBounds(for: rectangle)
    configuration.width = Int(pixels.width)
    configuration.height = Int(pixels.height)
    guard configuration.width > 0, configuration.height > 0 else { throw Failure.captureFailed }
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    try Task.checkCancellation()
    return NSImage(cgImage: ScreenshotColorSpace.matchDisplay(image, profile: display.colorSpace), size: source.size)
  }

  static func captureDisplays(_ displays: [ScreenshotSelectionController.Display]) async -> [CGImage?] {
    await captureDisplays(displays, capture: { await captureDisplay($0) })
  }

  static func captureDisplays(
    _ displays: [ScreenshotSelectionController.Display],
    capture: @escaping @MainActor @Sendable (ScreenshotSelectionController.Display) async -> CGImage?
  ) async -> [CGImage?] {
    await withTaskGroup(of: (Int, CGImage?).self) { group in
      for (index, display) in displays.enumerated() {
        group.addTask { [capture, display] in
          guard !Task.isCancelled else { return (index, nil) }
          return (index, await capture(display))
        }
      }
      var images = [CGImage?](repeating: nil, count: displays.count)
      for await (index, image) in group { images[index] = image }
      return images
    }
  }

  private static func captureDisplay(_ display: ScreenshotSelectionController.Display) async -> CGImage? {
    let image = await captureDisplayImage(rectangleCapture: {
      if #available(macOS 15.2, *) {
        let image = try await SCScreenshotManager.captureImage(in: display.captureFrame)
        guard hasSufficientResolution(image, for: display),
              display.colorSpace?.isWideGamutRGB != true || image.colorSpace?.isWideGamutRGB == true else {
          return nil
        }
        return image
      }
      return nil
    }, filteredCapture: {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      guard let screen = content.displays.first(where: { $0.displayID == display.displayID }) else {
        throw Failure.captureFailed
      }
      let configuration = SCStreamConfiguration()
      configuration.width = Int(display.pixelSize.width)
      configuration.height = Int(display.pixelSize.height)
      configuration.showsCursor = false
      return try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(display: screen, excludingWindows: []), configuration: configuration
      )
    })
    return image.map { ScreenshotColorSpace.matchDisplay($0, profile: display.colorSpace) }
  }

  static func captureDisplayImage(
    rectangleCapture: () async throws -> CGImage?, filteredCapture: () async throws -> CGImage
  ) async -> CGImage? {
    if let image = try? await rectangleCapture() { return image }
    guard !Task.isCancelled else { return nil }
    return try? await filteredCapture()
  }

  static func hasSufficientResolution(_ image: CGImage, for display: ScreenshotSelectionController.Display) -> Bool {
    let width = Int(display.pixelSize.width)
    let height = Int(display.pixelSize.height)
    return image.width >= width - 1 && image.height >= height - 1
  }

  func capture(mode: Mode, timeout: Duration = .seconds(120)) async throws -> ValidatedImage {
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
    let result = try await Task.detached(priority: .userInitiated) {
      try ValidatedImage.validate(Data(contentsOf: output))
    }.value
    try Task.checkCancellation()
    if wasCancelled { throw CancellationError() }
    return result
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

nonisolated enum ScreenshotColorSpace {
  static func rgb(_ profile: CGColorSpace?) -> CGColorSpace {
    if let profile, profile.model == .rgb { return profile }
    return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
  }

  static func matchDisplay(_ image: CGImage, profile: CGColorSpace?) -> CGImage {
    guard let profile, profile.model == .rgb,
          let source = image.colorSpace, !CFEqual(source, profile),
          let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: profile, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return image }
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context.makeImage() ?? image
  }
}
