import AppKit
import Sparkle

@MainActor
@Observable
final class SoftwareUpdater: NSObject, SPUUpdaterDelegate {
  static let shared = SoftwareUpdater()
  static let automaticChecksKey = "MaccyCaptureAutomaticUpdateChecks"
  static let channelKey = "MaccyCaptureUpdateChannel"

  private static let automaticCheckInterval: Duration = .seconds(24 * 60 * 60)
  private static let automaticCheckRetryInterval: Duration = .seconds(30)

  private static var isSupportedBuild: Bool {
    AppIdentity.isCustomizedBuild &&
      Data(base64Encoded: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")?.count == 32
  }

  var isAvailable: Bool { Self.isSupportedBuild }

  var automaticallyChecksForUpdates: Bool {
    didSet {
      guard automaticallyChecksForUpdates != oldValue else { return }
      defaults.set(automaticallyChecksForUpdates, forKey: Self.automaticChecksKey)
      if automaticallyChecksForUpdates {
        attemptAutomaticCheck()
      } else {
        cancelAutomaticChecks()
      }
    }
  }

  var channel: RepositoryUpdateFeed.Channel {
    didSet {
      defaults.set(channel.rawValue, forKey: Self.channelKey)
      statusKey = "UpdateReady"
    }
  }

  private(set) var isChecking = false
  private(set) var statusKey = "UpdateReady"
  var isBusy: Bool { isChecking || sparkle?.updater.sessionInProgress == true }
  var currentVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    return "\(version) (\(build))"
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let load: (URLRequest) async throws -> (Data, URLResponse)
  @ObservationIgnored private let canCheck: () -> Bool
  @ObservationIgnored private let hasActiveCapture: () -> Bool
  @ObservationIgnored private let sleep: (Duration) async throws -> Void
  @ObservationIgnored private let progress: (any UpdateCheckProgress)?
  @ObservationIgnored private var sparkle: (updater: SPUUpdater, driver: UpdateUserDriver)?
  @ObservationIgnored private var automaticCheckTimer: Task<Void, Never>?
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  @ObservationIgnored private var isCheckingAutomatically = false
  @ObservationIgnored private var resolved: RepositoryUpdateFeed.Resolved?
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var isUpdaterStarted = false

  init(
    defaults: UserDefaults = .standard,
    load: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await RepositoryUpdateSession().load($0) },
    canCheck: @escaping () -> Bool = { !AppDelegate.isTesting && SoftwareUpdater.isSupportedBuild },
    hasActiveCapture: @escaping () -> Bool = { ScreenshotCapture.shared.hasActiveCapture },
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    progress: (any UpdateCheckProgress)? = nil
  ) {
    self.defaults = defaults
    self.load = load
    self.canCheck = canCheck
    self.hasActiveCapture = hasActiveCapture
    self.sleep = sleep
    self.progress = progress
    automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    channel = defaults.string(forKey: Self.channelKey).flatMap(RepositoryUpdateFeed.Channel.init(rawValue:)) ?? .stable
    super.init()
  }

  func start() {
    guard canCheck(), !isStarted else { return }
    isStarted = true
    attemptAutomaticCheck()
  }

  func checkForUpdates() {
    guard canCheck(), !isBusy else { return }
    check(userInitiated: true)
  }

  func stop() {
    isStarted = false
    cancelAutomaticChecks()
    checkTask?.cancel()
  }

  private func cancelAutomaticChecks() {
    automaticCheckTimer?.cancel()
    automaticCheckTimer = nil
    if isCheckingAutomatically {
      checkTask?.cancel()
    }
  }

  private func attemptAutomaticCheck() {
    guard isStarted, automaticallyChecksForUpdates else { return }
    if isBusy || hasActiveCapture() {
      scheduleAutomaticCheck(after: Self.automaticCheckRetryInterval)
    } else {
      check(userInitiated: false)
    }
  }

  private func scheduleAutomaticCheck(after delay: Duration) {
    guard isStarted, automaticallyChecksForUpdates else { return }
    automaticCheckTimer?.cancel()
    automaticCheckTimer = Task { [weak self, sleep] in
      do {
        try await sleep(delay)
        try Task.checkCancellation()
      } catch {
        return
      }
      guard let self else { return }
      automaticCheckTimer = nil
      attemptAutomaticCheck()
    }
  }

  private func check(userInitiated: Bool) {
    let feed = RepositoryUpdateFeed(channel: channel)
    isChecking = true
    isCheckingAutomatically = !userInitiated
    statusKey = "UpdateChecking"
    let progress = userInitiated ? progress ?? sparkleUpdater().driver : nil
    progress?.showChecking { [weak self] in self?.checkTask?.cancel() }
    checkTask = Task { [weak self] in
      guard let self else { return }
      var nextCheckDelay = Self.automaticCheckInterval
      defer {
        isChecking = false
        isCheckingAutomatically = false
        checkTask = nil
        if !userInitiated, !Task.isCancelled {
          scheduleAutomaticCheck(after: nextCheckDelay)
        }
      }
      do {
        try Task.checkCancellation()
        let (data, response) = try await loadForDiscovery(feed.request())
        try Task.checkCancellation()
        if !userInitiated, hasActiveCapture() {
          nextCheckDelay = Self.automaticCheckRetryInterval
          statusKey = "UpdateReady"
          return
        }
        let tags = try feed.releaseTags(data: data, response: response)
        let release = try await feed.resolve(tags: tags, load: loadForDiscovery)
        try Task.checkCancellation()
        if !userInitiated, hasActiveCapture() {
          nextCheckDelay = Self.automaticCheckRetryInterval
          statusKey = "UpdateReady"
          return
        }
        resolved = release
        let updater = prepareUpdater()
        if !isUpdaterStarted {
          try updater.start()
          isUpdaterStarted = true
        }
        if userInitiated {
          updater.checkForUpdates()
        } else {
          updater.checkForUpdatesInBackground()
        }
      } catch {
        resolved = nil
        progress?.hideChecking()
        if Task.isCancelled || error is CancellationError {
          statusKey = "UpdateReady"
          return
        }
        switch error {
        case RepositoryUpdateFeed.Failure.unavailable: statusKey = "UpdateReleaseUnavailable"
        default: statusKey = Self.failureStatus(error as NSError)
        }
        progress?.showFailure(message: text(statusKey))
      }
    }
  }

