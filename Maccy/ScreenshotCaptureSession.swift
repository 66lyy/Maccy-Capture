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
    case window(CGWindowID, removeShadow: Bool)

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
      case .window(let id, let removeShadow):
        options = ["-l\(id)", "-a"] + (removeShadow ? ["-o"] : [])
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

  typealias ProcessFactory = (Mode, URL) throws -> Process

  private(set) var isCapturing = false
  private var process: Process?
  private var wasCancelled = false
  private var didTimeOut = false
  private let processFactory: ProcessFactory
  private let temporaryRoot: URL

  init(
    temporaryRoot: URL = FileManager.default.temporaryDirectory,
    processFactory: @escaping ProcessFactory = { mode, output in
      guard !AppDelegate.isTesting else { throw Failure.captureFailed }
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
    guard !AppDelegate.isTesting else { throw Failure.captureFailed }
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

  static func captureWindows(
    _ targets: [ScreenshotElementDetection.Window], on display: ScreenshotSelectionController.Display,
    snapshots: [CGWindowID: WindowLayer], removeShadow: Bool, addBackdrop: Bool
  ) async throws -> (image: CGImage, frame: NSRect) {
    guard !AppDelegate.isTesting else { throw Failure.captureFailed }
    let bounds = targets.reduce(NSRect.null) { $0.union($1.frame) }
    guard !bounds.isEmpty else { throw Failure.captureFailed }
    let image: CGImage
    let scale: CGFloat
    let imageBounds: CGRect
    if #available(macOS 26.0, *), targets.allSatisfy({ snapshots[$0.id] == nil }) {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      let windows = targets.compactMap { target in content.windows.first { $0.windowID == target.id } }
      guard windows.count == targets.count, let screen = content.displays.first(where: {
        $0.displayID == display.displayID
      }) else { throw Failure.captureFailed }
      let filter = SCContentFilter(display: screen, including: windows)
      let configuration = SCScreenshotConfiguration()
      configuration.showsCursor = false
      configuration.ignoreShadows = removeShadow
      configuration.includeChildWindows = false
      guard let captured = try await SCScreenshotManager.captureScreenshot(
        contentFilter: filter, configuration: configuration
      ).sdrImage else { throw Failure.captureFailed }
      image = captured
      scale = CGFloat(filter.pointPixelScale)
      imageBounds = bounds
    } else if let target = targets.first, targets.count == 1, snapshots[target.id] == nil {
      image = try await ScreenshotCaptureSession().capture(
        mode: .window(target.id, removeShadow: removeShadow)
      ).image
      scale = display.scale
      imageBounds = bounds
    } else {
      var layers: [(CGImage, CGRect)] = []
      for target in targets.reversed() {
        if let snapshot = snapshots[target.id] {
          layers.append((snapshot.image, snapshot.frame))
        } else if #available(macOS 26.0, *) {
          let layer = try await windowLayer(target, on: display, removeShadow: removeShadow)
          layers.append((layer.image, layer.frame))
        } else {
          let layer = try await ScreenshotCaptureSession().capture(
            mode: .window(target.id, removeShadow: true)
          ).image
          layers.append((layer, target.frame))
        }
      }
      scale = display.scale
      imageBounds = layers.reduce(CGRect.null) { $0.union($1.1) }
      guard let composed = compositeWindows(layers, bounds: imageBounds, scale: scale) else {
        throw Failure.captureFailed
      }
      image = composed
    }
    try Task.checkCancellation()
    guard scale > 0 else { throw Failure.captureFailed }
    let padded = addBackdrop ? windowBackdrop(image, scale: scale) : image
    guard let padded else { throw Failure.captureFailed }
    let width = CGFloat(padded.width) / scale
    let height = CGFloat(padded.height) / scale
    return (padded, CGRect(
      x: imageBounds.midX - width / 2, y: imageBounds.midY - height / 2, width: width, height: height
    ))
  }

  struct WindowLayer {
    let image: CGImage
    let frame: CGRect
  }

  static func snapshotPopups(
    _ targets: [ScreenshotElementDetection.Window], on displays: [ScreenshotSelectionController.Display],
    removeShadow: Bool
  ) async -> [CGWindowID: WindowLayer] {
    guard !AppDelegate.isTesting else { return [:] }
    var snapshots: [CGWindowID: WindowLayer] = [:]
    for target in targets where target.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) {
      guard !Task.isCancelled else { break }
      if #available(macOS 26.0, *), let display = displays.max(by: {
        let lhs = $0.captureFrame.intersection(target.frame), rhs = $1.captureFrame.intersection(target.frame)
        return (lhs.isNull ? 0 : lhs.width * lhs.height) < (rhs.isNull ? 0 : rhs.width * rhs.height)
      }) {
        snapshots[target.id] = try? await windowLayer(target, on: display, removeShadow: removeShadow)
      } else if let snapshot = try? await ScreenshotCaptureSession().capture(
        mode: .window(target.id, removeShadow: true)
      ) {
        snapshots[target.id] = WindowLayer(image: snapshot.image, frame: target.frame)
      }
    }
    return snapshots
  }

  @available(macOS 26.0, *)
  private static func windowLayer(
    _ target: ScreenshotElementDetection.Window, on display: ScreenshotSelectionController.Display, removeShadow: Bool
  ) async throws -> WindowLayer {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let screen = content.displays.first(where: { $0.displayID == display.displayID }),
          let window = content.windows.first(where: { $0.windowID == target.id }) else {
      throw Failure.captureFailed
    }
    let filter = SCContentFilter(display: screen, including: [window])
    let configuration = SCScreenshotConfiguration()
    configuration.showsCursor = false
    configuration.ignoreShadows = removeShadow
    configuration.includeChildWindows = false
    let margin: CGFloat = removeShadow ? 0 : 96
    let frame = target.frame.insetBy(dx: -margin, dy: -margin).intersection(display.captureFrame)
    guard !frame.isEmpty else { throw Failure.captureFailed }
    configuration.sourceRect = sourceRectangle(frame, displayFrame: display.captureFrame)
    guard let image = try await SCScreenshotManager.captureScreenshot(
      contentFilter: filter, configuration: configuration
    ).sdrImage else { throw Failure.captureFailed }
    return WindowLayer(image: image, frame: frame)
  }

  static func compositeWindows(_ layers: [(CGImage, CGRect)], bounds: CGRect, scale: CGFloat) -> CGImage? {
    guard !bounds.isEmpty, scale > 0,
          let context = windowCanvas(width: Int((bounds.width * scale).rounded()),
                                     height: Int((bounds.height * scale).rounded()),
                                     colorSpace: layers.first?.0.colorSpace) else { return nil }
    for (image, frame) in layers {
      let rect = CGRect(
        x: (frame.minX - bounds.minX) * scale, y: (bounds.maxY - frame.maxY) * scale,
        width: frame.width * scale, height: frame.height * scale
      )
      context.draw(image, in: rect.integral)
    }
    return context.makeImage()
  }

  static func windowBackdrop(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let padding = Int((32 * scale).rounded())
    let width = image.width + 2 * padding
    let height = image.height + 2 * padding
    guard let context = windowCanvas(width: width, height: height, colorSpace: image.colorSpace),
          let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [
              CGColor(red: 0.22, green: 0.34, blue: 0.66, alpha: 1),
              CGColor(red: 0.56, green: 0.33, blue: 0.67, alpha: 1)
            ] as CFArray, locations: [0, 1]
          ) else { return nil }
    context.drawLinearGradient(
      gradient, start: .zero, end: CGPoint(x: width, y: height), options: []
    )
    context.draw(image, in: CGRect(x: padding, y: padding, width: image.width, height: image.height))
    return context.makeImage()
  }

  private static func windowCanvas(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
    guard width > 0, height > 0, width <= ScreenshotImageLimits.maximumPixels / height,
          let rgb = colorSpace.flatMap({ $0.model == .rgb ? $0 : nil })
            ?? CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
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
    guard !AppDelegate.isTesting else { return nil }
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
    let process = try processFactory(mode, output)
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
