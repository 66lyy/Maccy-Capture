import CoreGraphics

@MainActor
final class ScreenCapturePermission {
  enum Result: Equatable {
    case granted
    case requested
    case needsSettings
    case requestInProgress
  }

  private let preflight: @MainActor () -> Bool
  private let request: @MainActor () -> Bool
  private var hasRequested = false
  private var isRequesting = false

  init(
    preflight: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
    request: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() }
  ) {
    self.preflight = preflight
    self.request = request
  }

  func authorize() -> Result {
    guard !isRequesting else { return .requestInProgress }
    if preflight() { return .granted }
    guard !hasRequested else { return .needsSettings }
    hasRequested = true
    isRequesting = true
    defer { isRequesting = false }
    return request() ? .granted : .requested
  }
}
