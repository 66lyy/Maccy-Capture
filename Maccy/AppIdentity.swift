import Foundation

nonisolated enum AppIdentity {
  static let customizedIdentifier = "local.maccy.capture"
  static let originalIdentifier = "org.p0deje.Maccy"
  static let migrationKey = "MaccyCapturePreferencesMigrated"

  static var isCustomizedBuild: Bool {
    Bundle.main.bundleIdentifier == customizedIdentifier
  }

  static func migratePreferences(
    defaults: UserDefaults = .standard,
    destination: String = customizedIdentifier,
    source: String = originalIdentifier
  ) {
    var current = defaults.persistentDomain(forName: destination) ?? [:]
    guard current[migrationKey] as? Bool != true else { return }
    let previous = defaults.persistentDomain(forName: source) ?? [:]
    current = previous.merging(current) { _, existing in existing }
    current[migrationKey] = true
    defaults.setPersistentDomain(current, forName: destination)
  }

  static func relaunchArguments(bundleURL: URL, processIdentifier: Int32) -> [String] {
    [
      "-c",
      """
      attempt=0
      while /bin/kill -0 "$1" 2>/dev/null; do
        attempt=$((attempt + 1))
        [ "$attempt" -le 100 ] || exit 1
        /bin/sleep 0.1
      done
      exec /usr/bin/open -n "$2"
      """,
      "maccy-capture-relaunch",
      String(processIdentifier),
      bundleURL.path
    ]
  }
}
