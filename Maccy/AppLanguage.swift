import Foundation
import Observation

@MainActor
@Observable
final class AppLanguage {
  static let shared = AppLanguage()
  static let system = "system"
  static let preferenceKey = "AppleLanguages"

  let supportedLanguages: [String]
  private(set) var selection: String

  @ObservationIgnored private let defaults: UserDefaults
  private let originalSelection: String

  var requiresRestart: Bool { selection != originalSelection }

  init(
    defaults: UserDefaults = .standard,
    domain: String = Bundle.main.bundleIdentifier ?? AppIdentity.customizedIdentifier,
    localizations: [String] = Bundle.main.localizations
  ) {
    self.defaults = defaults
    let languages = Self.languageOptions(from: localizations)
    supportedLanguages = languages
    let preferences = defaults.persistentDomain(forName: domain)?[Self.preferenceKey] as? [String]
    let selected: String
    if let preferences, !preferences.isEmpty {
      selected = Bundle.preferredLocalizations(from: languages, forPreferences: preferences).first ?? Self.system
    } else {
      selected = Self.system
    }
    selection = selected
    originalSelection = selected
  }

  func select(_ identifier: String) {
    guard identifier == Self.system || supportedLanguages.contains(identifier) else { return }
    guard identifier != selection else { return }
    if identifier == Self.system {
      defaults.removeObject(forKey: Self.preferenceKey)
    } else {
      defaults.set([identifier], forKey: Self.preferenceKey)
    }
    selection = identifier
  }

  static func languageOptions(from localizations: [String]) -> [String] {
    let languages = Set(localizations.filter { !$0.isEmpty && $0 != "Base" })
    let prioritized = ["zh-Hans", "en", "zh-Hant"].filter { languages.contains($0) }
    let remaining = languages.subtracting(prioritized).sorted {
      displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
    }
    return prioritized + remaining
  }

  static func displayName(for identifier: String) -> String {
    switch identifier {
    case "zh-Hans": return "简体中文"
    case "zh-Hant": return "繁體中文"
    case "en": return "English"
    default: return Locale(identifier: identifier).localizedString(forIdentifier: identifier) ?? identifier
    }
  }
}
