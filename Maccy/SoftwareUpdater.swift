import AppKit
import Sparkle

@MainActor
@Observable
final class SoftwareUpdater: NSObject, SPUUpdaterDelegate {
  static let shared = SoftwareUpdater()
  static let automaticChecksKey = "MaccyCaptureAutomaticUpdateChecks"

  var isAvailable: Bool {
    AppIdentity.isCustomizedBuild &&
      Data(base64Encoded: Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? "")?.count == 32
  }

  var automaticallyChecksForUpdates: Bool {
    didSet {
      defaults.set(automaticallyChecksForUpdates, forKey: Self.automaticChecksKey)
      guard isStarted else { return }
      scheduleChecks()
    }
  }

  private(set) var isChecking = false
  private(set) var hasCredential = false
  private(set) var statusKey = "UpdateReady"
  var isBusy: Bool { isChecking || updaterController?.updater.sessionInProgress == true }
  var currentVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    return "\(version) (\(build))"
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let readCredential: (Bool) throws -> String?
  @ObservationIgnored private let writeCredential: (String) throws -> Void
  @ObservationIgnored private let removeCredential: () throws -> Void
  @ObservationIgnored private let load: (URLRequest) async throws -> (Data, URLResponse)
  @ObservationIgnored private var updaterController: SPUStandardUpdaterController?
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  @ObservationIgnored private var scheduleTask: Task<Void, Never>?
  @ObservationIgnored private var resolved: RepositoryUpdateFeed.Resolved?
  @ObservationIgnored private var isStarted = false
  @ObservationIgnored private var isUpdaterStarted = false

  init(
    defaults: UserDefaults = .standard,
    readCredential: @escaping (Bool) throws -> String? = { try RepositoryUpdateCredential.read(allowInteraction: $0) },
    writeCredential: @escaping (String) throws -> Void = RepositoryUpdateCredential.write,
    removeCredential: @escaping () throws -> Void = RepositoryUpdateCredential.remove,
    load: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await RepositoryUpdateSession().load($0) }
  ) {
    self.defaults = defaults
    self.readCredential = readCredential
    self.writeCredential = writeCredential
    self.removeCredential = removeCredential
    self.load = load
    automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticChecksKey) as? Bool ?? true
    super.init()
  }

  func start() {
    guard !AppDelegate.isTesting, isAvailable, !isStarted else { return }
    isStarted = true
    refreshCredential()
    scheduleChecks()
  }

  func saveAccessToken(_ token: String) -> Bool {
    guard !isBusy else { return false }
    let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      guard RepositoryUpdateCredential.valid(token) else { throw RepositoryUpdateCredential.Failure.invalidToken }
      try writeCredential(token)
      hasCredential = true
      statusKey = "UpdateCredentialSaved"
      return true
    } catch {
      statusKey = "UpdateCredentialFailed"
      return false
    }
  }

  func clearAccessToken() {
    guard !isBusy else { return }
    do {
      try removeCredential()
      updaterController?.updater.httpHeaders = nil
      hasCredential = false
      statusKey = "UpdateCredentialRemoved"
    } catch {
      statusKey = "UpdateCredentialFailed"
    }
  }

  func checkForUpdates() {
    check(userInitiated: true)
  }

  func stop() {
    scheduleTask?.cancel()
    checkTask?.cancel()
    scheduleTask = nil
    checkTask = nil
    isStarted = false
  }

  private func refreshCredential() {
    do {
      hasCredential = try readCredential(false) != nil
    } catch {
      statusKey = "UpdateCredentialFailed"
    }
  }

  private func scheduleChecks() {
    scheduleTask?.cancel()
    guard automaticallyChecksForUpdates else { return }
    scheduleTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.check(userInitiated: false)
        do {
          try await Task.sleep(for: .seconds(21_600))
        } catch { return }
      }
    }
  }

  private func check(userInitiated: Bool) {
    guard isAvailable, !AppDelegate.isTesting, !isBusy else { return }
    if !userInitiated, ScreenshotCapture.shared.hasActiveCapture { return }
    isChecking = true
    statusKey = "UpdateChecking"
    checkTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isChecking = false
        checkTask = nil
      }
      do {
        let token = try readCredential(userInitiated)
        hasCredential = token != nil
        let feed = RepositoryUpdateFeed()
        let (data, response) = try await load(feed.request(token: token))
        try Task.checkCancellation()
        resolved = try feed.resolve(data: data, response: response)
        let updater = prepareUpdater()
        updater.httpHeaders = ["Accept": "application/octet-stream"]
        if let token { updater.httpHeaders?["Authorization"] = "Bearer \(token)" }
        if !isUpdaterStarted {
          try updater.start()
          isUpdaterStarted = true
        }
        if userInitiated {
          updater.checkForUpdates()
        } else {
          updater.checkForUpdatesInBackground()
        }
      } catch is CancellationError {
        statusKey = "UpdateReady"
      } catch RepositoryUpdateFeed.Failure.authorizationRequired {
        statusKey = "UpdateAuthorizationRequired"
      } catch RepositoryUpdateFeed.Failure.unavailable {
        statusKey = "UpdateReleaseUnavailable"
      } catch is RepositoryUpdateCredential.Failure {
        statusKey = "UpdateCredentialFailed"
      } catch {
        statusKey = "UpdateCheckFailed"
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
      request.setValue(nil, forHTTPHeaderField: "Authorization")
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
