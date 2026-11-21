import Defaults
import KeyboardShortcuts
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
  nonisolated static let isTesting = CommandLine.arguments.contains("enable-testing")
  var panel: FloatingPanel<ContentView>!

  @objc
  private lazy var statusItem: NSStatusItem = {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.behavior = .removalAllowed
    statusItem.button?.action = #selector(performStatusItemClick)
    statusItem.button?.image = Defaults[.menuIcon].image
    statusItem.button?.imagePosition = .imageLeft
    statusItem.button?.target = self
    return statusItem
  }()

  // Base accessibility label for the status item; kept separate from the optional
  // dynamic `title` (recent copy text) so VoiceOver always announces something
  // meaningful even when that preference is off or the app is disabled.
  private func updateStatusItemAccessibilityLabel() {
    var accessibilityLabel = NSLocalizedString("status_item_accessibility_label", comment: "")
    if isStatusItemDisabled {
      accessibilityLabel += " — \(NSLocalizedString("status_item_disabled_accessibility_suffix", comment: ""))"
    }
    statusItem.button?.setAccessibilityLabel(accessibilityLabel)
  }

  private var isStatusItemDisabled: Bool {
    Defaults[.ignoreEvents] || Defaults[.enabledPasteboardTypes].isEmpty
  }

  private var statusItemVisibilityObserver: NSKeyValueObservation?
  private var rejectedDuplicateLaunch = false
  private var isRestarting = false

  func applicationWillFinishLaunching(_ notification: Notification) { // swiftlint:disable:this function_body_length
    if AppIdentity.isCustomizedBuild,
       let iconURL = Bundle.main.url(forResource: "CaptureIcon", withExtension: "icns"),
       let icon = NSImage(contentsOf: iconURL) {
      NSApp.applicationIconImage = icon
      let iconName = NSImage.applicationIconName
      NSImage(named: iconName)?.setName(nil)
      icon.setName(iconName)
    }
    if !Self.isTesting, AppIdentity.isCustomizedBuild {
      AppIdentity.migratePreferences()
    }
    if !Self.isTesting, let identifier = Bundle.main.bundleIdentifier,
       NSWorkspace.shared.runningApplications.contains(where: {
         ($0.bundleIdentifier == identifier ||
          (AppIdentity.isCustomizedBuild && $0.bundleIdentifier == AppIdentity.originalIdentifier)) &&
         $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
       }) {
      rejectedDuplicateLaunch = true
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("ScreenshotDuplicateTitle", tableName: "GeneralSettings", comment: "")
      alert.informativeText = NSLocalizedString("ScreenshotDuplicateHelp", tableName: "GeneralSettings", comment: "")
      alert.addButton(withTitle: NSLocalizedString("ScreenshotQuitCopy", tableName: "GeneralSettings", comment: ""))
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
      NSApp.terminate(self)
      return
    }

    #if DEBUG
    if Self.isTesting {
      SPUUpdater(hostBundle: Bundle.main,
                 applicationBundle: Bundle.main,
                 userDriver: SPUStandardUserDriver(hostBundle: Bundle.main, delegate: nil),
                 delegate: nil)
      .automaticallyChecksForUpdates = false
      // Start from a clean slate for the isolated testing preferences.
      UserDefaults.standard.removePersistentDomain(forName: Defaults.Keys.testingSuiteName)
    }
    #endif

    // Bridge FloatingPanel via AppDelegate.
    AppState.shared.appDelegate = self

    Clipboard.shared.onNewCopy { History.shared.add($0) }
    if !Self.isTesting {
      Clipboard.shared.start()
    }

    Task {
      for await _ in Defaults.updates(.clipboardCheckInterval, initial: false) {
        Clipboard.shared.restart()
      }
    }

    statusItemVisibilityObserver = observe(\.statusItem.isVisible, options: .new) { _, change in
      if let newValue = change.newValue, Defaults[.showInStatusBar] != newValue {
        Defaults[.showInStatusBar] = newValue
      }
    }

    Task {
      for await value in Defaults.updates(.showInStatusBar) {
        statusItem.isVisible = value
      }
    }

    Task {
      for await value in Defaults.updates(.menuIcon, initial: false) {
        statusItem.button?.image = value.image
      }
    }

    synchronizeMenuIconText()
    Task {
      for await value in Defaults.updates(.showRecentCopyInMenuBar) {
        if value {
          statusItem.button?.title = AppState.shared.menuIconText
        } else {
          statusItem.button?.title = ""
        }
      }
    }

    updateStatusItemAccessibilityLabel()

    Task {
      for await _ in Defaults.updates(.ignoreEvents) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }

    Task {
      for await _ in Defaults.updates(.enabledPasteboardTypes) {
        statusItem.button?.appearsDisabled = isStatusItemDisabled
        updateStatusItemAccessibilityLabel()
      }
    }
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    guard !rejectedDuplicateLaunch else { return }
    migrateUserDefaults()
    disableUnusedGlobalHotkeys()

    if !Self.isTesting {
      KeyboardShortcuts.onKeyUp(for: .screenshot) {
        ScreenshotCapture.shared.captureMainDisplay()
      }
      KeyboardShortcuts.onKeyUp(for: .screenshotSelection) {
        ScreenshotCapture.shared.captureSelection()
      }
      KeyboardShortcuts.onKeyUp(for: .pinScreenshot) {
        ScreenshotCapture.shared.captureSelection(pinToScreen: true)
      }
      KeyboardShortcuts.onKeyUp(for: .pinClipboardImage) {
        ScreenshotCapture.shared.pinClipboardImage()
      }
      KeyboardShortcuts.onKeyUp(for: .togglePinnedClickThrough) {
        ScreenshotCapture.shared.togglePinnedClickThrough()
      }
    }

    panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Defaults[.windowSize]),
      identifier: Bundle.main.bundleIdentifier ?? "org.p0deje.Maccy",
      statusBarButton: statusItem.button,
      onClose: { AppState.shared.popup.reset() }
    ) {
      ContentView()
    }
    if !Self.isTesting {
      SoftwareUpdater.shared.start()
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    guard let panel else { return false }
    panel.toggle(height: AppState.shared.popup.height)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    guard !rejectedDuplicateLaunch else { return }
    SoftwareUpdater.shared.stop()
    ScreenshotCapture.shared.shutDown()
    if !isRestarting, Defaults[.clearOnQuit] {
      AppState.shared.history.clear()
    }
  }

  func prepareForUpdateRestart() {
    isRestarting = true
  }

  func restartCurrentApplication() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = AppIdentity.relaunchArguments(
      bundleURL: Bundle.main.bundleURL, processIdentifier: ProcessInfo.processInfo.processIdentifier
    )
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      isRestarting = true
      NSApp.terminate(self)
    } catch {
      let alert = NSAlert()
      alert.messageText = NSLocalizedString("ScreenshotRestartFailed", tableName: "GeneralSettings", comment: "")
      alert.informativeText = Bundle.main.bundleURL.path
      alert.runModal()
    }
  }

  private func ensureMigration(key: String, _ action: () -> Void) {
    if Defaults[.migrations][key] != true {
      action()
      Defaults[.migrations][key] = true
    }
  }

  @MainActor
  private func migrateUserDefaults() {
    ensureMigration(key: "2024-07-01-version-2") {
      // Start 2.x from scratch.
      Defaults.reset(.migrations)

      // Inverse hide* configuration keys.
      Defaults[.showFooter] = !UserDefaults.standard.bool(forKey: "hideFooter")
      Defaults[.showSearch] = !UserDefaults.standard.bool(forKey: "hideSearch")
      Defaults[.showTitle] = !UserDefaults.standard.bool(forKey: "hideTitle")
      UserDefaults.standard.removeObject(forKey: "hideFooter")
      UserDefaults.standard.removeObject(forKey: "hideSearch")
      UserDefaults.standard.removeObject(forKey: "hideTitle")
    }

    ensureMigration(key: "2025-07-04-add-jpeg-heic") {
      var types = Defaults[.enabledPasteboardTypes]
      if !types.isDisjoint(with: StorageType.images.types) {
        types.formUnion(StorageType.images.types)
      }
      Defaults[.enabledPasteboardTypes] = types
    }

    ensureMigration(key: "2026-08-12-cleanup-orphaned-history-item-contents") {
      _ = try? Storage.shared.cleanupOrphanedContents()
    }

    ensureMigration(key: "2026-08-31-sanitize-history-item-titles") {
      _ = try? Storage.shared.sanitizeTitles()
    }

    ensureMigration(key: "2026-09-15-remove-unpersistable-contents") {
      _ = try? Storage.shared.removeUnpersistableContents()
    }

    // The following defaults are not used in Maccy 2.x
    // and should be removed in 3.x.
    // - LaunchAtLogin__hasMigrated
    // - avoidTakingFocus
    // - saratovSeparator
    // - maxMenuItemLength
    // - maxMenuItems
  }

  @objc
  private func performStatusItemClick() {
    let modifierFlags = (NSApp.currentEvent?.modifierFlags ?? [])
      .union(NSEvent.modifierFlags)
      .intersection(.deviceIndependentFlagsMask)

    if modifierFlags.contains(.option) {
      Defaults[.ignoreEvents].toggle()

      if modifierFlags.contains(.shift) {
        Defaults[.ignoreOnlyNextEvent] = Defaults[.ignoreEvents]
      }

      return
    }

    panel.toggle(height: AppState.shared.popup.height, at: .statusItem)
  }

  private func synchronizeMenuIconText() {
    _ = withObservationTracking {
      AppState.shared.menuIconText
    } onChange: {
      DispatchQueue.main.async {
        if Defaults[.showRecentCopyInMenuBar] {
          self.statusItem.button?.title = AppState.shared.menuIconText
        }
        self.synchronizeMenuIconText()
      }
    }
  }

  private func disableUnusedGlobalHotkeys() {
    let names: [KeyboardShortcuts.Name] = [.delete, .pin, .togglePreview]
    KeyboardShortcuts.disable(names)

    NotificationCenter.default.addObserver(
      forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"),
      object: nil,
      queue: nil
    ) { notification in
      guard let name = notification.userInfo?["name"] as? KeyboardShortcuts.Name,
            names.contains(name) else { return }
      MainActor.assumeIsolated {
        KeyboardShortcuts.disable(name)
      }
    }
  }
}
