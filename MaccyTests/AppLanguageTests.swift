import AppKit
import KeyboardShortcuts
import Testing
@testable import Maccy

@MainActor
@Suite(.serialized)
struct PreferencesWindowTests {
  @Test("Opening settings keeps enough height for the sidebar and controls")
  func opensAtUsableSize() async throws {
    try #require(AppDelegate.isTesting)
    let controller = PreferencesWindowController()
    let window = try #require(controller.window)
    defer { window.close() }

    controller.show()
    try await Task.sleep(for: .milliseconds(350))
    let contentView = try #require(window.contentView)
    contentView.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let settingsView = try #require(contentView.subviews.first)

    #expect(window.isVisible)
    #expect(window.contentLayoutRect.height >= window.contentMinSize.height - 44)
    #expect(window.frame.height >= window.contentMinSize.height - 1)
    #expect(contentView.bounds.width >= window.contentMinSize.width - 1)
    #expect(contentView.bounds.height >= window.contentMinSize.height - 1)
    #expect(settingsView.frame == contentView.bounds)
  }

  @Test("Navigation labels, page titles, and settings controls fit the window", arguments: [false, true])
  func settingsContentFits(useMinimumSize: Bool) async throws {
    try #require(AppDelegate.isTesting)
    for page in [PreferencesView.Page.appearance, .shortcuts, .ignore] {
      var frames: [String: CGRect] = [:]
      let controller = PreferencesWindowController(page: page) { id, frame in
        frames[id] = frame
      }
      let window = try #require(controller.window)
      defer { window.close() }

      if useMinimumSize {
        window.setContentSize(window.contentMinSize)
      }
      controller.show()
      try await Task.sleep(for: .milliseconds(350))
      let contentView = try #require(window.contentView)
      contentView.layoutSubtreeIfNeeded()
      window.displayIfNeeded()

      let visibleBounds = contentView.bounds
      let title = try #require(frames["title.\(page.id)"])
      #expect(title.width > 0)
      #expect(visibleBounds.contains(title))
      for item in PreferencesView.Page.allCases {
        let label = try #require(frames["navigation.\(item.id)"])
        #expect(label.width > 0)
        #expect(visibleBounds.contains(label))
        #expect(label.maxX < title.minX)
      }
      let detail = try #require(frames["detail.\(page.id)"])
      #expect(detail.minX >= title.minX - 1)
      #expect(detail.maxX <= visibleBounds.maxX)

      if page == .ignore {
        let categories = try ["applications", "pasteboardTypes", "regexp"].map { category in
          try #require(frames["ignore.category.\(category)"])
        }
        for label in categories {
          #expect(label.width > 20)
          #expect(detail.contains(label))
          #expect(visibleBounds.contains(label))
        }
        for (previous, next) in zip(categories, categories.dropFirst()) {
          #expect(!previous.intersects(next))
        }
      }

      if page == .shortcuts {
        let recorders = recorders(in: contentView)
        #expect(recorders.count == 9)
        for recorder in recorders {
          let frame = recorder.convert(recorder.bounds, to: contentView)
          #expect(frame.width > 0)
          #expect(frame.minX >= visibleBounds.minX && frame.maxX <= visibleBounds.maxX)
          if !useMinimumSize {
            #expect(visibleBounds.contains(frame))
          }
        }
      }
    }
  }

  @Test("A shortcut change ignores unrelated conflicts and its own stored assignment")
  func checksOnlyEditedShortcut() {
    let edited = KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option])
    let unrelated = KeyboardShortcuts.Shortcut(.l, modifiers: [.control, .option])
    let candidate = ShortcutAssignment(id: "edited", title: "Edited", scope: .selection, shortcut: edited)
    var assignments = [
      candidate,
      ShortcutAssignment(id: "otherWindow", title: "Other window", scope: .pinnedImage, shortcut: edited),
      ShortcutAssignment(id: "oldFirst", title: "Old first", scope: .capture, shortcut: unrelated),
      ShortcutAssignment(id: "oldSecond", title: "Old second", scope: .global, shortcut: unrelated)
    ]
    #expect(candidate.conflicts(in: assignments).isEmpty)

    assignments.append(ShortcutAssignment(id: "global", title: "Global", scope: .global, shortcut: edited))
    #expect(candidate.conflicts(in: assignments).map(\.id) == ["global"])
  }

  private func recorders(in view: NSView) -> [KeyboardShortcuts.RecorderCocoa] {
    if let recorder = view as? KeyboardShortcuts.RecorderCocoa { return [recorder] }
    return view.subviews.flatMap { recorders(in: $0) }
  }
}

