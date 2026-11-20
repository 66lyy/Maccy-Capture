import Defaults
import Foundation

enum GlassStyle: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
  case frosted
  case clear

  var id: Self { self }

  var description: String {
    switch self {
    case .frosted:
      return NSLocalizedString("GlassStyleFrosted", tableName: "AppearanceSettings", comment: "")
    case .clear:
      return NSLocalizedString("GlassStyleClear", tableName: "AppearanceSettings", comment: "")
    }
  }
}