  private func loadForDiscovery(_ request: URLRequest) async throws -> (Data, URLResponse) {
    do {
      return try await load(request)
    } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) {
      try Task.checkCancellation()
      try await sleep(.seconds(1))
      try Task.checkCancellation()
      return try await load(request)
    }
  }

  private static func failureStatus(_ error: NSError) -> String {
    let cause: NSError
    if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.downloadError.rawValue),
       let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      cause = underlying
    } else {
      cause = error
    }
    guard let networkError = cause as? URLError else { return "UpdateCheckFailed" }
    switch networkError.code {
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
         .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
         .clientCertificateRequired:
      return "UpdateSecureConnectionFailed"
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
         .dnsLookupFailed:
      return "UpdateNetworkFailed"
    default:
      return "UpdateCheckFailed"
    }
  }

  private func sparkleUpdater() -> (updater: SPUUpdater, driver: UpdateUserDriver) {
    if let sparkle { return sparkle }
    let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
    let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
    sparkle = (updater, driver)
    return (updater, driver)
  }

  private func prepareUpdater() -> SPUUpdater {
    let updater = sparkleUpdater().updater
    updater.automaticallyChecksForUpdates = false
    updater.automaticallyDownloadsUpdates = false
    updater.sendsSystemProfile = false
    updater.userAgentString = "MaccyCapture/Updates"
    updater.clearFeedURLFromUserDefaults()
    return updater
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    resolved?.feedURL.absoluteString
  }

  func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

  func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

  func updater(
    _ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck
  ) throws {
    guard resolved?.downloadURL(for: updateItem.fileURL, length: updateItem.contentLength) != nil else {
      throw NSError(
        domain: "MaccyCaptureUpdates", code: 1,
        userInfo: [NSLocalizedDescriptionKey: text("UpdateUntrustedPackage")]
      )
    }
    statusKey = "UpdateFound"
  }

  func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
    false
  }

  func updater(
    _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest
  ) {
    guard let resolved else {
      request.url = URL(string: "about:blank")
      return
    }
    resolved.configureDownload(request, enclosure: item.fileURL, length: item.contentLength)
  }

  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    AppState.shared.appDelegate?.prepareForUpdateRestart()
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
  ) {
    resolved = nil
    guard let error = error as NSError? else {
      statusKey = "UpdateReady"
      return
    }
    guard error.domain == SUSparkleErrorDomain, error.code == Int(SUError.noUpdateError.rawValue) else {
      statusKey = Self.failureStatus(error)
      return
    }
    let reason = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
    statusKey = reason == SPUNoUpdateFoundReason.onLatestVersion.rawValue ||
      reason == SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue ? "UpdateUpToDate" : "UpdateNoApplicableVersion"
  }

  private func text(_ key: String) -> String {
    let fallback = Bundle.main.url(forResource: "en", withExtension: "lproj").flatMap(Bundle.init(url:))
    return Bundle.main.localizedString(forKey: key, value: fallback?.localizedString(forKey: key, value: nil,
      table: "GeneralSettings"), table: "GeneralSettings")
  }
}

@MainActor
protocol UpdateCheckProgress: AnyObject {
  func showChecking(cancellation: @escaping () -> Void)
  func hideChecking()
  func showFailure(message: String)
}

/// Shows Sparkle's checking window while release discovery runs, and hands it over to
/// Sparkle's own check without closing it first so the window never blinks.
final class UpdateUserDriver: SPUStandardUserDriver, UpdateCheckProgress {
  private final class PendingCheck {
    var cancel: (() -> Void)?

    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
  }

  private var pendingCheck: PendingCheck?

  func showChecking(cancellation: @escaping () -> Void) {
    let pending = PendingCheck(cancellation)
    pendingCheck = pending
    super.showUserInitiatedUpdateCheck {
      let cancel = pending.cancel
      pending.cancel = nil
      cancel?()
    }
  }

  func hideChecking() {
    guard pendingCheck != nil else { return }
    dismissUpdateInstallation()
  }

  func showFailure(message: String) {
    NSApp.activate()
    let error = NSError(domain: "MaccyCaptureUpdates", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    showUpdaterError(error, acknowledgement: {})
  }

  override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    guard let pending = pendingCheck else {
      super.showUserInitiatedUpdateCheck(cancellation: cancellation)
      return
    }
    pendingCheck = nil
    if pending.cancel == nil { cancellation() } else { pending.cancel = cancellation }
  }

  override func dismissUpdateInstallation() {
    pendingCheck = nil
    super.dismissUpdateInstallation()
  }
}
