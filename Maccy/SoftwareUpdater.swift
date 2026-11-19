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
  var isBusy: Bool { isChecking || updaterController?.updater.sessionInProgress == true }
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
  @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
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
    sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.defaults = defaults
    self.load = load
    self.canCheck = canCheck
    self.hasActiveCapture = hasActiveCapture
    self.sleep = sleep
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
        let (data, response) = try await load(feed.request())
        try Task.checkCancellation()
        if !userInitiated, hasActiveCapture() {
          nextCheckDelay = Self.automaticCheckRetryInterval
          statusKey = "UpdateReady"
          return
        }
        resolved = try feed.resolve(data: data, response: response)
        let updater = prepareUpdater()
        updater.httpHeaders = ["Accept": "application/octet-stream"]
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
        if Task.isCancelled || error is CancellationError {
          statusKey = "UpdateReady"
        } else if case RepositoryUpdateFeed.Failure.unavailable = error {
          statusKey = "UpdateReleaseUnavailable"
        } else {
          statusKey = "UpdateCheckFailed"
        }
      }
    }
  }

  private func prepareUpdater() -> SPUUpdater {
    if updaterController == nil {
      updaterController = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
      )
    }
    let updater = updaterController!.updater
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
    guard resolved?.permits(updateItem.fileURL, length: updateItem.contentLength) == true else {
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
    guard resolved?.permits(item.fileURL, length: item.contentLength) == true, request.url == item.fileURL else {
      request.url = URL(string: "about:blank")
      return
    }
    request.httpShouldHandleCookies = false
    request.cachePolicy = .reloadIgnoringLocalCacheData
  }

  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool { true }

  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    AppState.shared.appDelegate?.prepareForUpdateRestart()
  }

  func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
  ) {
    updater.httpHeaders = nil
    resolved = nil
    statusKey = error == nil || (error as NSError?)?.code == Int(SUError.noUpdateError.rawValue)
      ? "UpdateReady" : "UpdateCheckFailed"
  }

  private func text(_ key: String) -> String {
    NSLocalizedString(key, tableName: "GeneralSettings", comment: "")
  }
}
