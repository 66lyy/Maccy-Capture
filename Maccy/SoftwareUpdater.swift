import Sparkle

@Observable
class SoftwareUpdater {
  var isAvailable: Bool { !AppIdentity.isCustomizedBuild }

  var automaticallyChecksForUpdates = false {
    didSet {
      guard isAvailable else { return }
      updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }
  }

  private var updater: SPUUpdater { updaterController.updater }
  private var automaticallyChecksForUpdatesObservation: NSKeyValueObservation?

  @ObservationIgnored private lazy var updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
  )

  init() {
    guard isAvailable else { return }
    automaticallyChecksForUpdatesObservation = updater.observe(
      \.automaticallyChecksForUpdates,
      options: [.initial, .new, .old]
    ) { [unowned self] _, change in
      guard change.newValue != change.oldValue, let newValue = change.newValue else {
        return
      }

      MainActor.assumeIsolated {
        self.automaticallyChecksForUpdates = newValue
      }
    }
  }

  func checkForUpdates() {
    guard isAvailable else { return }
    updater.checkForUpdates()
  }
}
