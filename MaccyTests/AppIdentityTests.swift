import AppKit
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct AppIdentityTests {
  @Test("An existing screen recording grant never opens a request dialog")
  func existingGrant() {
    var requests = 0
    let permission = ScreenCapturePermission(preflight: { true }, request: { requests += 1; return true })
    #expect(permission.authorize() == .granted)
    #expect(requests == 0)
  }

  @Test("A denied request does not immediately trigger another permission dialog")
  func singleRequest() {
    var requests = 0
    let permission = ScreenCapturePermission(preflight: { false }, request: { requests += 1; return false })
    #expect(permission.authorize() == .requested)
    #expect(permission.authorize() == .needsSettings)
    #expect(permission.authorize() == .needsSettings)
    #expect(requests == 1)
  }

  @Test("A granted request permits capture without showing an extra help dialog")
  func grantedRequest() {
    let permission = ScreenCapturePermission(preflight: { false }, request: { true })
    #expect(permission.authorize() == .granted)
  }

  @Test("Permission request reentrancy cannot open a second system dialog")
  func reentrantRequest() {
    var requests = 0
    var nested: ScreenCapturePermission.Result?
    var permission: ScreenCapturePermission!
    permission = ScreenCapturePermission(preflight: { false }, request: {
      requests += 1
      nested = permission.authorize()
      return false
    })
    #expect(permission.authorize() == .requested)
    #expect(nested == .requestInProgress)
    #expect(requests == 1)
  }

  @Test("An external permission change is rechecked without another request")
  func permissionChanged() {
    var allowed = false
    var requests = 0
    let permission = ScreenCapturePermission(preflight: { allowed }, request: { requests += 1; return false })
    #expect(permission.authorize() == .requested)
    allowed = true
    #expect(permission.authorize() == .granted)
    #expect(requests == 1)
  }

  @Test("The customized application has an independent identity and no official updater")
  func independentIdentity() {
    #expect(AppIdentity.customizedIdentifier != AppIdentity.originalIdentifier)
    #expect(Bundle.main.bundleIdentifier == AppIdentity.customizedIdentifier)
    #expect(AppIdentity.isCustomizedBuild)
    #expect(!SoftwareUpdater().isAvailable)
  }

  @Test("Preference migration is local, preserves custom settings, and runs only once")
  func preferenceMigration() throws {
    let source = "local.maccy.fixture.source.\(UUID().uuidString)"
    let destination = "local.maccy.fixture.destination.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: destination))
    defer {
      defaults.removePersistentDomain(forName: source)
      defaults.removePersistentDomain(forName: destination)
    }
    defaults.setPersistentDomain(["screenshotSoundEnabled": false, "showFooter": false], forName: source)
    defaults.setPersistentDomain(["showFooter": true], forName: destination)
    AppIdentity.migratePreferences(defaults: defaults, destination: destination, source: source)
    let migrated = try #require(defaults.persistentDomain(forName: destination))
    #expect(migrated["screenshotSoundEnabled"] as? Bool == false)
    #expect(migrated["showFooter"] as? Bool == true)
    #expect(migrated[AppIdentity.migrationKey] as? Bool == true)
    #expect(defaults.persistentDomain(forName: source)?["showFooter"] as? Bool == false)
    defaults.setPersistentDomain(["screenshotSoundEnabled": true], forName: source)
    AppIdentity.migratePreferences(defaults: defaults, destination: destination, source: source)
    #expect(defaults.persistentDomain(forName: destination)?["screenshotSoundEnabled"] as? Bool == false)
  }

  @Test("Restart uses the exact application path as an argument, not a bundle lookup")
  func relaunchPath() {
    let bundleURL = URL(fileURLWithPath: "/private/tmp/Generated App's Folder/Maccy.app")
    let arguments = AppIdentity.relaunchArguments(bundleURL: bundleURL, processIdentifier: 12345)
    #expect(arguments.last == bundleURL.path)
    #expect(arguments[arguments.count - 2] == "12345")
    #expect(arguments[1].contains("exec /usr/bin/open -n \"$2\""))
    #expect(arguments[1].contains("/bin/kill -0 \"$1\""))
    #expect(!arguments[1].contains(bundleURL.path))
    #expect(!arguments[1].contains(AppIdentity.originalIdentifier))
  }
}