@MainActor
@Suite(.serialized)
struct AppLanguageTests {
  private let localizations = ["Base", "en", "zh-Hans", "zh-Hant", "ja"]

  @Test("Inherited language preferences still display Follow System")
  func followsSystem() throws {
    try withPreferences { defaults, domain in
      defaults.register(defaults: [AppLanguage.preferenceKey: ["en"]])
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      #expect(language.selection == AppLanguage.system)
      #expect(!language.requiresRestart)
    }
  }

  @Test("Selecting Simplified Chinese stores an app-only override")
  func selectSimplifiedChinese() throws {
    try withPreferences { defaults, domain in
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      language.select("zh-Hans")
      #expect(language.selection == "zh-Hans")
      #expect(language.requiresRestart)
      #expect(defaults.persistentDomain(forName: domain)?[AppLanguage.preferenceKey] as? [String] == ["zh-Hans"])
      #expect(defaults.bool(forKey: "fixtureSetting"))
    }
  }

  @Test("A new launch restores the selected language without another restart notice")
  func restoresSelection() throws {
    try withPreferences { defaults, domain in
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      language.select("zh-Hans")
      let relaunched = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      #expect(relaunched.selection == "zh-Hans")
      #expect(!relaunched.requiresRestart)
    }
  }

  @Test("Follow System removes only the per-app language override")
  func removeOverride() throws {
    try withPreferences { defaults, domain in
      defaults.set(["zh-Hans"], forKey: AppLanguage.preferenceKey)
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      language.select(AppLanguage.system)
      #expect(language.selection == AppLanguage.system)
      #expect(language.requiresRestart)
      #expect(defaults.persistentDomain(forName: domain)?[AppLanguage.preferenceKey] == nil)
      #expect(defaults.bool(forKey: "fixtureSetting"))
    }
  }

  @Test("Restoring the original selection removes the restart notice")
  func restoreOriginalSelection() throws {
    try withPreferences { defaults, domain in
      defaults.set(["en"], forKey: AppLanguage.preferenceKey)
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      language.select("zh-Hans")
      #expect(language.requiresRestart)
      language.select("en")
      #expect(!language.requiresRestart)
      #expect(defaults.stringArray(forKey: AppLanguage.preferenceKey) == ["en"])
    }
  }

  @Test("Unsupported language identifiers do not modify preferences")
  func rejectUnsupportedLanguage() throws {
    try withPreferences { defaults, domain in
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      language.select("unsupported-fixture")
      #expect(language.selection == AppLanguage.system)
      #expect(!language.requiresRestart)
      #expect(defaults.persistentDomain(forName: domain)?[AppLanguage.preferenceKey] == nil)
    }
  }

  @Test("Language options prioritize Chinese and English without dropping existing translations")
  func availableOptions() {
    let options = AppLanguage.languageOptions(from: localizations + ["en", "", "de"])
    #expect(Array(options.prefix(3)) == ["zh-Hans", "en", "zh-Hant"])
    #expect(Set(options) == Set(["en", "zh-Hans", "zh-Hant", "ja", "de"]))
    #expect(options.count == 5)
    #expect(AppLanguage.displayName(for: "zh-Hans") == "简体中文")
    #expect(AppLanguage.displayName(for: "zh-Hant") == "繁體中文")
    #expect(AppLanguage.displayName(for: "en") == "English")
  }

  @Test("Regional language overrides resolve to a shipped localization")
  func regionalOverride() throws {
    try withPreferences { defaults, domain in
      defaults.set(["zh-Hans-CN"], forKey: AppLanguage.preferenceKey)
      let language = AppLanguage(defaults: defaults, domain: domain, localizations: localizations)
      #expect(language.selection == "zh-Hans")
    }
  }

