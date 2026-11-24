import SwiftUI
import Defaults
import LaunchAtLogin

struct GeneralSettingsPane: View {
  private let notificationsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(Bundle.main.bundleIdentifier ?? "")"
  )

  @Default(.searchMode) private var searchMode
  @Default(.pasteByDefault) private var pasteByDefault
  @Default(.removeFormattingByDefault) private var removeFormattingByDefault

  @State private var copyModifier = HistoryItemAction.copy.modifierFlags.description
  @State private var pasteModifier = HistoryItemAction.paste.modifierFlags.description
  @State private var pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description

  @State private var updater = SoftwareUpdater.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      PreferencesGroup(title: Text("GeneralLanguageSection", tableName: "GeneralSettings"), symbol: "globe") {
        LanguageSettingsView()
          .padding(.vertical, 10)
      }

      PreferencesGroup(title: Text("GeneralBehaviorSection", tableName: "GeneralSettings"), symbol: "slider.horizontal.3") {
        PreferencesRow(title: Text("LaunchAtLogin", tableName: "GeneralSettings")) {
          LaunchAtLogin.Toggle {
            Text("LaunchAtLogin", tableName: "GeneralSettings")
          }
          .toggleStyle(.switch)
          .labelsHidden()
          .accessibilityLabel(Text("LaunchAtLogin", tableName: "GeneralSettings"))
        }
        Divider()

        PreferencesRow(title: Text("Search", tableName: "GeneralSettings")) {
          Picker("", selection: $searchMode) {
            ForEach(Search.Mode.allCases) { mode in
              Text(mode.description)
            }
          }
          .labelsHidden()
          .accessibilityLabel(Text("Search", tableName: "GeneralSettings"))
          .frame(width: 176, alignment: .trailing)
        }
        Divider()

        option(.pasteByDefault, "PasteAutomatically")
        Divider()
        option(.removeFormattingByDefault, "PasteWithoutFormatting")

        Text(String(
          format: NSLocalizedString("Modifiers", tableName: "GeneralSettings", comment: ""),
          copyModifier, pasteModifier, pasteWithoutFormatting
        ))
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .font(.subheadline)
        .padding(.bottom, 10)

        Divider()
        option(.formatJSON, "FormatJSON")
        Divider()
        if let notificationsURL = notificationsURL {
          Link(destination: notificationsURL, label: {
            Text("NotificationsAndSounds", tableName: "GeneralSettings")
          })
          .padding(.bottom, 10)
        }
        Divider()
        option(.screenshotRemoveWindowShadow, "ScreenshotRemoveWindowShadow")
        Divider()
        option(.screenshotWindowBackdrop, "ScreenshotWindowBackdrop")
        Divider()
        option(.automaticPinStackingEnabled, Text(verbatim: String(
          localized: "ScreenshotAutoStackPins",
          defaultValue: "Automatically stack pinned screenshots",
          table: "GeneralSettings"
        )))
      }

      PreferencesGroup(title: Text("UpdateSection", tableName: "GeneralSettings"), symbol: "arrow.down.circle") {
        updateSettings
          .padding(.vertical, 10)
      }
    }
    .onChange(of: pasteByDefault, refreshModifiers)
    .onChange(of: removeFormattingByDefault, refreshModifiers)
  }

  private func option(_ key: Defaults.Key<Bool>, _ title: LocalizedStringKey) -> some View {
    option(key, Text(title, tableName: "GeneralSettings"))
  }

  private func option(_ key: Defaults.Key<Bool>, _ title: Text) -> some View {
    PreferencesRow(title: title) {
      Defaults.Toggle(key: key) {
        title
      }
      .toggleStyle(.switch)
      .labelsHidden()
      .accessibilityLabel(title)
    }
  }

  private var updateSettings: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(verbatim: updater.currentVersion)
        .font(.caption)
        .textSelection(.enabled)
      Picker(selection: $updater.channel) {
        Text("UpdateChannelStable", tableName: "GeneralSettings").tag(RepositoryUpdateFeed.Channel.stable)
        Text("UpdateChannelPreview", tableName: "GeneralSettings").tag(RepositoryUpdateFeed.Channel.preview)
      } label: {
        Text("UpdateChannel", tableName: "GeneralSettings")
      }
      .pickerStyle(.menu)
      .disabled(!updater.isAvailable || updater.isBusy)
      Text("UpdateChannelHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Toggle(isOn: $updater.automaticallyChecksForUpdates) {
        Text("UpdateAutomaticChecks", tableName: "GeneralSettings")
      }
      .disabled(!updater.isAvailable)
      HStack {
        Button {
          updater.checkForUpdates()
        } label: {
          Text("CheckNow", tableName: "GeneralSettings")
        }
        .disabled(!updater.isAvailable || updater.isBusy)
        if updater.isChecking {
          ProgressView().controlSize(.small)
        }
      }
      Text(LocalizedStringKey(updater.statusKey), tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text("UpdateRestartHelp", tableName: "GeneralSettings")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func refreshModifiers() {
    copyModifier = HistoryItemAction.copy.modifierFlags.description
    pasteModifier = HistoryItemAction.paste.modifierFlags.description
    pasteWithoutFormatting = HistoryItemAction.pasteWithoutFormatting.modifierFlags.description
  }
}

#Preview {
  GeneralSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
