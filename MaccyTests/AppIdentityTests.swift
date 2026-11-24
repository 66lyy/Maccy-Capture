import AppKit
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct AppIdentityTests {
  @Test("Exception diagnostics describe windows without exposing their private titles or user-info values")
  func exceptionReportPrivacy() {
    let window = NSWindow(
      contentRect: NSRect(x: 20, y: 30, width: 160, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.title = "Private title sentinel"
    defer { window.close() }

    let exception = NSException(
      name: .internalInconsistencyException, reason: "Layout failed for \(window.title)",
      userInfo: ["DiagnosticKey": "Private value sentinel"]
    )
    let frame = "AppKit __NSWindowGetDisplayCycleObserverForLayout_block_invoke"
    let report = ExceptionDiagnosticText(exception, [frame])
    #expect(report.contains("Exception: NSInternalInconsistencyException"))
    #expect(report.contains("Reason: Layout failed for [redacted]"))
    #expect(report.contains("DiagnosticKey"))
    #expect(report.contains("NSWindow title=[redacted] frame="))
    #expect(report.contains("visible=no key=no contentView="))
    #expect(report.contains(frame))
    #expect(!report.contains("Private title sentinel"))
    #expect(!report.contains("Private value sentinel"))
    #expect(ExceptionDiagnosticText(exception, []).contains("Reason: [redacted outside window layout]"))
  }

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
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Maccy Capture")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "CaptureIcon")
    #expect(AppIdentity.isCustomizedBuild)
    #expect(SoftwareUpdater().isAvailable)
    let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    #expect(feedURL == "https://github.com/66lyy/Maccy-Capture/releases/latest/download/capture-appcast.xml")
    #expect(Bundle.main.url(forResource: "appcast", withExtension: "xml") == nil)
    #expect(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool == true)
  }

  @Test("The About panel links to Maccy Capture and preserves contributor credit")
  func aboutLinks() {
    let credits = About().credits
    var links: [String: String] = [:]
    credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, range, _ in
      if let url = value as? String {
        links[credits.attributedSubstring(from: range).string] = url
      }
    }
    #expect(links == [
      "Releases": "https://github.com/66lyy/Maccy-Capture/releases",
      "GitHub": "https://github.com/66lyy/Maccy-Capture",
      "Issues": "https://github.com/66lyy/Maccy-Capture/issues",
      "Sasha Koss": "https://koss.nocorp.me"
    ])
  }

  @Test("The app and default menu item use the capture artwork")
  func captureArtwork() throws {
    let iconURL = try #require(Bundle.main.url(forResource: "CaptureIcon", withExtension: "icns"))
    let icon = try #require(NSImage(contentsOf: iconURL))
    #expect(icon.isValid)
    let updateAlertIcon = try #require(NSImage(named: NSImage.applicationIconName))
    let iconData = try #require(icon.tiffRepresentation)
    #expect(updateAlertIcon.tiffRepresentation == iconData)
    let menuImage = try #require(NSImage(named: .captureStatusBar))
    #expect(menuImage.isTemplate)
    #expect(MenuIcon.maccy.image === menuImage)
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
    defaults.setPersistentDomain(["formatJSON": false, "showFooter": false], forName: source)
    defaults.setPersistentDomain(["showFooter": true], forName: destination)
    AppIdentity.migratePreferences(defaults: defaults, destination: destination, source: source)
    let migrated = try #require(defaults.persistentDomain(forName: destination))
    #expect(migrated["formatJSON"] as? Bool == false)
    #expect(migrated["showFooter"] as? Bool == true)
    #expect(migrated[AppIdentity.migrationKey] as? Bool == true)
    #expect(defaults.persistentDomain(forName: source)?["showFooter"] as? Bool == false)
    defaults.setPersistentDomain(["formatJSON": true], forName: source)
    AppIdentity.migratePreferences(defaults: defaults, destination: destination, source: source)
    #expect(defaults.persistentDomain(forName: destination)?["formatJSON"] as? Bool == false)
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