  @Test("The built app includes Simplified Chinese language and capture settings")
  func bundledChineseTranslations() throws {
    #expect(Bundle.main.localizations.contains("zh-Hans"))
    let path = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
    let bundle = try #require(Bundle(path: path))
    #expect(bundle.localizedString(forKey: "Language", value: nil, table: "GeneralSettings") == "语言：")
    #expect(
      bundle.localizedString(forKey: "LanguageFollowSystem", value: nil, table: "GeneralSettings") == "跟随系统"
    )
    #expect(
      bundle.localizedString(forKey: "LanguageRestart", value: nil, table: "GeneralSettings") == "重启以应用"
    )
    #expect(
      bundle.localizedString(forKey: "ScreenshotSection", value: nil, table: "GeneralSettings") != "ScreenshotSection"
    )
  }

  @Test("The status item accessibility label uses the app's display name in every shipped locale")
  func statusItemAccessibilityName() throws {
    let displayName = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
    for localization in Bundle.main.localizations where localization != "Base" {
      let path = try #require(Bundle.main.path(forResource: localization, ofType: "lproj"))
      let bundle = try #require(Bundle(path: path))
      let label = bundle.localizedString(forKey: "status_item_accessibility_label", value: nil, table: nil)
      #expect(label.hasPrefix("\(displayName) — "), "\(localization): \(label)")
    }
  }

  @Test("Advanced settings shell examples target the running app's defaults domain")
  func advancedSettingsShellExamples() throws {
    let identifier = try #require(Bundle.main.bundleIdentifier)
    var checkedExamples = 0
    for localization in Bundle.main.localizations {
      guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
            let bundle = Bundle(path: path) else { continue }
      for key in ["TurnOffShellScript", "TurnOffNextShellScript"] {
        let example = bundle.localizedString(forKey: key, value: nil, table: "AdvancedSettings")
        guard !example.isEmpty && example != key else { continue }
        #expect(example.contains(identifier), "\(localization): \(key) is missing the app's defaults domain")
        #expect(!example.localizedCaseInsensitiveContains(AppIdentity.originalIdentifier))
        checkedExamples += 1
      }
    }
    #expect(checkedExamples > 0)
  }

  @Test("The slow-scroll hint is translated in every shipped localization")
  func slowScrollHintTranslated() throws {
    let english = "Scroll more slowly"
    let localizations = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }
    #expect(localizations.count >= 30)
    for localization in localizations {
      guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
            let bundle = Bundle(path: path),
            bundle.path(forResource: "GeneralSettings", ofType: "strings") != nil else { continue }
      let value = bundle.localizedString(forKey: "ScreenshotLongSlowScroll", value: nil, table: "GeneralSettings")
      #expect(value != english && value != "ScreenshotLongSlowScroll", "\(localization) is untranslated")
    }
  }

  @Test("The color format hint is translated in every shipped localization")
  func colorFormatHintTranslated() throws {
    let english = "Hold C · Space to switch"
    let localizations = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }
    #expect(localizations.count >= 30)
    for localization in localizations {
      guard let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
            let bundle = Bundle(path: path),
            bundle.path(forResource: "GeneralSettings", ofType: "strings") != nil else { continue }
      let value = bundle.localizedString(forKey: "ScreenshotColorFormatHint", value: nil, table: "GeneralSettings")
      #expect(value != english && value != "ScreenshotColorFormatHint", "\(localization) is untranslated")
    }
  }

  @Test("The history footer's update check is translated in every shipped localization")
  func checkForUpdatesTranslated() throws {
    let localizations = Bundle.main.localizations.filter { $0 != "en" && $0 != "Base" }
    #expect(localizations.count >= 30)
    for localization in localizations {
      let path = try #require(Bundle.main.path(forResource: localization, ofType: "lproj"))
      let bundle = try #require(Bundle(path: path))
      for (key, english) in [
        ("check_for_updates", "Check for Updates"),
        ("check_for_updates_tooltip", "Check for a new version of the application.")
      ] {
        let value = bundle.localizedString(forKey: key, value: nil, table: nil)
        #expect(!value.isEmpty && value != english && value != key, "\(localization): \(key) is untranslated")
      }
      let title = bundle.localizedString(forKey: "check_for_updates", value: nil, table: nil)
      #expect(!title.hasSuffix("…"), "\(localization): \(title)")
    }
  }

  @Test("The history footer's Preferences label has no trailing ellipsis in any localization")
  func preferencesLabelHasNoEllipsis() throws {
    let localizations = Bundle.main.localizations.filter { $0 != "Base" }
    #expect(localizations.count >= 30)
    for localization in localizations {
      let path = try #require(Bundle.main.path(forResource: localization, ofType: "lproj"))
      let bundle = try #require(Bundle(path: path))
      let title = bundle.localizedString(forKey: "preferences", value: nil, table: nil)
      #expect(!title.hasSuffix("…"), "\(localization): \(title)")
    }
  }

  private func withPreferences(_ body: (UserDefaults, String) -> Void) throws {
    let domain = "local.maccy.language.fixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.setPersistentDomain(["fixtureSetting": true], forName: domain)
    body(defaults, domain)
  }
}
