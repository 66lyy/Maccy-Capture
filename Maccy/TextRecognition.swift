import CoreGraphics
import Foundation
import Vision

nonisolated enum TextRecognition {
  typealias Operation = @Sendable (CGImage, Cancellation) throws -> String
  private static let screenshotQueue = DispatchQueue(label: "local.maccy.capture.ocr", qos: .userInitiated)
  static let clipboardQueue = DispatchQueue(label: "org.p0deje.Maccy.textRecognition", qos: .utility)

  private enum Failure: Error {
    case render
  }

  nonisolated final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?

    func checkCancellation() throws {
      lock.lock()
      defer { lock.unlock() }
      if cancelled { throw CancellationError() }
    }

    fileprivate func install(_ request: VNRequest?) throws {
      lock.lock()
      defer { lock.unlock() }
      if cancelled { request?.cancel(); throw CancellationError() }
      self.request = request
    }

    func cancel() {
      lock.lock()
      defer { lock.unlock() }
      cancelled = true
      request?.cancel()
      request = nil
    }
  }

  static func recognizeScreenshot(
    render: @escaping @Sendable () -> CGImage?, operation: @escaping Operation
  ) async throws -> String {
    let cancellation = Cancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        screenshotQueue.async {
          continuation.resume(with: Result {
            try cancellation.checkCancellation()
            guard let image = render() else { throw Failure.render }
            try cancellation.checkCancellation()
            let value = try operation(image, cancellation)
            try cancellation.checkCancellation()
            return value
          })
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  static func recognizeScreenshot(_ image: CGImage, cancellation: Cancellation = Cancellation()) throws -> String {
    try cancellation.checkCancellation()
    let request = accurateRequest()
    let supported = try request.supportedRecognitionLanguages()
    let languages = ["zh-Hans", "zh-Hant", "en-US"].filter(supported.contains)
    if !languages.isEmpty { request.recognitionLanguages = languages }
    request.automaticallyDetectsLanguage = true
    request.minimumTextHeight = 0
    let input = paddedNarrowImage(image) ?? image
    let text = try recognizeScreenshot(input, request: request, cancellation: cancellation)
    guard text.isEmpty else { return text }

    let retry = accurateRequest()
    retry.minimumTextHeight = 0
    retry.usesLanguageCorrection = false
    if !languages.isEmpty { retry.recognitionLanguages = languages }
    return try recognizeScreenshot(enlargedImage(image) ?? image, request: retry, cancellation: cancellation)
  }

  static func recognizeClipboardImage(imageData: Data?, fileURL: URL?) async -> String? {
    await withCheckedContinuation { continuation in
      clipboardQueue.async {
        do {
          continuation.resume(returning: try performClipboardRecognition(imageData: imageData, fileURL: fileURL))
        } catch {
          print("Unable to perform the request: \(error).")
          continuation.resume(returning: nil)
        }
      }
    }
  }

  private static func accurateRequest() -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    return request
  }

  static func performClipboardRecognition(imageData: Data?, fileURL: URL?) throws -> String? {
    guard let data = imageData ?? fileURL.flatMap({ $0.isFileURL ? try? Data(contentsOf: $0) : nil }) else { return nil }
    let request = accurateRequest()
    request.automaticallyDetectsLanguage = true
    return try recognize(using: VNImageRequestHandler(data: data), request: request)?.joined(separator: "\n")
  }

  private static func recognizeScreenshot(
    _ image: CGImage, request: VNRecognizeTextRequest, cancellation: Cancellation
  ) throws -> String {
    let lines = try recognize(
      using: VNImageRequestHandler(cgImage: image, orientation: .up), request: request, cancellation: cancellation
    )
    return (lines ?? [])
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
  }

  private static func recognize(
    using handler: VNImageRequestHandler, request: VNRecognizeTextRequest, cancellation: Cancellation? = nil
  ) throws -> [String]? {
    try cancellation?.install(request)
    defer { try? cancellation?.install(nil) }
    try handler.perform([request])
    try cancellation?.checkCancellation()
    return request.results?.compactMap { $0.topCandidates(1).first?.string }
  }

  static func paddedNarrowImage(_ image: CGImage) -> CGImage? {
    let margin = 36
    let maxContentSize = 3840 - 2 * margin
    let longestSide = max(image.width, image.height)
    guard min(image.width, image.height) < 48, longestSide <= maxContentSize,
          let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let scale = min(3, Double(maxContentSize) / Double(longestSide))
    let width = Int(Double(image.width) * scale)
    let height = Int(Double(image.height) * scale)
    guard let context = CGContext(
      data: nil, width: width + 2 * margin, height: height + 2 * margin, bitsPerComponent: 8,
      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.setFillColor(cornerBackground(of: image, in: space))
    context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: margin, y: margin, width: width, height: height))
    return context.makeImage()
  }

  private static func cornerBackground(of image: CGImage, in space: CGColorSpace) -> CGColor {
    let fallback = CGColor(gray: 1, alpha: 1)
    guard let context = CGContext(
      data: nil, width: 4, height: 1, bitsPerComponent: 8, bytesPerRow: 16,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ), let data = context.data else { return fallback }
    let corners = [(0, 0), (image.width - 1, 0), (0, image.height - 1), (image.width - 1, image.height - 1)]
    for (index, corner) in corners.enumerated() {
      guard let pixel = image.cropping(to: CGRect(x: corner.0, y: corner.1, width: 1, height: 1)) else {
        return fallback
      }
      context.draw(pixel, in: CGRect(x: index, y: 0, width: 1, height: 1))
    }
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    let components = (0..<3).map { channel in
      CGFloat((0..<4).reduce(0) { $0 + Int(pixels[$1 * 4 + channel]) }) / 1020
    }
    return CGColor(colorSpace: space, components: components + [1]) ?? fallback
  }

  private static func enlargedImage(_ image: CGImage) -> CGImage? {
    let scale = min(3, 3840.0 / Double(max(image.width, image.height)))
    guard scale > 1, let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: Int(Double(image.width) * scale), height: Int(Double(image.height) * scale),
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: context.width, height: context.height)
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(bounds)
    context.interpolationQuality = .high
    context.draw(image, in: bounds)
    return context.makeImage()
  }
}
