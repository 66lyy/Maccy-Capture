import SwiftUI

struct LanguageSettingsView: View {
  @State private var language = AppLanguage.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("", selection: Binding(get: { language.selection }, set: { language.select($0) })) {
        Text(String(
          localized: "LanguageFollowSystem", defaultValue: "Follow System", table: "GeneralSettings"
        ))
        .tag(AppLanguage.system)
        Divider()
        ForEach(language.supportedLanguages, id: \.self) { identifier in
          Text(verbatim: AppLanguage.displayName(for: identifier))
            .tag(identifier)
        }
      }
      .labelsHidden()
      .accessibilityLabel(Text(String(
        localized: "Language", defaultValue: "Language:", table: "GeneralSettings"
      )))
      .frame(width: 220, alignment: .leading)

      Text(String(
        localized: "LanguageHelp",
        defaultValue: "Choose an app language. Restart to apply it to all menus and settings.",
        table: "GeneralSettings"
      ))
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      if language.requiresRestart {
        Button {
          AppState.shared.appDelegate?.restartCurrentApplication()
        } label: {
          Text(String(
            localized: "LanguageRestart", defaultValue: "Restart to Apply", table: "GeneralSettings"
          ))
        }
        Text(String(
          localized: "LanguageRestartNotice",
          defaultValue: "Restarting closes temporary pinned images but keeps clipboard history.",
          table: "GeneralSettings"
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
