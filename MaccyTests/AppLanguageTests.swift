import Foundation
import Testing
@testable import Maccy

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

  private func withPreferences(_ body: (UserDefaults, String) -> Void) throws {
    let domain = "local.maccy.language.fixture.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.setPersistentDomain(["fixtureSetting": true], forName: domain)
    body(defaults, domain)
  }
}
